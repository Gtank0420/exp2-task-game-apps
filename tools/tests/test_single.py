"""1台版の読み込み (exp2/single_load.py) と検証 (exp2/single_validate.py) のテスト。

疑似参加者のデータを exp2-single-simulate (Swift) で一時フォルダに作り、
そのままなら検証を通ること、わざと壊すと検出されることを確かめる。
Python 側の列の定義が、アプリ側 (SingleRecords.swift) と食い違っていないことも確かめる。

    .venv/bin/python -m unittest discover -s tools/tests
"""

import csv
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pandas as pd  # noqa: E402

from exp2 import single_schema  # noqa: E402
from exp2.single_load import load_single_session, load_single_sessions, single_session_folders  # noqa: E402
from exp2.single_validate import _check_meta, validate_single_session  # noqa: E402
from exp2.validate import _Report  # noqa: E402
from validate_session import find_folders  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[2]
SOURCES = APP_ROOT / "Packages/ExperimentCore/Sources"
SINGLE_RECORDS_SWIFT = SOURCES / "SingleCore/SingleRecords.swift"
BASE_RECORDS_SWIFT = {
    "ItemRecord": SOURCES / "ExperimentCore/Records.swift",
    "EventRecord": SOURCES / "ExperimentCore/Records.swift",
    "SegmentRecord": SOURCES / "ExperimentCore/Records.swift",
    "RoundRecord": SOURCES / "GameCore/GameRecords.swift",
    "TouchRecord": SOURCES / "GameCore/GameRecords.swift",
}


def errors(issues):
    return [i for i in issues if i.level == "ERROR"]


def warns(issues):
    return [i for i in issues if i.level == "WARN"]


@unittest.skipUnless(shutil.which("swift"), "swift がないので疑似データを作れない")
class SingleLoadValidateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="exp2-single-pytest-"))
        # 2人分、区間を短縮。1人目は自由区間の最初のポップアップの最中に落ちて再開する
        subprocess.run(
            ["swift", "run", "--package-path", str(APP_ROOT / "Packages/ExperimentCore"), "exp2-single-simulate",
             "--out", str(cls.tmp / "orig"), "--n", "2", "--short", "--interrupt-popup"],
            check=True, capture_output=True,
        )
        cls.root = cls.tmp / "orig" / single_schema.DATA_FOLDER

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def copy(self, pid="DEV_SSIM02") -> Path:
        """壊す用に1人分を写す (フォルダ名は participant_id と同じにしておく)。"""
        dest = Path(tempfile.mkdtemp(dir=self.tmp)) / pid
        shutil.copytree(self.root / pid, dest)
        return dest

    def edit_csv(self, path: Path, fn):
        with path.open(newline="") as f:
            rows = list(csv.reader(f))
        fn(rows)
        with path.open("w", newline="") as f:
            csv.writer(f, lineterminator="\n").writerows(rows)

    def col(self, rows, name):
        return rows[0].index(name)

    def assert_issue(self, folder, text, level="ERROR"):
        issues = validate_single_session(folder)
        self.assertTrue(any(i.level == level and text in i.message for i in issues),
                        f"「{text}」の {level} がありません: {[str(i) for i in errors(issues) + warns(issues)]}")

    # --- そのままのデータ ---

    def test_simulated_data_is_valid(self):
        for pid in ["DEV_SSIM01", "DEV_SSIM02"]:
            issues = validate_single_session(self.root / pid)
            self.assertEqual(errors(issues) + warns(issues), [], pid)

    def test_interrupted_popup(self):
        s = load_single_session(self.root / "DEV_SSIM01")
        self.assertEqual(s.popups["close_reason"].iloc[0], "interrupted")
        free = s.segments[s.segments["segment"] == "free"]
        self.assertEqual(list(free["end_reason"]), ["interrupted", "timeout"])
        self.assertEqual(s.popups["closed_elapsed_ms"].iloc[0], free["end_elapsed_ms"].iloc[0])
        self.assertTrue((s.rounds["end_reason"] == "interrupted").any())

    def test_loaded_types(self):
        s = load_single_session(self.root / "DEV_SSIM02")
        self.assertEqual(str(s.popups["shown_mono_ms"].dtype), "int64")
        self.assertEqual(str(s.popups["first_action_ms"].dtype), "Int64")
        self.assertEqual(str(s.touches["in_guard"].dtype), "boolean")
        self.assertEqual(str(s.items["unanswered_reason"].dtype), "category")
        self.assertEqual(list(s.items["segment"].cat.categories), ["focus", "game_only", "free"])
        self.assertEqual(s.config["popup"]["segment"], "free")
        self.assertEqual(len(load_single_sessions(self.root.parent)), 2)
        self.assertEqual(load_single_sessions(self.root, include_dev=False), [])

    def test_python_wait_sequence_matches_app(self):
        # アプリが書いた待ち時間と、Python で種から求めた待ち時間が一致する (Swift と同じ手順か)
        for pid in ["DEV_SSIM01", "DEV_SSIM02"]:
            s = load_single_session(self.root / pid)
            expected = [single_schema.popup_wait_ms(s.config["popup"], k) for k in s.popups["popup_index"]]
            self.assertEqual(list(s.popups["planned_wait_ms"]), expected)
            self.assertEqual(list(s.popups["game"]),
                             [single_schema.popup_game(s.config["popup"], k) for k in s.popups["popup_index"]])

    def test_production_wait_range(self):
        popup = {"seed": 20261106, "wait_min_ms": 120_000, "wait_max_ms": 240_000, "wait_step_ms": 1_000}
        waits = [single_schema.popup_wait_ms(popup, k) for k in range(300)]
        self.assertTrue(all(120_000 <= w <= 240_000 and w % 1_000 == 0 for w in waits))

    def test_find_folders_tells_single_from_task(self):
        # 1台版のフォルダも meta.json を持つので、課題アプリとして検証してはいけない
        for path in [self.root.parent, self.root, self.root / "DEV_SSIM01"]:
            kinds = {kind for kind, _ in find_folders(path)}
            self.assertEqual(kinds, {"single"}, path)
        self.assertEqual(single_session_folders(self.tmp), [])

    # --- 壊したデータ ---

    def test_detects_wrong_planned_wait(self):
        folder = self.copy()
        def change(rows):
            i = self.col(rows, "planned_wait_ms")
            rows[1][i] = str(int(rows[1][i]) + 1_000)
        self.edit_csv(folder / "popups.csv", change)
        self.assert_issue(folder, "待ち時間の列")

    def test_detects_missing_popup(self):
        folder = self.copy()
        self.edit_csv(folder / "popups.csv", lambda rows: rows.pop())
        issues = validate_single_session(folder)
        self.assertTrue(errors(issues))

    def test_detects_wrong_game_order(self):
        folder = self.copy()
        def swap(rows):
            i = self.col(rows, "game")
            rows[1][i] = "merge" if rows[1][i] == "stack" else "stack"
        self.edit_csv(folder / "popups.csv", swap)
        self.assert_issue(folder, "交互の順")

    def test_detects_game_action_during_guard(self):
        folder = self.copy()
        popups = pd.read_csv(folder / "popups.csv")
        shown = int(popups["shown_mono_ms"].iloc[0])
        def act(rows):
            i_down, i_res, i_guard, i_pop = (self.col(rows, c) for c in ["down_mono_ms", "result", "in_guard", "popup_index"])
            row = next(r for r in rows[1:] if r[i_pop] == "0")
            row[i_down] = str(shown + 100)
            row[i_guard] = "1"
            row[i_res] = "drop_placed"
        self.edit_csv(folder / "touches.csv", act)
        self.assert_issue(folder, "受け付けない時間に触れたタッチで、ゲームが動いています")

    def test_detects_missing_interrupted_item(self):
        folder = self.copy()
        def change(rows):
            i_reason, i_pop = self.col(rows, "unanswered_reason"), self.col(rows, "popup_index")
            row = next(r for r in rows[1:] if r[i_reason] == "popup")
            row[i_reason] = "timeout"
            row[i_pop] = ""
        self.edit_csv(folder / "items.csv", change)
        self.assert_issue(folder, "中断した問題")

    def test_detects_wrong_app_kind(self):
        folder = self.copy()
        meta = json.loads((folder / "meta.json").read_text())
        meta["app_kind"] = "task"
        (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
        self.assert_issue(folder, "app_kind")

    def test_detects_two_device_id_in_production(self):
        meta = json.loads((self.root / "DEV_SSIM02" / "meta.json").read_text())
        meta.update(participant_id="P01", mode="production")
        r = _Report()
        _check_meta(meta, Path("P01"), r)
        self.assertTrue(any("1台版の決まり" in i.message for i in r.issues))
        meta.update(participant_id="S01")
        r = _Report()
        _check_meta(meta, Path("S01"), r)
        self.assertFalse(any("1台版の決まり" in i.message for i in r.issues))


class SingleSchemaMatchesSwiftTest(unittest.TestCase):
    """Python 側の定義が、アプリ側 (SingleRecords.swift) と食い違っていないこと。"""

    def setUp(self):
        self.src = SINGLE_RECORDS_SWIFT.read_text(encoding="utf-8")

    @staticmethod
    def swift_columns(src: str, struct: str) -> list[str]:
        """struct の `static let columns` を読む。`ItemRecord.columns + [...]` のように2台版の列を土台にした形も読む。"""
        body = src.split(f"struct {struct}")[1]
        m = re.search(r"static let columns = (?:(\w+)\.columns)?(?: \+ )?(\[(.*?)\])?\n", body, re.S)
        base = []
        if m.group(1):
            base = SingleSchemaMatchesSwiftTest.swift_columns(
                BASE_RECORDS_SWIFT[m.group(1)].read_text(encoding="utf-8"), m.group(1))
        extra = re.findall(r'"([a-z_]+)"', m.group(3) or "")
        return base + extra

    def test_columns(self):
        for struct, table in [("SingleItemRecord", "items.csv"), ("SingleEventRecord", "events.csv"),
                              ("SingleSegmentRecord", "segments.csv"), ("PopupRecord", "popups.csv"),
                              ("SingleRoundRecord", "game_rounds.csv"), ("SingleTouchRecord", "touches.csv")]:
            self.assertEqual(self.swift_columns(self.src, struct),
                             [c.name for c in single_schema.TABLES[table]], table)

    def enum_values(self, name):
        body = self.src.split(f"enum {name}")[1].split("\n}")[0]
        return [m.group(2) or m.group(1) for m in re.finditer(r'\bcase (\w+)(?: = "([a-z_]+)")?', body)]

    def test_enums(self):
        self.assertEqual(tuple(self.enum_values("SingleEventType")), single_schema.SINGLE_EVENT_TYPES)
        self.assertEqual(tuple(self.enum_values("UnansweredReason")), single_schema.UNANSWERED_REASONS)
        self.assertEqual(tuple(self.enum_values("PopupCloseReason")), single_schema.POPUP_CLOSE_REASONS)
        self.assertEqual(tuple(self.enum_values("SingleRoundEndReason")), single_schema.ROUND_END_REASONS)


if __name__ == "__main__":
    unittest.main()
