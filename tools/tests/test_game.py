"""ゲームアプリの読み込み (exp2/game_load.py)・検証 (exp2/game_validate.py)・2048 型の再現 (exp2/merge_game.py) のテスト。

疑似プレイヤーのデータを exp2-simulate --app game (Swift) で一時フォルダに作り、
そのままなら検証を通ること、わざと壊すと検出されることを確かめる。

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

from exp2 import game_schema  # noqa: E402
from exp2.game_load import combine_game, load_game_session, load_game_sessions  # noqa: E402
from exp2.game_validate import round_seed, validate_game_session  # noqa: E402
from exp2.merge_game import GOLDEN, MergeGame  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[2]
GAME_RECORDS_SWIFT = APP_ROOT / "Packages/ExperimentCore/Sources/GameCore/GameRecords.swift"


def errors(issues):
    return [i for i in issues if i.level == "ERROR"]


def warns(issues):
    return [i for i in issues if i.level == "WARN"]


@unittest.skipUnless(shutil.which("swift"), "swift がないので疑似データを作れない")
class GameLoadValidateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="exp2-game-pytest-"))
        # 2人分、5分ずつ。1人目は記録開始から 70 秒で落ちて再開する
        subprocess.run(
            ["swift", "run", "--package-path", str(APP_ROOT / "Packages/ExperimentCore"), "exp2-simulate",
             "--app", "game", "--out", str(cls.tmp / "orig"), "--n", "2", "--short",
             "--interrupt-game-at-ms", "70000"],
            check=True, capture_output=True,
        )
        cls.root = cls.tmp / "orig" / game_schema.DATA_FOLDER

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def copy(self, pid="DEV_SIM02") -> Path:
        dest = Path(tempfile.mkdtemp(dir=self.tmp)) / pid
        shutil.copytree(self.root / pid, dest)
        return dest

    def edit_csv(self, path: Path, fn):
        with path.open(newline="") as f:
            rows = list(csv.reader(f))
        fn(rows)
        with path.open("w", newline="") as f:
            csv.writer(f, lineterminator="\n").writerows(rows)

    def col(self, name, table):
        return [c.name for c in game_schema.TABLES[table]].index(name)

    def assert_issue(self, folder, text, level="ERROR"):
        msgs = [str(i) for i in validate_game_session(folder) if i.level == level]
        self.assertTrue(any(text in m for m in msgs), f"'{text}' を含む {level} がない: {msgs}")

    # --- そのままのデータ ---

    def test_simulated_data_is_valid(self):
        for pid in ["DEV_SIM01", "DEV_SIM02"]:
            issues = validate_game_session(self.root / pid)
            self.assertEqual(errors(issues) + warns(issues), [], pid)

    def test_resumed_session(self):
        g = load_game_session(self.root / "DEV_SIM01")
        self.assertIn("session_resume", set(g.events["event_type"].astype(str)))
        self.assertIn("app_launch", set(g.events["event_type"].astype(str)))

    def test_loaded_types(self):
        g = load_game_session(self.root / "DEV_SIM02")
        self.assertEqual(str(g.touches["down_mono_ms"].dtype), "int64")
        self.assertEqual(str(g.touches["round_index"].dtype), "Int64")
        self.assertEqual(str(g.touches["down_x"].dtype), "float64")
        self.assertEqual(list(g.rounds["game"].cat.categories), list(game_schema.GAMES))
        self.assertEqual(str(g.motion["acc_x"].dtype), "float64")
        self.assertTrue(set(g.rounds["game"].astype(str)) <= {"stack", "merge"})
        self.assertIsNone(load_game_session(self.root / "DEV_SIM02", load_motion=False).motion)

    def test_load_sessions_and_combine(self):
        sessions = load_game_sessions(self.tmp / "orig", load_motion=False)
        self.assertEqual([s.participant_id for s in sessions], ["DEV_SIM01", "DEV_SIM02"])
        self.assertEqual(load_game_sessions(self.tmp / "orig", include_dev=False), [])
        t = combine_game(sessions)
        self.assertEqual(set(t["rounds"]["participant_id"]), {"DEV_SIM01", "DEV_SIM02"})
        self.assertEqual(list(t["rounds"]["game"].cat.categories), list(game_schema.GAMES))

    def test_round_seeds_follow_config(self):
        g = load_game_session(self.root / "DEV_SIM02", load_motion=False)
        base = g.config["base_seed"]
        for _, row in g.rounds.iterrows():
            self.assertEqual(row["round_seed"], round_seed(base, row["round_index"]))

    # --- 壊したデータが検出されること ---

    def test_detects_wrong_merge_score(self):
        f = self.copy()
        game, score = self.col("game", "game_rounds.csv"), self.col("score_end", "game_rounds.csv")

        def change(rows):
            i = next(k for k, r in enumerate(rows) if k > 0 and r[game] == "merge")
            rows[i][score] = str(int(rows[i][score]) + 4)
        self.edit_csv(f / "game_rounds.csv", change)
        self.assert_issue(f, "再現した得点")

    def test_detects_missing_touch(self):
        f = self.copy()
        self.edit_csv(f / "game_touches.csv", lambda rows: rows.pop(3))
        self.assert_issue(f, "touch_index が 0 から連続していません")

    def test_detects_wrong_best_before(self):
        f = self.copy()
        best = self.col("best_before", "game_rounds.csv")
        self.edit_csv(f / "game_rounds.csv", lambda rows: rows[-1].__setitem__(best, "9999"))
        self.assert_issue(f, "best_before")

    def test_detects_motion_gap(self):
        f = self.copy()
        idx = self.col("sample_index", "game_motion.csv")

        def drop(rows):
            del rows[1000:1100]  # 2秒分を抜き、番号を振り直す
            for k, r in enumerate(rows[1:]):
                r[idx] = str(k)
        self.edit_csv(f / "game_motion.csv", drop)
        self.assert_issue(f, "以上空いた所", level="WARN")

    def test_detects_wrong_app_kind_and_incomplete(self):
        f = self.copy()
        meta = json.loads((f / "game_meta.json").read_text())
        meta["app_kind"] = "task"
        meta["completed"] = False
        (f / "game_meta.json").write_text(json.dumps(meta, ensure_ascii=False))
        self.assert_issue(f, "app_kind")
        self.assert_issue(f, "記録が終了していません")

    def test_detects_unknown_touch_type(self):
        f = self.copy()
        t = self.col("touch_type", "game_touches.csv")
        self.edit_csv(f / "game_touches.csv", lambda rows: rows[2].__setitem__(t, "pinch"))
        self.assert_issue(f, "決まった値以外")


class MergeGameGoldenTest(unittest.TestCase):
    """基準ファイル (Swift のテストも読む) と、いまの merge_game.py が同じ盤を作ること。"""

    def test_matches_golden(self):
        with GOLDEN.open() as f:
            rows = list(csv.DictReader(f))
        game = None
        for r in rows:
            if r["step"] == "0":
                game = MergeGame(int(r["seed"]))
            else:
                moved, _ = game.move(r["direction"])
                self.assertEqual(int(moved), int(r["moved"]))
            self.assertEqual(" ".join(map(str, game.board)), r["board"])
            self.assertEqual(game.score, int(r["score"]))


class GameSchemaMatchesSwiftTest(unittest.TestCase):
    """Python 側の定義が、アプリ側 (GameRecords.swift) と食い違っていないこと。"""

    def setUp(self):
        self.src = GAME_RECORDS_SWIFT.read_text(encoding="utf-8")

    def swift_columns(self, struct):
        body = self.src.split(f"struct {struct}")[1]
        block = re.search(r"static let columns = \[(.*?)\]", body, re.S).group(1)
        return re.findall(r'"([a-z_]+)"', block)

    def test_columns(self):
        for struct, table in [("GameEventRecord", "game_events.csv"), ("RoundRecord", "game_rounds.csv"),
                              ("TouchRecord", "game_touches.csv"), ("MotionRecord", "game_motion.csv")]:
            self.assertEqual(self.swift_columns(struct), [c.name for c in game_schema.TABLES[table]], table)

    def enum_values(self, name):
        body = self.src.split(f"enum {name}")[1].split("\n}")[0]
        body = body.split("public static func")[0].split("public var")[0]
        return [m.group(2) or m.group(1) for m in re.finditer(r'case (\w+)(?: = "([a-z_]+)")?', body)]

    def test_enums(self):
        self.assertEqual(tuple(self.enum_values("GameEventType")), game_schema.GAME_EVENT_TYPES)
        self.assertEqual(tuple(self.enum_values("RoundEndReason")), game_schema.ROUND_END_REASONS)
        self.assertEqual(tuple(self.enum_values("TouchType")), game_schema.TOUCH_TYPES)


if __name__ == "__main__":
    unittest.main()
