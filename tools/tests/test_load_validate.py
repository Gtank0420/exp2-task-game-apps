"""読み込み関数 (exp2/load.py) と検証 (exp2/validate.py) のテスト。

疑似参加者のデータを exp2-simulate (Swift) で一時フォルダに作り、
そのままなら検証を通ること、わざと壊すと検出されることを確かめる。

    .venv/bin/python -m unittest discover -s tools/tests
"""

import csv
import json
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pandas as pd  # noqa: E402

from exp2 import schema  # noqa: E402
from exp2.load import combine, load_session, load_sessions, meta_frame  # noqa: E402
from exp2.validate import validate_session  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[2]
RECORDS_SWIFT = APP_ROOT / "Packages/ExperimentCore/Sources/ExperimentCore/Records.swift"
HEADPHONE_SWIFT = APP_ROOT / "Packages/ExperimentCore/Sources/ExperimentCore/HeadphoneMotion.swift"


def errors(issues):
    return [i for i in issues if i.level == "ERROR"]


def warns(issues):
    return [i for i in issues if i.level == "WARN"]


@unittest.skipUnless(shutil.which("swift"), "swift がないので疑似データを作れない")
class LoadValidateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="exp2-pytest-"))
        # 2人分、区間を短縮。1人目は自由区間の 25 秒で落ちて再開する
        subprocess.run(
            ["swift", "run", "--package-path", str(APP_ROOT / "Packages/ExperimentCore"), "exp2-simulate",
             "--out", str(cls.tmp / "orig"), "--n", "2", "--short", "--interrupt-free-at-ms", "25000"],
            check=True, capture_output=True,
        )
        cls.root = cls.tmp / "orig" / schema.DATA_FOLDER

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def copy(self, pid="DEV_SIM02") -> Path:
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

    def edit_meta(self, folder: Path, fn):
        meta = json.loads((folder / "meta.json").read_text())
        fn(meta)
        (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))

    def col(self, name, table):
        return [c.name for c in schema.TABLES[table]].index(name)

    # --- そのままのデータ ---

    def test_simulated_data_is_valid(self):
        for pid in ["DEV_SIM01", "DEV_SIM02"]:
            issues = validate_session(self.root / pid)
            self.assertEqual(errors(issues) + warns(issues), [], pid)
            # 疑似参加者は記録処理だけを動かすので、AirPods の記録はない (INFO で知らせる)
            self.assertTrue(any("AirPods の記録はありません" in i.message for i in issues))

    def test_interrupted_session_has_two_free_parts(self):
        s = load_session(self.root / "DEV_SIM01")
        free = s.segments[s.segments["segment"] == "free"]
        self.assertEqual(list(free["end_reason"]), ["interrupted", "timeout"])
        self.assertEqual(free.iloc[0]["end_elapsed_ms"], free.iloc[1]["start_elapsed_ms"])
        self.assertIn("session_resume", set(s.events["event_type"]))
        infos = [i.message for i in validate_session(self.root / "DEV_SIM01") if i.level == "INFO"]
        self.assertTrue(any("中断 1 回" in m for m in infos))

    def test_loaded_types(self):
        s = load_session(self.root / "DEV_SIM02")
        self.assertEqual(str(s.items["shown_unix_ms"].dtype), "int64")
        self.assertEqual(str(s.items["response"].dtype), "Int64")
        self.assertEqual(str(s.items["is_correct"].dtype), "boolean")
        self.assertTrue(s.items["segment"].cat.ordered)
        self.assertEqual(list(s.items["segment"].cat.categories), schema.SEGMENT_ORDER)
        self.assertEqual(str(s.events["part"].dtype), "Int64")
        self.assertEqual(s.planned_duration_ms("free"), 60_000)

    def test_load_sessions_combine_and_meta(self):
        sessions = load_sessions(self.tmp / "orig")
        self.assertEqual([s.participant_id for s in sessions], ["DEV_SIM01", "DEV_SIM02"])
        self.assertEqual(load_sessions(self.tmp / "orig", include_dev=False), [])
        tables = combine(sessions)
        self.assertEqual(set(tables["items"]["participant_id"]), {"DEV_SIM01", "DEV_SIM02"})
        self.assertTrue(tables["items"]["segment"].cat.ordered)
        meta = meta_frame(sessions)
        self.assertEqual(list(meta["participant_id"]), ["DEV_SIM01", "DEV_SIM02"])
        for c in ["oral_q1_observed", "oral_q2_game_fun", "data_consent", "handedness", "created_unix_ms"]:
            self.assertIn(c, meta.columns)

    # --- 壊したデータが検出されること ---

    def assert_error(self, folder, text):
        msgs = [str(i) for i in errors(validate_session(folder))]
        self.assertTrue(any(text in m for m in msgs), f"'{text}' を含むエラーがない: {msgs}")

    def test_detects_missing_item_row(self):
        f = self.copy()
        self.edit_csv(f / "items.csv", lambda rows: rows.pop(5))
        self.assert_error(f, "item_index が 0 から連続していません")

    def test_detects_changed_problem(self):
        f = self.copy()
        a = self.col("a", "items.csv")

        def change(rows):
            rows[3][a] = "2" if rows[3][a] != "2" else "3"
            b = self.col("b", "items.csv")
            rows[3][self.col("correct_answer", "items.csv")] = str((int(rows[3][a]) + int(rows[3][b])) % 10)
        self.edit_csv(f / "items.csv", change)
        self.assert_error(f, "乱数の種")

    def test_detects_wrong_rt(self):
        f = self.copy()
        rt = self.col("rt_ms", "items.csv")
        self.edit_csv(f / "items.csv", lambda rows: rows[2].__setitem__(rt, str(int(rows[2][rt]) + 50)))
        self.assert_error(f, "rt_ms が answered_mono_ms")

    def test_detects_wrong_header(self):
        f = self.copy()
        self.edit_csv(f / "events.csv", lambda rows: rows[0].__setitem__(2, "unix_time"))
        self.assert_error(f, "列が定義と違います")

    def test_detects_non_integer_value(self):
        f = self.copy()
        a = self.col("a", "items.csv")
        self.edit_csv(f / "items.csv", lambda rows: rows[1].__setitem__(a, "x"))
        self.assert_error(f, "整数でない値")

    def test_detects_mono_going_back(self):
        f = self.copy()
        mono = self.col("mono_ms", "events.csv")
        self.edit_csv(f / "events.csv", lambda rows: rows[10].__setitem__(mono, "0"))
        self.assert_error(f, "単調時刻が戻っています")

    def test_detects_wrong_segment_length(self):
        f = self.copy()
        end = self.col("end_elapsed_ms", "segments.csv")
        self.edit_csv(f / "segments.csv", lambda rows: rows[1].__setitem__(end, "15000"))
        self.assert_error(f, "区間の長さ")

    def test_detects_incomplete_session(self):
        f = self.copy()
        self.edit_meta(f, lambda m: m.__setitem__("completed", False))
        self.assert_error(f, "完了していません")

    def test_warns_on_refused_consent_and_partial_file(self):
        f = self.copy()
        self.edit_meta(f, lambda m: m.__setitem__("data_consent", False))
        (f / "items.csv.partial_123.txt").write_text("DEV_SIM02,free,0,")
        msgs = [str(i) for i in warns(validate_session(f))]
        self.assertTrue(any("同意がありません" in m for m in msgs))
        self.assertTrue(any("partial_123" in m for m in msgs))
        self.assertEqual(errors(validate_session(f)), [])

    def test_detects_folder_name_mismatch(self):
        f = self.copy()
        renamed = f.parent / "DEV_OTHER"
        f.rename(renamed)
        self.assert_error(renamed, "フォルダ名")

    # --- IMU との突き合わせ ---

    def make_imu(self, path: Path, start_ms: int, end_ms: int, gap_at_ms: int | None = None):
        ts = list(range(start_ms, end_ms, 20))  # 50 Hz
        if gap_at_ms is not None:
            ts = [t for t in ts if not (gap_at_ms <= t < gap_at_ms + 1200)]
        with closing(sqlite3.connect(path)) as con:
            con.execute("CREATE TABLE ZSENSINGHEADPHONEMOTION (Z_PK INTEGER PRIMARY KEY, ZTIMESTAMP VARCHAR)")
            con.executemany("INSERT INTO ZSENSINGHEADPHONEMOTION (ZTIMESTAMP) VALUES (?)", [(str(t),) for t in ts])
            con.commit()

    def test_imu_overlap_and_gaps(self):
        folder = self.root / "DEV_SIM02"
        ev = load_session(folder).events
        start, end = int(ev["unix_ms"].min()), int(ev["unix_ms"].max())
        db = self.tmp / "imu_ok.db"
        self.make_imu(db, start - 10_000, end + 10_000, gap_at_ms=start + 30_000)
        issues = validate_session(folder, imu_db=db)
        self.assertEqual(errors(issues), [])
        self.assertTrue(any("空きが 1 か所" in i.message for i in warns(issues)))

        late = self.tmp / "imu_late.db"
        self.make_imu(late, start + 5_000, end + 10_000)
        self.assertTrue(any("開始が" in i.message for i in warns(validate_session(folder, imu_db=late))))

    def test_imu_sample_from_other_day_does_not_overlap(self):
        sample = APP_ROOT / "samples/imu_sample.db"
        if not sample.exists():
            self.skipTest("samples/imu_sample.db がない")
        msgs = [i.message for i in errors(validate_session(self.root / "DEV_SIM02", imu_db=sample))]
        self.assertTrue(any("重なっていません" in m for m in msgs))


    # --- AirPods の頭の動き (schema_version 4 から被験者フォルダに入る) ---

    def add_headphone(self, folder: Path, gap: tuple[int, int] | None = None, disconnect_at: int | None = None) -> None:
        """課題アプリと同じ形の AirPods の記録を、セッションの作成から最後のイベントまで 50 Hz で足す。
        gap: (始め, 長さ) の ms (セッションの作成からの時刻) のサンプルを抜く。disconnect_at: その時刻に切断と再接続"""
        meta = json.loads((folder / "meta.json").read_text())
        ev = pd.read_csv(folder / "events.csv")
        u0, m0 = meta["created_at"]["unix_ms"], meta["created_at"]["mono_ms"]
        t = pd.Series(range(500, int(ev["unix_ms"].max()) - u0, 20))
        if gap:
            t = t[(t < gap[0]) | (t >= gap[0] + gap[1])].reset_index(drop=True)
        n = len(t)
        motion = pd.DataFrame({
            "participant_id": meta["participant_id"], "sample_index": range(n), "unix_ms": u0 + t, "mono_ms": m0 + t,
            "sensor_ts_ms": [f"{m0 + x + 0.5:.3f}" for x in t], "recv_unix_ms": u0 + t + 30, "recv_mono_ms": m0 + t + 30,
            "sensor_location": "right",
            **{c: "0.00000" for c in ["acc_x", "acc_y", "acc_z", "grav_x", "grav_y", "rot_x", "rot_y", "rot_z",
                                      "quat_x", "quat_y", "quat_z", "pitch", "roll", "yaw"]},
            "grav_z": "-1.00000", "quat_w": "1.00000",
        })[[c.name for c in schema.HEADPHONE_MOTION]]
        rows = [(0, "record_start", "reason=session_create audio_route=AirPods:BluetoothA2DPOutput"),
                (0, "connected", "at_record_start"), (1, "motion_start", "reason=record_start")]
        if disconnect_at is not None:
            rows += [(disconnect_at, "disconnected", ""), (disconnect_at + 3_000, "connected", "")]
        events = pd.DataFrame(sorted(rows), columns=["t", "event_type", "detail"])
        events.insert(0, "participant_id", meta["participant_id"])
        events.insert(1, "event_index", range(len(events)))
        events.insert(2, "unix_ms", u0 + events["t"])
        events.insert(3, "mono_ms", m0 + events["t"])
        motion.to_csv(folder / schema.HEADPHONE_MOTION_FILE, index=False, lineterminator="\n")
        events.drop(columns="t").to_csv(folder / schema.HEADPHONE_EVENTS_FILE, index=False, lineterminator="\n")

    def free_start_ms(self, folder: Path) -> int:
        """自由区間の開始の、セッションの作成からの時刻"""
        meta = json.loads((folder / "meta.json").read_text())
        seg = pd.read_csv(folder / "segments.csv")
        return int(seg[seg["segment"] == "free"]["start_unix_ms"].iloc[0]) - meta["created_at"]["unix_ms"]

    def test_headphone_valid_and_loaded(self):
        folder = self.copy()
        self.add_headphone(folder)
        issues = validate_session(folder)
        self.assertEqual(errors(issues) + warns(issues), [])
        s = load_session(folder)
        self.assertEqual(str(s.headphone["unix_ms"].dtype), "int64")
        self.assertEqual(list(s.headphone["first_after_start"]).index(True), 0)
        self.assertEqual(int(s.headphone["first_after_start"].sum()), 1)
        self.assertEqual(len(s.headphone_events), 3)

    def test_headphone_gap_disconnect_and_missing(self):
        folder = self.copy()
        free0 = self.free_start_ms(folder)
        # 自由区間 (短縮で 60 秒) の始めの 10 秒が欠け、そこで切断と再接続
        self.add_headphone(folder, gap=(free0, 10_000), disconnect_at=free0 + 100)
        msgs = [i.message for i in warns(validate_session(folder))]
        self.assertTrue(any("free" in m and "10% を超えています" in m for m in msgs), msgs)
        self.assertTrue(any("切断が 1 回" in m and "free の 0.0 分" in m for m in msgs), msgs)
        self.assertEqual(int(load_session(folder).headphone["first_after_start"].sum()), 2, "つながり直しの直後も印を付ける")

        # 疑似参加者でないのに記録がなければ ERROR
        bare = self.copy()
        self.edit_meta(bare, lambda m: m["config_snapshot"].pop("simulated_participant"))
        self.assertTrue(any("headphone_motion.csv" in i.message for i in errors(validate_session(bare))))

    def test_headphone_detects_broken_index(self):
        folder = self.copy()
        self.add_headphone(folder)
        self.edit_csv(folder / schema.HEADPHONE_MOTION_FILE, lambda rows: rows.pop(100))
        self.assertTrue(any("sample_index" in i.message for i in errors(validate_session(folder))))


class SchemaMatchesSwiftTest(unittest.TestCase):
    """Python 側の定義が、アプリ側 (Records.swift) と食い違っていないこと。"""

    def setUp(self):
        self.src = RECORDS_SWIFT.read_text(encoding="utf-8")

    def swift_columns(self, struct):
        body = self.src.split(f"struct {struct}")[1]
        block = re.search(r"static let columns = \[(.*?)\]", body, re.S).group(1)
        return re.findall(r'"([a-z_]+)"', block)

    def test_columns(self):
        for struct, table in [("ItemRecord", "items.csv"), ("EventRecord", "events.csv"),
                              ("SegmentRecord", "segments.csv")]:
            self.assertEqual(self.swift_columns(struct), [c.name for c in schema.TABLES[table]], table)

    def test_event_types(self):
        body = self.src.split("enum EventType")[1].split("}")[0]
        self.assertEqual(re.findall(r'case \w+ = "([a-z_]+)"', body), schema.EVENT_TYPES)

    def test_end_reasons(self):
        body = self.src.split("enum SegmentEndReason")[1].split("}")[0]
        self.assertEqual(re.findall(r"case (\w+)", body), schema.END_REASONS)

    def test_headphone(self):
        src = HEADPHONE_SWIFT.read_text(encoding="utf-8")
        for struct, table in [("HeadphoneMotionRecord", schema.HEADPHONE_MOTION), ("HeadphoneEventRecord", schema.HEADPHONE_EVENTS)]:
            body = src.split(f"struct {struct}")[1]
            block = re.search(r"static let columns = \[(.*?)\]", body, re.S).group(1)
            self.assertEqual(re.findall(r'"([a-z_]+)"', block), [c.name for c in table], struct)
        body = src.split("enum HeadphoneEventType")[1].split("\n}")[0]
        names = [m[1] or m[0] for m in re.findall(r'case `?(\w+)`?(?: = "([a-z_]+)")?', body)]
        self.assertEqual(names, list(schema.HEADPHONE_EVENT_TYPES))
        body = src.split("enum HeadphoneSensorLocation")[1].split("public init")[0]
        self.assertEqual(re.findall(r"case `?(\w+)`?", body), list(schema.HEADPHONE_LOCATIONS))


if __name__ == "__main__":
    unittest.main()
