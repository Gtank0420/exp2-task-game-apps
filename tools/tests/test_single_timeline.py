"""1台版の統合 (exp2/single_timeline.py、tools/build_single_timeline.py) のテスト。

1台版と IMU の矛盾のない疑似データを tools/make_single_sim.py で作り (3人、本番の長さ、約10秒)、
状態のラベルが筋書き (正解) どおりになるかを確かめる。2台版の test_timeline.py と同じ基準 (一致 97% 以上)。

    .venv/bin/python -m unittest discover -s tools/tests
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from exp2.single_timeline import STATES, SingleLabelParams, build_single_timeline  # noqa: E402
from exp2.single_validate import validate_single_session  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[2]
TOOLS = APP_ROOT / "tools"
PIDS = ["DEV_SJOINT01", "DEV_SJOINT02", "DEV_SJOINT03"]


@unittest.skipUnless(shutil.which("swift"), "swift がないので疑似データを作れない")
class SingleTimelineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="exp2-single-timeline-pytest-"))
        cls.root = cls.tmp / "sim"
        subprocess.run([sys.executable, str(TOOLS / "make_single_sim.py"), "--out", str(cls.root), "--n", "3"],
                       check=True, capture_output=True)
        cls.folders = {pid: cls.root / "exp2_single" / pid for pid in PIDS}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def truth_states(self, pid, unix_ms):
        """正解 (100 ms ごと) の状態。idle は neither と呼ぶ"""
        truth = pd.read_csv(self.root / "truth" / f"{pid}.csv")
        i = np.searchsorted(truth["true_unix_ms"].to_numpy(), unix_ms, side="right") - 1
        return pd.Series(truth["state"].to_numpy()[i]).replace({"idle": "neither"}).to_numpy()

    def test_simulated_data_is_valid(self):
        for pid, folder in self.folders.items():
            issues = validate_single_session(folder)
            self.assertEqual([str(i) for i in issues if i.level in ("ERROR", "WARN")], [], pid)

    def test_labels_match_truth(self):
        for pid, folder in self.folders.items():
            tl = build_single_timeline(folder)
            lab = tl.labels()
            free = lab[lab["segment"] == "free"]
            known = free[free["state"] != "ambiguous"]
            truth = self.truth_states(pid, known["unix_ms"].to_numpy())
            agree = (known["state"].astype(str).to_numpy() == truth).mean()
            self.assertGreater(agree, 0.97, pid)
            self.assertLess((free["state"] == "ambiguous").mean(), 0.1, pid)
            self.assertTrue({"compute", "game"} <= set(known["state"].astype(str)), pid)
            # ゲームのみの区間は (始めの1秒を除いて) ゲーム中、計算のみの区間は計算中
            go = lab[(lab["segment"] == "game_only") & (lab["elapsed_ms"] > 2_000)]
            self.assertGreater((go["state"] == "game").mean(), 0.9, pid)
            fo = lab[lab["segment"] == "focus"]
            self.assertGreater((fo["state"] == "compute").mean(), 0.95, pid)

    def test_popup_time_is_never_compute(self):
        """ポップアップが出ている間は計算中にしない。回答間隔は出た・閉じた時刻で区切る"""
        tl = build_single_timeline(self.folders["DEV_SJOINT02"])
        lab = tl.labels()
        inside = lab[lab["popup_index"].notna()]
        self.assertFalse(inside.empty)
        self.assertTrue(inside["on_game_screen"].all())
        self.assertFalse((inside["state"] == "compute").any())
        self.assertTrue((inside["since_shown_ms"] >= 0).all())
        ai = tl._answer_intervals("free")
        for _, p in tl.session.popups.iterrows():
            spans = (ai["start_unix_ms"] < p["closed_unix_ms"]) & (ai["end_unix_ms"] > p["shown_unix_ms"])
            self.assertFalse(spans.any(), f"popup_index {p['popup_index']} をまたぐ回答間隔がある")

    def test_dismissed_and_onset(self):
        """遊ばずに閉じたポップアップは dismissed、遊んだポップアップの最初の操作までは onset (切り替わりの前後を除く前)"""
        tl = build_single_timeline(self.folders["DEV_SJOINT02"])
        lab = tl.labels()
        pops = tl.session.popups
        for _, p in pops.iterrows():
            rows = lab[lab["popup_index"] == p["popup_index"]]
            if p["n_actions"] == 0:
                self.assertTrue((rows["raw_state"] == "dismissed").all())
            else:
                first = p["shown_unix_ms"] + p["first_action_ms"]
                self.assertTrue((rows[rows["unix_ms"] < first]["raw_state"] == "onset").all())
                self.assertFalse((rows[rows["unix_ms"] >= first]["raw_state"].isin(["onset", "dismissed"])).any())

    def test_label_params_change_results(self):
        """感度分析: ゲーム中とみなす時間を短くすると、ゲーム画面で止まっている時間が増える"""
        folder = self.folders["DEV_SJOINT03"]
        base = build_single_timeline(folder).labels()
        strict = build_single_timeline(folder, SingleLabelParams(game_window_ms={"stack": 300, "merge": 300})).labels()
        self.assertGreater((strict["raw_state"] == "game_idle").sum(), (base["raw_state"] == "game_idle").sum())

    def test_windows_are_pure(self):
        tl = build_single_timeline(self.folders["DEV_SJOINT01"])
        lab = tl.labels()
        w = tl.windows(lab)
        self.assertTrue({"compute", "game"} <= set(w["state"].dropna()))
        for _, row in w.dropna(subset=["state"]).sample(50, random_state=0).iterrows():
            inside = lab[(lab["unix_ms"] >= row["start_unix_ms"]) & (lab["unix_ms"] < row["end_unix_ms"])]
            self.assertEqual(set(inside["state"].astype(str)), {row["state"]})

    def test_attach_imu(self):
        tl = build_single_timeline(self.folders["DEV_SJOINT02"])
        imu = tl.attach_imu()
        free = imu[imu["segment"] == "free"]
        self.assertGreater(len(free), 50 * 60 * 15)
        self.assertTrue(set(free["state"].dropna()) <= set(STATES))
        self.assertTrue(imu["state"].isna().iloc[0], "区間の外は状態なし")
        self.assertEqual(set(imu["unix_ms"].diff().dropna()), {20})

    def test_summary(self):
        tl = build_single_timeline(self.folders["DEV_SJOINT01"])
        s = tl.summary()
        self.assertTrue(0 < s["work_rate"] <= 1)
        self.assertGreater(s["calibrated_throughput"], 0)
        self.assertEqual(s["n_popups"], len(tl.session.popups))
        self.assertAlmostEqual(sum(s[f"free_frac_{k}"] for k in STATES), 1)
        self.assertAlmostEqual(s["play_rate"] + s["dismissed_rate"], 1)

    def test_cli_writes_outputs(self):
        out = self.tmp / "timeline_out"
        r = subprocess.run([sys.executable, str(TOOLS / "build_single_timeline.py"), str(self.root), "--out", str(out)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        for pid in PIDS:
            for name in ["events.csv", "intervals.csv", "labels.csv", "windows.csv", "imu_states.csv"]:
                self.assertTrue((out / pid / name).exists(), f"{pid}/{name}")
        summary = pd.read_csv(out / "summary.csv")
        self.assertEqual(list(summary["participant_id"]), PIDS)
        # 既にあれば止まる
        again = subprocess.run([sys.executable, str(TOOLS / "build_single_timeline.py"), str(self.root), "--out", str(out)],
                               capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)


if __name__ == "__main__":
    unittest.main()
