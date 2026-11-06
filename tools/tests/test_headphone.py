"""AirPods の記録テスト (exp2/headphone.py、tools/check_headphone_test.py) のテスト。

課題アプリが書くのと同じ形の疑似の記録 (50 Hz で 90 秒、受け取りは30秒ごとに 1 秒止まり、途中で 3 秒切断) を作り、
まとめの数字が筋書きどおりになるかを確かめる。

    .venv/bin/python -m unittest discover -s tools/tests
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from exp2.headphone import (  # noqa: E402
    EVENTS_FILE,
    META_FILE,
    MOTION_FILE,
    compare_magnitudes,
    load_headphone_test,
    summarize_imu_db,
    summarize_test,
)

TOOLS = Path(__file__).resolve().parents[1]
UNIX0 = 1_793_000_000_000
MONO0 = 5_000_000


def make_test_folder(root: Path) -> Path:
    """センサの時刻は 20 ms おき。45〜48 秒は切断でサンプルがない。
    受け取りはふだん 30 ms 遅れ、30 秒と 60 秒の直後 1 秒は止まり、止まりの終わりにまとめて届く。"""
    folder = root / "IMUTEST_20261104_153012"
    folder.mkdir()
    sensor = np.arange(0, 90_000, 20)
    sensor = sensor[(sensor < 45_000) | (sensor >= 48_000)]
    recv = sensor + 30
    for stall in (30_000, 60_000):
        held = (sensor >= stall) & (sensor < stall + 1_000)
        recv[held] = stall + 1_000 + 30
    n = len(sensor)
    rng = np.random.default_rng(1)
    motion = pd.DataFrame({
        "participant_id": folder.name, "sample_index": np.arange(n),
        "unix_ms": UNIX0 + sensor, "mono_ms": MONO0 + sensor, "sensor_ts_ms": (MONO0 + sensor).astype(float),
        "recv_unix_ms": UNIX0 + recv, "recv_mono_ms": MONO0 + recv,
        "sensor_location": np.where(sensor < 70_000, "right", "left"),
        "acc_x": rng.normal(0, 0.01, n), "acc_y": rng.normal(0, 0.01, n), "acc_z": rng.normal(0, 0.01, n),
        "grav_x": 0.0, "grav_y": -0.3, "grav_z": -np.sqrt(1 - 0.09),
        "rot_x": rng.normal(0, 0.1, n), "rot_y": rng.normal(0, 0.1, n), "rot_z": rng.normal(0, 0.1, n),
        "quat_w": 1.0, "quat_x": 0.0, "quat_y": 0.0, "quat_z": 0.0,
        "pitch": -0.3, "roll": 0.0, "yaw": 0.0,
    })
    motion.to_csv(folder / MOTION_FILE, index=False)
    events = pd.DataFrame([
        ("record_start", -500, "audio_route=AirPods:BluetoothA2DPOutput"),
        ("motion_start", -400, "reason=record_start"),
        ("disconnected", 45_010, ""),
        ("connected", 47_990, ""),
        ("location_change", 70_000, "from=right to=left"),
        ("record_stop", 90_100, "samples=%d" % n),
    ], columns=["event_type", "t", "detail"])
    events.insert(0, "participant_id", folder.name)
    events.insert(1, "event_index", range(len(events)))
    events.insert(2, "unix_ms", UNIX0 + events["t"])
    events.insert(3, "mono_ms", MONO0 + events["t"])
    events.drop(columns="t").to_csv(folder / EVENTS_FILE, index=False)
    (folder / META_FILE).write_text(json.dumps({"test_id": folder.name, "config": {"gap_threshold_ms": 500}}))
    return folder


class HeadphoneTestSummaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = make_test_folder(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_summary(self):
        s = summarize_test(load_headphone_test(self.folder))
        self.assertAlmostEqual(s["duration_min"], 89_980 / 60_000)
        self.assertAlmostEqual(s["mean_hz"], 4_349 / 89.98)  # 3 秒の切断の分 (150 サンプル) だけ 50 Hz より少ない
        self.assertEqual(s["per_second_median"], 50)
        self.assertEqual(s["per_second_min"], 0)
        # センサの時刻の空きは切断の1回だけ。受け取った時刻は、止まり2回と切断1回
        self.assertEqual(s["sensor_gap"], {"max_ms": 3_020.0, "n_over": 1})
        self.assertEqual(s["recv_gap"]["n_over"], 3)
        self.assertEqual(s["recv_stalls_sensor_continuous"], 2)
        self.assertEqual(s["latency_ms"]["median"], 30)
        self.assertEqual(s["latency_ms"]["max"], 1_030)
        self.assertEqual(s["sensor_non_increasing"], 0)
        self.assertTrue(s["sample_index_ok"])
        self.assertEqual(s["location_changes"], 1)
        self.assertEqual(s["event_counts"]["disconnected"], 1)

    def test_compare_with_imu_app(self):
        t = load_headphone_test(self.folder)
        m = t.motion
        # 既存の IMU アプリの形 (load_imu_sqlite の表) に、同じ値を写す
        imu = pd.DataFrame({
            "unix_ms": m["recv_unix_ms"], "ZLOCATION": np.where(m["sensor_location"] == "right", 2, 1),
            "ZROTATION_X": m["rot_x"], "ZROTATION_Y": m["rot_y"], "ZROTATION_Z": m["rot_z"],
            "ZUSER_ACC_X": m["acc_x"], "ZUSER_ACC_Y": m["acc_y"], "ZUSER_ACC_Z": m["acc_z"],
            "ZGRAVITY_X": m["grav_x"], "ZGRAVITY_Y": m["grav_y"], "ZGRAVITY_Z": m["grav_z"],
            "ZATT_PITCH": m["pitch"], "ZATT_ROLL": m["roll"],
        })
        b = summarize_imu_db(imu)
        self.assertEqual(b["recv_gap"]["n_over"], 3)
        self.assertEqual(b["location_counts"]["right"], int((m["sensor_location"] == "right").sum()))
        cmp = compare_magnitudes(m, imu)
        np.testing.assert_allclose(cmp["app_median"], cmp["imu_app_median"])
        gravity = cmp[cmp["value"] == "|gravity (G)|"].iloc[0]
        self.assertAlmostEqual(gravity["app_median"], 1.0)

    def test_session_folder(self):
        """本番の被験者フォルダ (test_meta.json がなく meta.json がある) も読め、設定は config_snapshot.headphone から取る"""
        (self.folder / META_FILE).unlink()
        (self.folder / "meta.json").write_text(json.dumps(
            {"participant_id": "P01", "config_snapshot": {"headphone": {"gap_threshold_ms": 2_000}}}))
        t = load_headphone_test(self.folder)
        self.assertEqual(t.gap_threshold_ms, 2_000)
        self.assertEqual(summarize_test(t)["sensor_gap"]["n_over"], 1)

    def test_script_runs(self):
        fig = Path(self.tmp.name) / "fig.png"
        out = subprocess.run([sys.executable, str(TOOLS / "check_headphone_test.py"), str(self.folder), "--figure", str(fig)],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("うち、センサの時刻は続いていた 2 回", out)
        self.assertIn("disconnected", out)
        try:
            import matplotlib  # noqa: F401
        except ImportError:
            return
        self.assertTrue(fig.exists())


if __name__ == "__main__":
    unittest.main()
