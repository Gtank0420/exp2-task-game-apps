"""課題アプリの「AirPods の記録テスト」(app_decisions #71) の記録を読み、確かめる。
本番のセッションの被験者フォルダ (schema_version 4 から同じ形の2つの CSV が入る。#72) も読める。

記録は exp2_imu_test/<テスト ID>/ にある:
    headphone_motion.csv   1サンプル1行 (センサの時刻 unix_ms/mono_ms/sensor_ts_ms と、受け取った時刻 recv_unix_ms/recv_mono_ms)
    headphone_events.csv   記録の開始・終了、接続・切断、受信の開始・停止、エラー、測っている側の切り替わり
    test_meta.json         端末、アプリの版、設定 (gap_threshold_ms など)

確かめたいこと (本番に組み込む前の試験):
    1. 何 Hz で取れるか (実験1の既存の IMU アプリは平均 50 Hz)
    2. 受け取った時刻の止まり (既存アプリで約30秒ごとにあった) が、センサの時刻にも出るか
    3. 切断と再接続のあと、受信が戻るか
    4. 既存の IMU アプリと同じ大きさの値が出るか (同じ動きを続けて記録したものと比べる)
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

MOTION_FILE = "headphone_motion.csv"
EVENTS_FILE = "headphone_events.csv"
META_FILE = "test_meta.json"


@dataclass
class HeadphoneTest:
    folder: Path
    motion: pd.DataFrame
    events: pd.DataFrame
    meta: dict = field(default_factory=dict)

    @property
    def gap_threshold_ms(self) -> int:
        return int(self.meta.get("config", {}).get("gap_threshold_ms", 500))


def load_headphone_test(folder: str | Path) -> HeadphoneTest:
    """試験の記録フォルダを読む。サンプルはセンサの時刻の順に並べ直さず、書かれた順 (届いた順) のまま返す。
    本番の被験者フォルダなら、設定は meta.json の config_snapshot.headphone から読む。"""
    folder = Path(folder)
    motion = pd.read_csv(folder / MOTION_FILE)
    events = pd.read_csv(folder / EVENTS_FILE, keep_default_na=False)
    meta_path = folder / META_FILE
    session_meta_path = folder / "meta.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    elif session_meta_path.exists():
        session = json.loads(session_meta_path.read_text(encoding="utf-8"))
        meta = {"test_id": session.get("participant_id"),
                "config": (session.get("config_snapshot") or {}).get("headphone") or {}}
    else:
        meta = {}
    return HeadphoneTest(folder, motion, events, meta)


def _gap_summary(diffs: pd.Series, threshold_ms: float) -> dict:
    return {
        "max_ms": float(diffs.max()) if len(diffs) else float("nan"),
        "n_over": int((diffs >= threshold_ms).sum()),
    }


def _per_second(ms: pd.Series) -> pd.Series:
    """1秒ごとのサンプル数 (最初と最後の、途中までしかない1秒は除く)。"""
    sec = ((ms - ms.min()) // 1000).astype("int64")
    counts = sec.value_counts().reindex(range(int(sec.max()) + 1), fill_value=0).sort_index()
    return counts.iloc[1:-1] if len(counts) > 2 else counts


def summarize_test(t: HeadphoneTest) -> dict:
    """試験の記録をまとめる (数値は ms と Hz)。"""
    m = t.motion
    th = t.gap_threshold_ms
    out: dict = {"test_id": t.folder.name, "n_samples": len(m), "gap_threshold_ms": th}
    if len(m) < 2:
        return out
    sensor = m["sensor_ts_ms"].astype(float)
    recv = m["recv_mono_ms"].astype("int64")
    sensor_diff = sensor.diff().dropna()
    recv_diff = recv.diff().dropna()
    duration_s = (sensor.max() - sensor.min()) / 1000
    out["duration_min"] = duration_s / 60
    out["mean_hz"] = (len(m) - 1) / duration_s if duration_s > 0 else float("nan")
    per_sec = _per_second(sensor)
    out["per_second_min"] = int(per_sec.min()) if len(per_sec) else None
    out["per_second_median"] = float(per_sec.median()) if len(per_sec) else None
    out["sensor_gap"] = _gap_summary(sensor_diff, th)
    out["recv_gap"] = _gap_summary(recv_diff, th)
    # 受け取った時刻が止まったところで、センサの時刻も同じだけ空いていたか。
    # 空いていなければ、止まりの間もサンプルは測られていて、あとからまとめて届いただけ
    stalls = recv_diff[recv_diff >= th]
    out["recv_stalls_sensor_continuous"] = int((sensor_diff.loc[stalls.index] < th).sum())
    out["sensor_non_increasing"] = int((sensor_diff <= 0).sum())
    latency = (m["recv_mono_ms"] - m["mono_ms"]).astype(float)
    out["latency_ms"] = {"median": float(latency.median()), "p95": float(latency.quantile(0.95)),
                         "max": float(latency.max())}
    out["sample_index_ok"] = bool((m["sample_index"].diff().dropna() == 1).all() and m["sample_index"].iloc[0] == 0)
    loc = m["sensor_location"].astype(str)
    out["location_counts"] = loc.value_counts().to_dict()
    out["location_changes"] = int((loc != loc.shift()).iloc[1:].sum())
    out["event_counts"] = t.events["event_type"].value_counts().to_dict()
    return out


def summarize_imu_db(imu: pd.DataFrame, gap_threshold_ms: int = 500) -> dict:
    """既存の IMU アプリの記録 (load_imu_sqlite の表) を、同じ物差しでまとめる。時刻は受け取った時刻しかない。"""
    out: dict = {"n_samples": len(imu)}
    if len(imu) < 2:
        return out
    recv = imu["unix_ms"].astype("int64")
    duration_s = (recv.max() - recv.min()) / 1000
    out["duration_min"] = duration_s / 60
    out["mean_hz"] = (len(imu) - 1) / duration_s if duration_s > 0 else float("nan")
    out["recv_gap"] = _gap_summary(recv.diff().dropna(), gap_threshold_ms)
    # ZLOCATION は CMDeviceMotion.sensorLocation (0: 既定, 1: 左, 2: 右)
    names = {0: "default", 1: "left", 2: "right"}
    out["location_counts"] = imu["ZLOCATION"].map(names).fillna("unknown").value_counts().to_dict()
    return out


# 値の大きさを比べる列 (課題アプリの列名, 既存の IMU アプリの列名)
_VECTORS = {
    "rotation (rad/s)": (["rot_x", "rot_y", "rot_z"], ["ZROTATION_X", "ZROTATION_Y", "ZROTATION_Z"]),
    "user_acc (G)": (["acc_x", "acc_y", "acc_z"], ["ZUSER_ACC_X", "ZUSER_ACC_Y", "ZUSER_ACC_Z"]),
    "gravity (G)": (["grav_x", "grav_y", "grav_z"], ["ZGRAVITY_X", "ZGRAVITY_Y", "ZGRAVITY_Z"]),
}
_ANGLES = {"pitch (rad)": ("pitch", "ZATT_PITCH"), "roll (rad)": ("roll", "ZATT_ROLL")}


def compare_magnitudes(test: pd.DataFrame, imu: pd.DataFrame) -> pd.DataFrame:
    """2つの記録の値の大きさ (ベクトルの長さと姿勢の角度) の中央値と 95 パーセンタイルを並べる。

    同じ人が同じ動きを続けて記録したものなら、同じくらいになるはず。単位や軸が違えば大きくずれる。
    重力の長さはどちらも 1 G 前後になるはず。
    """
    rows = []
    for name, (a_cols, b_cols) in _VECTORS.items():
        a = np.linalg.norm(test[a_cols].to_numpy(float), axis=1)
        b = np.linalg.norm(imu[b_cols].to_numpy(float), axis=1)
        rows.append({"value": f"|{name}|", "app_median": np.median(a), "app_p95": np.quantile(a, 0.95),
                     "imu_app_median": np.median(b), "imu_app_p95": np.quantile(b, 0.95)})
    for name, (a_col, b_col) in _ANGLES.items():
        a, b = test[a_col].to_numpy(float), imu[b_col].to_numpy(float)
        rows.append({"value": name, "app_median": np.median(a), "app_p95": np.quantile(np.abs(a), 0.95),
                     "imu_app_median": np.median(b), "imu_app_p95": np.quantile(np.abs(b), 0.95)})
    return pd.DataFrame(rows)


def plot_test(t: HeadphoneTest, path: str | Path) -> bool:
    """確認用の図。上から: 1秒ごとのサンプル数 (センサの時刻で数える / 受け取った時刻で数える)、受け取りの遅れ。
    接続・切断・受信のやり直しは縦の点線で示す。matplotlib がなければ False。"""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    m = t.motion
    t0 = float(m["mono_ms"].min())
    ink, muted, series = "#52514e", "#a3a29c", "#2a78d6"
    fig, axes = plt.subplots(3, 1, figsize=(14, 7), sharex=True)
    for ax, col, title in [(axes[0], "mono_ms", "samples per second (sensor time)"),
                           (axes[1], "recv_mono_ms", "samples per second (receive time)")]:
        sec = ((m[col] - t0) // 1000).astype("int64")
        counts = sec.value_counts().sort_index()
        counts = counts.reindex(range(int(counts.index.min()), int(counts.index.max()) + 1), fill_value=0)
        ax.plot(counts.index / 60, counts.to_numpy(), lw=1, color=series)
        ax.set_title(title, loc="left", fontsize=10, color=ink)
        ax.set_ylabel("samples / s")
    axes[2].plot((m["mono_ms"] - t0) / 60_000, m["recv_mono_ms"] - m["mono_ms"], lw=0.6, color=series)
    axes[2].set_title("receive latency (receive time - sensor time)", loc="left", fontsize=10, color=ink)
    axes[2].set_ylabel("ms")
    axes[2].set_xlabel("elapsed (min, from first sample)")
    marks = t.events[t.events["event_type"].isin(["connected", "disconnected", "motion_start", "motion_error"])]
    for _, e in marks.iterrows():
        x = (float(e["mono_ms"]) - t0) / 60_000
        for ax in axes:
            ax.axvline(x, color=muted, lw=0.8, ls=":")
        axes[0].annotate(str(e["event_type"]), (x, 1), xycoords=("data", "axes fraction"), fontsize=7,
                         color=ink, rotation=90, va="top", ha="right")
    for ax in axes:
        ax.grid(axis="y", color="#e6e5e1", lw=0.6)
        ax.spines[["top", "right"]].set_visible(False)
    fig.suptitle(t.folder.name, color=ink)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return True
