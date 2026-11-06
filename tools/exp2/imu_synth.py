"""AirPods の IMU の疑似データを作る。分析コードの通し確認用。

正解のファイル (exp2-simulate --app joint が書く truth/<ID>.csv) の状態と、課題アプリの頭振りの合図
(shake_prompt_on) から、頭の姿勢と動きを作る。書く形は2つ:
- synthesize_headphone: 課題アプリが被験者フォルダに書く形 (headphone_motion.csv、headphone_events.csv。
  2026-11-04 からの本番の形、app_decisions #72)。時刻は iPad の時計で、センサの時刻と受け取った時刻の両方を持つ
- synthesize_imu: 既存の IMU アプリと同じ形の SQLite (テーブル ZSENSINGHEADPHONEMOTION、ZTIMESTAMP は
  Unix ミリ秒の文字列)。列の形は samples/imu_sample.db (実験1のときの記録) に合わせた。予備の経路の確認用

頭の動きの大きさは、それらしく見える程度の仮の値で、意味はない。状態ごとの違いの向きだけをそろえた:
- 計算中: 少しうつむいて (iPad を見る)、ほぼ静か
- ゲーム中: 深くうつむいて (手元の iPhone を見る)、計算中より少し揺れる。持ち上げる瞬間に頭が下を向く
- どちらでもない: あまりうつむかず、ときどき周りを見る (左右に向く)
- 頭振りの合図: 合図の約1秒後から、左右に大きく振る

本物の IMU アプリの癖 (docs/data_spec.md 6章) も再現できる: 約30秒ごとに受信が止まり、止まった間のサンプルは
止まりが終わった時刻でまとめて入る (サンプル自体は欠けない)。止まりの長さは記録が進むにつれて伸びる。
課題アプリの形では、止まりは受け取った時刻 (recv_*) にだけ出て、センサの時刻は等間隔のまま。
"""

from __future__ import annotations

import sqlite3
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

# samples/imu_sample.db と同じ表の定義
CREATE_TABLE = (
    "CREATE TABLE ZSENSINGHEADPHONEMOTION ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
    "ZDATA_LINES INTEGER, ZLOCATION INTEGER, ZMAG_ACCURACY INTEGER, ZATT_PITCH FLOAT, ZATT_Q_W FLOAT, "
    "ZATT_Q_X FLOAT, ZATT_Q_Y FLOAT, ZATT_Q_Z FLOAT, ZATT_RM_M11 FLOAT, ZATT_RM_M12 FLOAT, ZATT_RM_M13 FLOAT, "
    "ZATT_RM_M21 FLOAT, ZATT_RM_M22 FLOAT, ZATT_RM_M23 FLOAT, ZATT_RM_M31 FLOAT, ZATT_RM_M32 FLOAT, "
    "ZATT_RM_M33 FLOAT, ZATT_ROLL FLOAT, ZATT_YAW FLOAT, ZGRAVITY_X FLOAT, ZGRAVITY_Y FLOAT, ZGRAVITY_Z FLOAT, "
    "ZHEADING FLOAT, ZMAG_X FLOAT, ZMAG_Y FLOAT, ZMAG_Z FLOAT, ZROTATION_X FLOAT, ZROTATION_Y FLOAT, "
    "ZROTATION_Z FLOAT, ZUSER_ACC_X FLOAT, ZUSER_ACC_Y FLOAT, ZUSER_ACC_Z FLOAT, ZDEVICE_ID VARCHAR, "
    "ZLABEL VARCHAR, ZTIMESTAMP VARCHAR )"
)
COLUMNS = [
    "Z_PK", "Z_ENT", "Z_OPT", "ZDATA_LINES", "ZLOCATION", "ZMAG_ACCURACY", "ZATT_PITCH", "ZATT_Q_W", "ZATT_Q_X",
    "ZATT_Q_Y", "ZATT_Q_Z", "ZATT_RM_M11", "ZATT_RM_M12", "ZATT_RM_M13", "ZATT_RM_M21", "ZATT_RM_M22",
    "ZATT_RM_M23", "ZATT_RM_M31", "ZATT_RM_M32", "ZATT_RM_M33", "ZATT_ROLL", "ZATT_YAW", "ZGRAVITY_X",
    "ZGRAVITY_Y", "ZGRAVITY_Z", "ZHEADING", "ZMAG_X", "ZMAG_Y", "ZMAG_Z", "ZROTATION_X", "ZROTATION_Y",
    "ZROTATION_Z", "ZUSER_ACC_X", "ZUSER_ACC_Y", "ZUSER_ACC_Z", "ZDEVICE_ID", "ZLABEL", "ZTIMESTAMP",
]


@dataclass
class ImuSynthConfig:
    hz: int = 50
    # 課題アプリの記録の前後に、IMU の記録が伸びている長さ (装着して記録を始めてから課題アプリを始めるまで、など)
    lead_ms: int = 20_000
    tail_ms: int = 20_000
    # 状態ごとの頭の前後の傾き (rad、負がうつむき) と揺れ (角速度の標準偏差 rad/s、加速度の標準偏差 G)
    pitch: tuple[tuple[str, float], ...] = (("compute", -0.30), ("game", -0.75), ("idle", -0.12), ("other", -0.20))
    rot_sigma: tuple[tuple[str, float], ...] = (("compute", 0.03), ("game", 0.08), ("idle", 0.15), ("other", 0.10))
    acc_sigma: tuple[tuple[str, float], ...] = (("compute", 0.004), ("game", 0.012), ("idle", 0.02), ("other", 0.015))
    # 姿勢が目標に近づく速さ (時定数 s)
    posture_tau_s: float = 0.4
    # 頭振り: 合図から振り始めるまで (反応時間)、振る長さ、振れ幅 (rad)、速さ (Hz)
    shake_delay_ms: int = 1_000
    shake_ms: int = 2_500
    shake_amp_rad: float = 0.6
    shake_hz: float = 2.0
    # 受信の止まり (本物の IMU アプリの癖)
    stalls: bool = True
    stall_interval_ms: int = 30_000
    stall_ms_start: int = 700
    stall_ms_growth_per_min: float = 50.0
    device_id: str = "00000000-0000-4000-8000-00000000a1b2"


def _quaternion(yaw: np.ndarray, pitch: np.ndarray, roll: np.ndarray) -> np.ndarray:
    """オイラー角 (yaw-pitch-roll の順) から四元数 (w, x, y, z)。"""
    cy, sy = np.cos(yaw / 2), np.sin(yaw / 2)
    cp, sp = np.cos(pitch / 2), np.sin(pitch / 2)
    cr, sr = np.cos(roll / 2), np.sin(roll / 2)
    return np.stack([
        cr * cp * cy + sr * sp * sy,
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
    ], axis=1)


def _rotation_matrix(q: np.ndarray) -> np.ndarray:
    w, x, y, z = q.T
    return np.stack([
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
        2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
    ], axis=1)


def _synthesize(truth: pd.DataFrame, shake_unix_ms: list[int], start_unix_ms: int, end_unix_ms: int,
                seed: int, cfg: ImuSynthConfig) -> dict[str, np.ndarray]:
    """頭の動きを作る。t は測った本当の時刻 (= iPad の時計の Unix ms、小数)、received は受け取った時刻。"""
    rng = np.random.default_rng(seed)
    step = 1000 / cfg.hz
    t = np.arange(start_unix_ms, end_unix_ms, step)
    n = len(t)

    # その時刻の状態 (直前の正解の行)。iPhone を手に持っていればゲーム中とする
    idx = np.searchsorted(truth["true_unix_ms"].to_numpy(), t, side="right") - 1
    idx = np.clip(idx, 0, len(truth) - 1)
    state = truth["state"].to_numpy()[idx].astype(object)
    holding = truth["holding"].to_numpy()[idx] == 1
    state = np.where(holding, "game", np.where(state == "game", "other", state))
    state = np.where(t < truth["true_unix_ms"].iloc[0], "other", state)

    def by_state(table):
        m = dict(table)
        return np.array([m.get(s, m["other"]) for s in state])

    # 姿勢: 目標の傾きに一次遅れで近づく。どちらでもないときは、ときどき左右を見る
    target_pitch = by_state(cfg.pitch)
    alpha = 1 - np.exp(-(step / 1000) / cfg.posture_tau_s)
    pitch = np.empty(n)
    p = target_pitch[0]
    for i in range(n):
        p += alpha * (target_pitch[i] - p)
        pitch[i] = p
    look = np.zeros(n)
    yaw_target = 0.0
    for i in range(n):
        if state[i] == "idle" and rng.random() < 1 / (cfg.hz * 4):
            yaw_target = rng.uniform(-0.8, 0.8)
        elif state[i] != "idle":
            yaw_target = 0.0
        look[i] = (look[i - 1] if i else 0.0) + alpha * (yaw_target - (look[i - 1] if i else 0.0))
    rot_sigma = by_state(cfg.rot_sigma)
    yaw = look + 1.45 + np.cumsum(rng.normal(0, 1, n) * rot_sigma * 0.002)
    roll = 0.30 + np.cumsum(rng.normal(0, 1, n) * rot_sigma * 0.002)
    pitch = pitch + np.cumsum(rng.normal(0, 1, n) * rot_sigma * 0.002) * 0.2

    # 頭振り
    acc_sigma = by_state(cfg.acc_sigma)
    for s in shake_unix_ms:
        a = s + cfg.shake_delay_ms
        m = (t >= a) & (t < a + cfg.shake_ms)
        yaw[m] += cfg.shake_amp_rad * np.sin(2 * np.pi * cfg.shake_hz * (t[m] - a) / 1000)
        acc_sigma = np.where(m, 0.3, acc_sigma)

    rot = np.stack([np.gradient(pitch), np.gradient(roll), np.gradient(yaw)], axis=1) * (1000 / step)
    rot += rng.normal(0, 1, (n, 3)) * rot_sigma[:, None]
    acc = rng.normal(0, 1, (n, 3)) * acc_sigma[:, None]
    q = _quaternion(yaw, pitch, roll)
    rm = _rotation_matrix(q)
    gravity = -rm[:, 6:9]

    # 受信の時刻。止まりの間のサンプルは、止まりが終わった時刻でまとめて入る
    received = t.copy()
    if cfg.stalls:
        k = 1
        while start_unix_ms + k * cfg.stall_interval_ms < end_unix_ms:
            s0 = start_unix_ms + k * cfg.stall_interval_ms
            length = cfg.stall_ms_start + cfg.stall_ms_growth_per_min * (k * cfg.stall_interval_ms / 60_000)
            m = (t >= s0) & (t < s0 + length)
            received[m] = s0 + length
            k += 1
    return {"t": t, "received": received, "pitch": pitch, "roll": roll, "yaw": yaw, "q": q, "rm": rm,
            "gravity": gravity, "rot": rot, "acc": acc}


def synthesize_imu(truth: pd.DataFrame, shake_unix_ms: list[int], start_unix_ms: int, end_unix_ms: int,
                   seed: int, unix_offset_ms: int = 0, cfg: ImuSynthConfig | None = None) -> pd.DataFrame:
    """既存の IMU アプリの形の表 (COLUMNS の列) を作る。

    truth: true_unix_ms, state, holding の列 (100 ms ごと)。本当の時刻 (= iPad の時計)
    shake_unix_ms: 課題アプリの shake_prompt_on の時刻
    unix_offset_ms: IMU の端末の時計のずれ (ZTIMESTAMP にだけ足す)
    """
    cfg = cfg or ImuSynthConfig()
    a = _synthesize(truth, shake_unix_ms, start_unix_ms, end_unix_ms, seed, cfg)
    n = len(a["t"])
    pitch, roll, yaw, q, rm, gravity, rot, acc = (a[k] for k in ["pitch", "roll", "yaw", "q", "rm", "gravity", "rot", "acc"])
    timestamps = (np.floor(a["received"]) + unix_offset_ms).astype(np.int64)

    return pd.DataFrame({
        "Z_PK": np.arange(1, n + 1), "Z_ENT": 1, "Z_OPT": 1, "ZDATA_LINES": np.arange(1, n + 1),
        "ZLOCATION": 2, "ZMAG_ACCURACY": -1, "ZATT_PITCH": pitch,
        "ZATT_Q_W": q[:, 0], "ZATT_Q_X": q[:, 1], "ZATT_Q_Y": q[:, 2], "ZATT_Q_Z": q[:, 3],
        **{f"ZATT_RM_M{r}{c}": rm[:, (r - 1) * 3 + (c - 1)] for r in (1, 2, 3) for c in (1, 2, 3)},
        "ZATT_ROLL": roll, "ZATT_YAW": yaw,
        "ZGRAVITY_X": gravity[:, 0], "ZGRAVITY_Y": gravity[:, 1], "ZGRAVITY_Z": gravity[:, 2],
        "ZHEADING": -1.0, "ZMAG_X": 0.0, "ZMAG_Y": 0.0, "ZMAG_Z": 0.0,
        "ZROTATION_X": rot[:, 0], "ZROTATION_Y": rot[:, 1], "ZROTATION_Z": rot[:, 2],
        "ZUSER_ACC_X": acc[:, 0], "ZUSER_ACC_Y": acc[:, 1], "ZUSER_ACC_Z": acc[:, 2],
        "ZDEVICE_ID": cfg.device_id, "ZLABEL": None, "ZTIMESTAMP": timestamps.astype(str),
    })[COLUMNS]


def write_imu_sqlite(df: pd.DataFrame, path: str | Path) -> None:
    """IMU アプリと同じ形の SQLite に書く。既にあれば止める (上書きしない)。"""
    path = Path(path)
    if path.exists():
        raise FileExistsError(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as con:
        con.execute(CREATE_TABLE)
        # 表の定義 (列の型) は本物と同じにし、行は pandas に入れてもらう (numpy の数の型を変換してくれる)
        df.to_sql("ZSENSINGHEADPHONEMOTION", con, if_exists="append", index=False)
        con.commit()


def synthesize_headphone(truth: pd.DataFrame, shake_unix_ms: list[int], start: dict, end_unix_ms: int,
                         participant_id: str, seed: int, cfg: ImuSynthConfig | None = None,
                         reference_hz: float = 50.0) -> tuple[pd.DataFrame, pd.DataFrame]:
    """課題アプリが被験者フォルダに書く形 (headphone_motion.csv、headphone_events.csv) の表を作る。

    start: 記録を始めた瞬間 ({"unix_ms", "mono_ms"}、セッションを作った瞬間。meta.json の created_at)。
    課題アプリと同じ iPad の時計なので、時計のずれはない。最初のサンプルは受け取りを始めてから約1秒後に届く。
    cfg.stalls なら、受け取った時刻だけが約30秒ごとに止まる (センサの時刻は続く。2026-11-04 の実機の試験と同じ)。
    """
    cfg = cfg or ImuSynthConfig()
    first_unix = int(start["unix_ms"]) + 1_000
    a = _synthesize(truth, shake_unix_ms, first_unix, end_unix_ms, seed, cfg)
    n = len(a["t"])
    mono_offset = int(start["unix_ms"]) - int(start["mono_ms"])
    unix = np.floor(a["t"]).astype(np.int64)
    # 受け取りの遅れはふだん 20〜40 ms (試験の中央値 34 ms)。止まりの間は、止まりが終わるまで遅れる
    recv = np.maximum(np.floor(a["received"]).astype(np.int64), unix + 20) + np.random.default_rng(seed + 1).integers(0, 20, n)
    recv = np.maximum.accumulate(recv)
    motion = pd.DataFrame({
        "participant_id": participant_id, "sample_index": np.arange(n),
        "unix_ms": unix, "mono_ms": unix - mono_offset, "sensor_ts_ms": (unix - mono_offset) + 0.25,
        "recv_unix_ms": recv, "recv_mono_ms": recv - mono_offset, "sensor_location": "right",
        "acc_x": a["acc"][:, 0], "acc_y": a["acc"][:, 1], "acc_z": a["acc"][:, 2],
        "grav_x": a["gravity"][:, 0], "grav_y": a["gravity"][:, 1], "grav_z": a["gravity"][:, 2],
        "rot_x": a["rot"][:, 0], "rot_y": a["rot"][:, 1], "rot_z": a["rot"][:, 2],
        "quat_w": a["q"][:, 0], "quat_x": a["q"][:, 1], "quat_y": a["q"][:, 2], "quat_z": a["q"][:, 3],
        "pitch": a["pitch"], "roll": a["roll"], "yaw": a["yaw"],
    })
    t0 = int(start["unix_ms"])
    t_end = int(recv[-1]) + 10 if n else end_unix_ms
    rows = [
        (t0, "record_start", "reason=session_create audio_route=AirPods:BluetoothA2DPOutput"),
        (t0, "authorization", "status=authorized"),
        (t0, "connected", "at_record_start"),
        (t0 + 1, "motion_start", "reason=record_start"),
        (t_end, "motion_stop", "reason=record_stop"),
        (t_end, "record_stop", f"samples={n}"),
    ]
    events = pd.DataFrame(rows, columns=["unix_ms", "event_type", "detail"])
    events.insert(0, "participant_id", participant_id)
    events.insert(1, "event_index", range(len(events)))
    events.insert(3, "mono_ms", events["unix_ms"] - mono_offset)
    return motion, events


def write_headphone_csv(motion: pd.DataFrame, events: pd.DataFrame, folder: str | Path) -> None:
    """被験者フォルダに課題アプリと同じ形で書く (値は小数5桁、センサの時刻は3桁)。既にあれば止める (上書きしない)。"""
    folder = Path(folder)
    for name in ("headphone_motion.csv", "headphone_events.csv"):
        if (folder / name).exists():
            raise FileExistsError(folder / name)
    m = motion.copy()
    value_cols = [c for c in m.columns if c not in ("participant_id", "sample_index", "unix_ms", "mono_ms",
                                                     "sensor_ts_ms", "recv_unix_ms", "recv_mono_ms", "sensor_location")]
    for c in value_cols:
        m[c] = m[c].map(lambda v: "0.00000" if abs(v) < 0.000005 else f"{v:.5f}")
    m["sensor_ts_ms"] = m["sensor_ts_ms"].map(lambda v: f"{v:.3f}")
    m.to_csv(folder / "headphone_motion.csv", index=False, lineterminator="\n")
    events.to_csv(folder / "headphone_events.csv", index=False, lineterminator="\n")
