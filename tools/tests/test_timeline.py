"""統合スクリプト (exp2/timeline.py、tools/build_timeline.py) のテスト。

2つのアプリと IMU の矛盾のない疑似データを tools/make_joint_sim.py で作り (3人、本番の長さ、約20秒)、
組み合わせ・時計のずれの確認・状態のラベルが、筋書き (正解) どおりになるかを確かめる。
IMU は課題アプリの被験者フォルダ (headphone_motion.csv) に入る。既存の IMU アプリの形 (imu/<ID>.db、予備の経路) も書く。
1人目は iPhone に別の ID (DEV_JOINT10) を入れ、3人目は iPhone の時計を 3 秒進めてある。

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

from exp2.load import load_imu_sqlite  # noqa: E402
from exp2.timeline import LabelParams, build_timeline, detect_holding, pair_sessions  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[2]
TOOLS = APP_ROOT / "tools"


class DetectHoldingTest(unittest.TestCase):
    """持ち上げの判定。机の上 → 平らに近く持つ (傾き 10°、手の揺れあり) → 机の上 → 机の上で一瞬叩かれる"""

    def motion(self):
        rng = np.random.default_rng(0)
        t = np.arange(0, 40_000, 20)
        held = (t >= 10_000) & (t < 25_000)
        tilt = np.radians(np.where(held, 10.0, 0.5))
        rot_sigma = np.where(held, 0.05, 0.0015)
        rot_sigma[(t >= 32_000) & (t < 32_100)] = 0.5  # 机を叩いた一瞬の揺れ
        rot = rng.normal(0, 1, (3, len(t))) * rot_sigma
        return pd.DataFrame({"unix_ms": t, "grav_z": -np.cos(tilt), "rot_x": rot[0], "rot_y": rot[1], "rot_z": rot[2]})

    def test_flat_holding_is_detected_by_shake(self):
        h = detect_holding(self.motion(), LabelParams())
        self.assertEqual(len(h), 1, "机を叩いた一瞬は持ち上げにしない")
        self.assertAlmostEqual(h["start_unix_ms"].iloc[0], 10_000, delta=600)
        self.assertAlmostEqual(h["end_unix_ms"].iloc[0], 25_000, delta=600)

    def test_tilt_only_misses_flat_holding(self):
        """揺れを見ない (閾値を大きくする) と、傾き 10° の持ち方は分からない (揺れを足した理由)"""
        self.assertTrue(detect_holding(self.motion(), LabelParams(still_rot_rad_s=1e9)).empty)


@unittest.skipUnless(shutil.which("swift"), "swift がないので疑似データを作れない")
class TimelineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="exp2-timeline-pytest-"))
        cls.root = cls.tmp / "sim"
        subprocess.run(
            [sys.executable, str(TOOLS / "make_joint_sim.py"), "--out", str(cls.root), "--n", "3",
             "--game-id", "DEV_JOINT01=DEV_JOINT10", "--iphone-offset-ms", "DEV_JOINT03=3000", "--legacy-imu-db"],
            check=True, capture_output=True,
        )
        cls.pairs = {p.participant_id: p for p in pair_sessions(cls.root)}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def truth_states(self, pid, unix_ms):
        """正解 (本当の時刻 = iPad の時計、100 ms ごと) の状態。idle は neither と呼ぶ"""
        truth = pd.read_csv(self.root / "truth" / f"{pid}.csv")
        i = np.searchsorted(truth["true_unix_ms"].to_numpy(), unix_ms, side="right") - 1
        return pd.Series(truth["state"].to_numpy()[i]).replace({"idle": "neither"}).to_numpy()

    # --- 組み合わせ ---

    def test_pairs_by_id_and_warns_on_mismatch(self):
        self.assertEqual(self.pairs["DEV_JOINT02"].game_participant_id, "DEV_JOINT02")
        self.assertEqual(self.pairs["DEV_JOINT02"].issues, [])
        p = self.pairs["DEV_JOINT01"]
        self.assertEqual(p.game_participant_id, "DEV_JOINT10", "ID が食い違っても、時間が重なる記録と組にする")
        self.assertTrue(any(i.level == "WARN" and "食い違って" in i.message for i in p.issues))

    def test_pairs_override_and_missing_game(self):
        pairs = pair_sessions(self.root, overrides={"DEV_JOINT01": "DEV_JOINT10"})
        p = next(x for x in pairs if x.participant_id == "DEV_JOINT01")
        self.assertEqual(p.game_participant_id, "DEV_JOINT10")
        self.assertFalse(any(i.level == "WARN" for i in p.issues))
        empty = self.tmp / "no_game"
        empty.mkdir(exist_ok=True)
        lonely = pair_sessions(self.root, game_root=empty)
        self.assertTrue(all(x.game_folder is None for x in lonely))
        self.assertTrue(all(any("見つかりません" in i.message for i in x.issues) for x in lonely))

    # --- 時計のずれ ---

    def test_clock_offset_is_detected(self):
        tl = build_timeline(self.pairs["DEV_JOINT03"])
        self.assertAlmostEqual(tl.suggested_game_offset(), -3000, delta=750)
        self.assertTrue(any("時計のずれ" in i.check for i in tl.issues))
        fixed = build_timeline(self.pairs["DEV_JOINT03"], game_offset_ms=-3000)
        self.assertEqual(fixed.suggested_game_offset(), -3000)
        self.assertFalse(any("時計のずれ" in i.check for i in fixed.issues))
        ok = build_timeline(self.pairs["DEV_JOINT01"])
        self.assertFalse(any("時計のずれ" in i.check for i in ok.issues))

    # --- 状態のラベル ---

    def test_labels_match_truth(self):
        for pid, offset in [("DEV_JOINT01", 0), ("DEV_JOINT02", 0), ("DEV_JOINT03", -3000)]:
            tl = build_timeline(self.pairs[pid], game_offset_ms=offset)
            lab = tl.labels()
            free = lab[lab["segment"] == "free"]
            known = free[free["state"] != "ambiguous"]
            truth = self.truth_states(pid, known["unix_ms"].to_numpy())
            agree = (known["state"].astype(str).to_numpy() == truth).mean()
            self.assertGreater(agree, 0.97, pid)
            self.assertLess((free["state"] == "ambiguous").mean(), 0.1, pid)
            # ゲームのみ区間は (区間の始めの持ち上げまでを除いて) ゲーム中、計算のみの区間は計算中
            go = lab[(lab["segment"] == "game_only") & (lab["elapsed_ms"] > 5_000)]
            self.assertGreater((go["state"] == "game").mean(), 0.9, pid)
            fo = lab[lab["segment"] == "focus"]
            self.assertGreater((fo["state"] == "compute").mean(), 0.95, pid)

    def test_label_params_change_results(self):
        """感度分析: 回答の空きの閾値を変えると、どちらでもない時間が変わる"""
        pair = self.pairs["DEV_JOINT01"]
        base = build_timeline(pair).labels()
        strict = build_timeline(pair, params=LabelParams(slow_factor=1.2)).labels()
        self.assertGreater((strict["state"] == "ambiguous").sum(), (base["state"] == "ambiguous").sum())

    def test_windows_are_pure(self):
        tl = build_timeline(self.pairs["DEV_JOINT01"])
        lab = tl.labels()
        w = tl.windows(lab)
        self.assertTrue({"compute", "game"} <= set(w["state"].dropna()))
        for _, row in w.dropna(subset=["state"]).sample(50, random_state=0).iterrows():
            inside = lab[(lab["unix_ms"] >= row["start_unix_ms"]) & (lab["unix_ms"] < row["end_unix_ms"])]
            self.assertEqual(set(inside["state"].astype(str)), {row["state"]})
        self.assertTrue((w["end_unix_ms"] - w["start_unix_ms"] == 5_000).all())

    def test_attach_imu(self):
        tl = build_timeline(self.pairs["DEV_JOINT02"])
        # 課題アプリの AirPods の記録 (既定) と、既存の IMU アプリの形 (予備の経路) の両方
        for imu in [tl.attach_imu(), tl.attach_imu(load_imu_sqlite(self.root / "imu" / "DEV_JOINT02.db"))]:
            free = imu[imu["segment"] == "free"]
            self.assertGreater(len(free), 50 * 60 * 15)
            self.assertTrue(set(free["state"].dropna()) <= {"compute", "game", "neither", "ambiguous"})
            self.assertTrue(imu["state"].isna().iloc[0], "課題アプリの区間の外は状態なし")
        # センサの時刻は等間隔で、受け取りの止まりの影響を受けない
        app = tl.attach_imu()
        self.assertEqual(set(app["unix_ms"].diff().dropna()), {20})
        self.assertTrue(app["first_after_start"].iloc[0])

    def test_summary(self):
        s = build_timeline(self.pairs["DEV_JOINT01"]).summary()
        self.assertTrue(0 < s["work_rate"] <= 1)
        self.assertGreater(s["calibrated_throughput"], 0)
        self.assertGreater(s["free_holding_s"], 0)
        self.assertAlmostEqual(sum(s[f"free_frac_{k}"] for k in ("compute", "game", "neither", "ambiguous")), 1)

    # --- 書き出し ---

    def test_cli_writes_outputs(self):
        out = self.tmp / "timeline_out"
        r = subprocess.run([sys.executable, str(TOOLS / "build_timeline.py"), str(self.root), "--out", str(out),
                            "--game-offset", "DEV_JOINT03=-3000"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        for pid in ["DEV_JOINT01", "DEV_JOINT02", "DEV_JOINT03"]:
            for name in ["events.csv", "intervals.csv", "labels.csv", "windows.csv", "imu_states.csv"]:
                self.assertTrue((out / pid / name).exists(), f"{pid}/{name}")
        imu = pd.read_csv(out / "DEV_JOINT02" / "imu_states.csv")
        self.assertEqual(list(imu.columns), ["sample_index", "unix_ms", "task_unix_ms", "t_s", "segment", "state",
                                             "sensor_location", "first_after_start"])
        summary = pd.read_csv(out / "summary.csv")
        self.assertEqual(list(summary["participant_id"]), ["DEV_JOINT01", "DEV_JOINT02", "DEV_JOINT03"])
        self.assertIn("食い違って", (out / "report.txt").read_text())
        # 既にあれば止まる
        again = subprocess.run([sys.executable, str(TOOLS / "build_timeline.py"), str(self.root), "--out", str(out)],
                               capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)


if __name__ == "__main__":
    unittest.main()
