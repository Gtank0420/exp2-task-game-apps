"""課題アプリの書き出しデータを pandas で読み込む。

使い方:

    import sys; sys.path.insert(0, "tools")
    from exp2.load import load_session, load_sessions, combine, meta_frame

    s = load_session("data/exp2_data/P01")       # 1人分
    s.items, s.events, s.segments, s.meta         # DataFrame 3つと dict
    s.headphone, s.headphone_events               # AirPods の頭の動き (schema_version 4 から。初めて使うときに読む)

    sessions = load_sessions("data/exp2_data", include_dev=False, only_consented=True)
    tables = combine(sessions)                    # 全員分を縦につないだ DataFrame
    meta = meta_frame(sessions)                   # 1人1行の被験者情報

型 (docs/data_spec.md と同じ):
- 時刻 (*_unix_ms, *_mono_ms) と番号は int64。空欄のありうる列は pandas の Int64 (欠損は <NA>)
- is_correct は boolean (欠損は <NA>)
- segment は順序付きカテゴリ (focus < game_only < free)
- 文字列は str
"""

from __future__ import annotations

import json
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from . import schema

SEGMENT_DTYPE = pd.CategoricalDtype(schema.SEGMENT_ORDER, ordered=True)


class SchemaError(ValueError):
    """ファイルの列や値が定義 (schema.py) と合わない。"""


def read_raw(path: Path) -> pd.DataFrame:
    """CSV をすべて文字列のまま読む (空欄は空文字)。型の変換と検証は convert で行う。"""
    return pd.read_csv(path, dtype=str, keep_default_na=False, na_filter=False)


def convert(raw: pd.DataFrame, columns: list[schema.Column]) -> tuple[pd.DataFrame, list[str]]:
    """文字列のままの表を定義どおりの型に変換する。変換できなかった内容を文の一覧で返す。"""
    problems: list[str] = []
    expected = [c.name for c in columns]
    if list(raw.columns) != expected:
        return raw, [f"列が定義と違います: {list(raw.columns)} (定義: {expected})"]

    out = {}
    for col in columns:
        s = raw[col.name]
        empty = s == ""
        if not col.nullable and empty.any():
            problems.append(f"{col.name}: 空欄があります (行 {_rows(empty)})")
        if col.kind in ("int", "bool01"):
            num = pd.to_numeric(s.where(~empty), errors="coerce")
            bad = ~empty & (num.isna() | (num % 1 != 0))
            if bad.any():
                problems.append(f"{col.name}: 整数でない値があります (行 {_rows(bad)})")
            if col.kind == "bool01":
                bad01 = ~empty & ~num.isin([0, 1])
                if bad01.any():
                    problems.append(f"{col.name}: 0/1 以外の値があります (行 {_rows(bad01)})")
                out[col.name] = num.astype("Int64").astype("boolean")
            elif col.nullable:
                out[col.name] = num.astype("Int64")
            else:
                out[col.name] = num.astype("Int64") if num.isna().any() else num.astype("int64")
        elif col.kind == "float":
            num = pd.to_numeric(s.where(~empty), errors="coerce")
            bad = ~empty & num.isna()
            if bad.any():
                problems.append(f"{col.name}: 数でない値があります (行 {_rows(bad)})")
            out[col.name] = num.astype("float64")
        elif col.kind == "choice":
            bad = ~empty & ~s.isin(col.choices)
            if bad.any():
                problems.append(f"{col.name}: 決まった値以外があります: {sorted(set(s[bad]))[:5]} (行 {_rows(bad)})")
            out[col.name] = s.where(~empty).astype(pd.CategoricalDtype(list(col.choices)))
        elif col.kind == "segment":
            bad = ~empty & ~s.isin(schema.SEGMENT_ORDER)
            if bad.any():
                problems.append(f"{col.name}: 不明な区間名があります (行 {_rows(bad)})")
            out[col.name] = s.where(~empty).astype(SEGMENT_DTYPE)
        elif col.kind == "event_type":
            bad = ~s.isin(schema.EVENT_TYPES)
            if bad.any():
                problems.append(f"{col.name}: 不明なイベントがあります: {sorted(set(s[bad]))}")
            out[col.name] = s.astype(str)
        elif col.kind == "end_reason":
            bad = ~s.isin(schema.END_REASONS)
            if bad.any():
                problems.append(f"{col.name}: 不明な終了理由があります (行 {_rows(bad)})")
            out[col.name] = s.astype(str)
        else:
            out[col.name] = s.astype(str)
    return pd.DataFrame(out, index=raw.index), problems


def _rows(mask: pd.Series, limit: int = 5) -> str:
    # CSV 上の行番号 (見出しを1行目とする) で示す
    idx = [str(i + 2) for i in mask[mask].index[:limit]]
    more = " ほか" if mask.sum() > limit else ""
    return ", ".join(idx) + more


@dataclass
class Session:
    participant_id: str
    folder: Path
    meta: dict
    items: pd.DataFrame
    events: pd.DataFrame
    segments: pd.DataFrame

    @property
    def config(self) -> dict:
        return self.meta["config_snapshot"]

    @property
    def headphone(self) -> pd.DataFrame | None:
        """AirPods の頭の動き (headphone_motion.csv)。ファイルがなければ None。1人 36 分で約 10 万行あるので、
        初めて使うときに読む。first_after_start 列の意味は load_headphone。"""
        return self._headphone()[0]

    @property
    def headphone_events(self) -> pd.DataFrame | None:
        return self._headphone()[1]

    def _headphone(self) -> tuple[pd.DataFrame | None, pd.DataFrame | None]:
        if not hasattr(self, "_headphone_cache"):
            self._headphone_cache = (load_headphone(self.folder)
                                     if (self.folder / schema.HEADPHONE_MOTION_FILE).exists() else (None, None))
        return self._headphone_cache

    def planned_duration_ms(self, segment: str) -> int:
        return next(s["duration_ms"] for s in self.config["segments"] if s["id"] == segment)


def read_table(folder: Path, name: str) -> pd.DataFrame:
    """1つの CSV を定義どおりの型で読む。定義と合わなければ SchemaError。"""
    df, problems = convert(read_raw(Path(folder) / name), schema.TABLES[name])
    if problems:
        raise SchemaError(f"{Path(folder) / name}: " + " / ".join(problems))
    return df


def load_session(folder: str | Path) -> Session:
    """1人分のフォルダを読む。"""
    folder = Path(folder)
    meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    return Session(
        participant_id=meta["participant_id"],
        folder=folder,
        meta=meta,
        items=read_table(folder, "items.csv"),
        events=read_table(folder, "events.csv"),
        segments=read_table(folder, "segments.csv"),
    )


def load_headphone(folder: str | Path) -> tuple[pd.DataFrame, pd.DataFrame]:
    """AirPods の頭の動きの記録 (headphone_motion.csv と headphone_events.csv) を定義どおりの型で読む。

    被験者フォルダ (schema_version 4 から) でも、記録テストのフォルダ (exp2_imu_test/IMUTEST_...) でもよい。
    サンプルは書かれた順 (届いた順) のまま返す。時刻はセンサの時刻 (unix_ms, mono_ms) を使う
    (受け取った時刻 recv_* は、ときどき止まってまとめて届く。docs/data_spec.md 6章)。

    first_after_start 列 (bool) を足す: 受け取りの開始 (motion_start) と、つながり直し (connected) の直後の
    1サンプル。実機の試験 (2026-11-04) では、この1サンプルだけ quat_z がちょうど 0 で加速度も次のサンプルと
    つながらない、初期化中の値だった。分析ではこの行を除く。
    """
    folder = Path(folder)
    out = []
    for name, columns in schema.HEADPHONE_TABLES.items():
        df, problems = convert(read_raw(folder / name), columns)
        if problems:
            raise SchemaError(f"{folder / name}: " + " / ".join(problems))
        out.append(df)
    motion, events = out
    starts = events.loc[events["event_type"].isin(["motion_start", "connected"]), "mono_ms"].to_numpy()
    first = pd.Series(False, index=motion.index)
    if len(motion) and len(starts):
        mono = motion["mono_ms"].to_numpy()
        # 各開始の時刻より後で最初のサンプル (届いた順に並んでいて、センサの時刻は逆戻りしない)
        pos = pd.Series(mono).searchsorted(starts, side="right")
        first.iloc[sorted({int(p) for p in pos if p < len(motion)})] = True
    motion["first_after_start"] = first
    return motion, events


def session_folders(root: str | Path) -> list[Path]:
    """root が exp2_data の親でも exp2_data 自体でも、被験者フォルダの一覧を返す。"""
    root = Path(root)
    if (root / "meta.json").exists():
        return [root]
    if (root / schema.DATA_FOLDER).is_dir():
        root = root / schema.DATA_FOLDER
    return sorted(p for p in root.iterdir() if p.is_dir() and (p / "meta.json").exists())


def load_sessions(
    root: str | Path,
    include_dev: bool = True,
    only_completed: bool = False,
    only_consented: bool = False,
) -> list[Session]:
    """複数人分を読む。

    include_dev=False で開発用 (DEV_) を除く。only_consented=True でデータ利用を断った人 (data_consent が false) を除く
    (設計書7章の除外基準「終了後の説明でデータ利用を断った人」)。2026-11-04 から同意の確認をしないので
    data_consent は空 (null) になり、除かない (app_decisions #65)。
    """
    sessions = []
    for folder in session_folders(root):
        s = load_session(folder)
        if not include_dev and s.meta.get("mode") == "dev":
            continue
        if only_completed and not s.meta.get("completed"):
            continue
        if only_consented and s.meta.get("data_consent") is False:
            continue
        sessions.append(s)
    return sessions


def combine(sessions: list[Session]) -> dict[str, pd.DataFrame]:
    """全員分の items / events / segments を縦につなぐ。"""
    out = {}
    for name in ("items", "events", "segments"):
        frames = [getattr(s, name) for s in sessions]
        df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()
        if "segment" in df:
            df["segment"] = df["segment"].astype(SEGMENT_DTYPE)
        out[name] = df
    return out


def meta_frame(sessions: list[Session]) -> pd.DataFrame:
    """meta.json を1人1行の表にする。終了後の2問はキー名の列になる。"""
    rows = []
    for s in sessions:
        m = s.meta
        row = {
            "participant_id": m["participant_id"],
            "mode": m["mode"],
            "handedness": m["handedness"],
            "created_unix_ms": m["created_at"]["unix_ms"],
            "created_mono_ms": m["created_at"]["mono_ms"],
            "created_local_time": m["created_local_time"],
            "timezone": m["timezone_identifier"],
            "completed": m["completed"],
            "completed_unix_ms": (m.get("completed_at") or {}).get("unix_ms"),
            "data_consent": m.get("data_consent"),
            "memo": m.get("memo", ""),
            "app_version": m["app"]["version"],
            "device_model": m["device"]["model"],
            "os_version": m["device"]["system_version"],
            "schema_version": m["schema_version"],
        }
        for a in m.get("oral_answers", []):
            row[a["key"]] = a.get("answer")
        rows.append(row)
    df = pd.DataFrame(rows)
    if not df.empty:
        df["completed_unix_ms"] = df["completed_unix_ms"].astype("Int64")
        df["data_consent"] = df["data_consent"].astype("boolean")
    return df


def unix_ms_to_datetime(ms: pd.Series, tz: str = "Asia/Tokyo") -> pd.Series:
    """Unix 時刻 (ミリ秒) を、時間帯付きの日時にする (表示・確認用)。"""
    return pd.to_datetime(ms, unit="ms", utc=True).dt.tz_convert(tz)


def load_imu_sqlite(path: str | Path) -> pd.DataFrame:
    """IMU アプリの SQLite (ZSENSINGHEADPHONEMOTION) を読む。読み取り専用で開く。

    ZTIMESTAMP は Unix 時刻 (ミリ秒) の文字列なので、整数にした unix_ms 列を足す。
    この時刻は IMU アプリがサンプルを受け取った時刻で、30秒ごとに 0.7〜1.5 秒止まったあと、
    まとめて同じ時刻で入る (samples/imu_sample.db で確認。docs/data_spec.md 6章)。
    """
    uri = f"file:{Path(path).resolve()}?mode=ro"
    with closing(sqlite3.connect(uri, uri=True)) as con:
        df = pd.read_sql_query("SELECT * FROM ZSENSINGHEADPHONEMOTION ORDER BY Z_PK", con)
    df.insert(0, "unix_ms", df["ZTIMESTAMP"].astype("int64"))
    return df
