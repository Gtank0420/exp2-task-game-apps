"""1台版の書き出しデータを pandas で読み込む。

使い方:

    import sys; sys.path.insert(0, "tools")
    from exp2.single_load import load_single_session, load_single_sessions, combine_single

    s = load_single_session("data/exp2_single/S01")     # 1人分
    s.items, s.events, s.segments                        # 2台版の課題アプリと同じ列 + 足した列
    s.popups, s.rounds, s.touches                        # ポップアップ、ゲームの部分、すべてのタッチ
    s.meta, s.config                                     # meta.json と config_snapshot
    s.headphone, s.headphone_events                      # AirPods の頭の動き (初めて使うときに読む)

    sessions = load_single_sessions("data/exp2_single", include_dev=False, only_completed=True)
    tables = combine_single(sessions)                    # 全員分を縦につないだ DataFrame

型の決まりは2台版と同じ (exp2/load.py の説明)。
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from . import schema, single_schema
from .load import SEGMENT_DTYPE, SchemaError, convert, load_headphone, read_raw


@dataclass
class SingleSession:
    participant_id: str
    folder: Path
    meta: dict
    items: pd.DataFrame
    events: pd.DataFrame
    segments: pd.DataFrame
    popups: pd.DataFrame
    rounds: pd.DataFrame
    touches: pd.DataFrame

    @property
    def config(self) -> dict:
        return self.meta["config_snapshot"]

    @property
    def headphone(self) -> pd.DataFrame | None:
        """AirPods の頭の動き (headphone_motion.csv)。ファイルがなければ None。初めて使うときに読む。"""
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


def read_single_table(folder: Path, name: str) -> pd.DataFrame:
    """1つの CSV を定義どおりの型で読む。定義と合わなければ SchemaError。"""
    df, problems = convert(read_raw(Path(folder) / name), single_schema.TABLES[name])
    if problems:
        raise SchemaError(f"{Path(folder) / name}: " + " / ".join(problems))
    return df


def load_single_session(folder: str | Path) -> SingleSession:
    """1人分のフォルダを読む。"""
    folder = Path(folder)
    meta = json.loads((folder / single_schema.META_FILE).read_text(encoding="utf-8"))
    if meta.get("app_kind") != single_schema.APP_KIND:
        raise SchemaError(f"{folder}: 1台版の記録ではありません (app_kind={meta.get('app_kind')})")
    tables = {name: read_single_table(folder, name) for name in single_schema.TABLES}
    return SingleSession(
        participant_id=meta["participant_id"], folder=folder, meta=meta,
        items=tables["items.csv"], events=tables["events.csv"], segments=tables["segments.csv"],
        popups=tables["popups.csv"], rounds=tables["game_rounds.csv"], touches=tables["touches.csv"],
    )


def is_single_folder(folder: Path) -> bool:
    """meta.json の app_kind が "single" の被験者フォルダか (2台版の課題アプリも meta.json という名前なので、中を見る)。"""
    meta = folder / single_schema.META_FILE
    if not meta.is_file():
        return False
    try:
        return json.loads(meta.read_text(encoding="utf-8")).get("app_kind") == single_schema.APP_KIND
    except (OSError, json.JSONDecodeError):
        return False


def single_session_folders(root: str | Path) -> list[Path]:
    """root が exp2_single の親でも exp2_single 自体でも被験者フォルダでも、1台版の被験者フォルダの一覧を返す。"""
    root = Path(root)
    if is_single_folder(root):
        return [root]
    if (root / single_schema.DATA_FOLDER).is_dir():
        root = root / single_schema.DATA_FOLDER
    if not root.is_dir():
        return []
    return sorted(p for p in root.iterdir() if p.is_dir() and is_single_folder(p))


def load_single_sessions(root: str | Path, include_dev: bool = True, only_completed: bool = False) -> list[SingleSession]:
    """複数人分を読む。include_dev=False で開発用 (DEV_) を除く。"""
    sessions = []
    for folder in single_session_folders(root):
        s = load_single_session(folder)
        if not include_dev and s.meta.get("mode") == "dev":
            continue
        if only_completed and not s.meta.get("completed"):
            continue
        sessions.append(s)
    return sessions


def combine_single(sessions: list[SingleSession]) -> dict[str, pd.DataFrame]:
    """全員分の表を縦につなぐ。"""
    out = {}
    for name in ("items", "events", "segments", "popups", "rounds", "touches"):
        frames = [getattr(s, name) for s in sessions]
        df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()
        if "segment" in df:
            df["segment"] = df["segment"].astype(SEGMENT_DTYPE)
        out[name] = df
    return out
