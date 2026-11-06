"""ゲームアプリの書き出しデータを pandas で読み込む。課題アプリの load.py と同じ使い方。

    import sys; sys.path.insert(0, "tools")
    from exp2.game_load import load_game_session, load_game_sessions, combine_game

    g = load_game_session("data/exp2_game/P01")    # 1人分
    g.events, g.rounds, g.touches, g.motion, g.meta

    sessions = load_game_sessions("data/exp2_game", include_dev=False)
    tables = combine_game(sessions)                 # 全員分を縦につないだ DataFrame

型 (docs/data_spec.md と同じ):
- 時刻と番号は int64。空欄のありうる列は pandas の Int64 (欠損は <NA>)
- game、touch_type、end_reason、event_type はカテゴリ。座標と動きは float64
- 動き (game_motion.csv) は1人 45 分で約13万行。読むのに数秒かかる。load_motion=False で読まずに済ませられる
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from . import game_schema
from .load import SchemaError, convert, read_raw


@dataclass
class GameSession:
    participant_id: str
    folder: Path
    meta: dict
    events: pd.DataFrame
    rounds: pd.DataFrame
    touches: pd.DataFrame
    motion: pd.DataFrame | None

    @property
    def config(self) -> dict:
        return self.meta["config_snapshot"]


def read_game_table(folder: Path, name: str) -> pd.DataFrame:
    """1つの CSV を定義どおりの型で読む。定義と合わなければ SchemaError。"""
    df, problems = convert(read_raw(Path(folder) / name), game_schema.TABLES[name])
    if problems:
        raise SchemaError(f"{Path(folder) / name}: " + " / ".join(problems))
    return df


def load_game_session(folder: str | Path, load_motion: bool = True) -> GameSession:
    """1人分のフォルダを読む。"""
    folder = Path(folder)
    meta = json.loads((folder / game_schema.META_FILE).read_text(encoding="utf-8"))
    return GameSession(
        participant_id=meta["participant_id"],
        folder=folder,
        meta=meta,
        events=read_game_table(folder, "game_events.csv"),
        rounds=read_game_table(folder, "game_rounds.csv"),
        touches=read_game_table(folder, "game_touches.csv"),
        motion=read_game_table(folder, "game_motion.csv") if load_motion else None,
    )


def game_session_folders(root: str | Path) -> list[Path]:
    """root が exp2_game の親でも exp2_game 自体でも、被験者フォルダの一覧を返す。"""
    root = Path(root)
    if (root / game_schema.META_FILE).exists():
        return [root]
    if (root / game_schema.DATA_FOLDER).is_dir():
        root = root / game_schema.DATA_FOLDER
    if not root.is_dir():
        return []
    return sorted(p for p in root.iterdir() if p.is_dir() and (p / game_schema.META_FILE).exists())


def load_game_sessions(
    root: str | Path,
    include_dev: bool = True,
    only_completed: bool = False,
    load_motion: bool = True,
) -> list[GameSession]:
    """複数人分を読む。include_dev=False で開発用 (DEV_) を除く。"""
    sessions = []
    for folder in game_session_folders(root):
        meta = json.loads((folder / game_schema.META_FILE).read_text(encoding="utf-8"))
        if not include_dev and meta.get("mode") == "dev":
            continue
        if only_completed and not meta.get("completed"):
            continue
        sessions.append(load_game_session(folder, load_motion=load_motion))
    return sessions


def combine_game(sessions: list[GameSession]) -> dict[str, pd.DataFrame]:
    """全員分の events / rounds / touches / motion を縦につなぐ。"""
    out = {}
    for name in ("events", "rounds", "touches", "motion"):
        frames = [getattr(s, name) for s in sessions if getattr(s, name) is not None]
        out[name] = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()
        # カテゴリの列は、つなぐと文字列に戻ることがあるので、定義の値で揃え直す
        columns = game_schema.TABLES[f"game_{name}.csv"]
        for c in columns:
            if c.kind == "choice" and c.name in out[name]:
                out[name][c.name] = out[name][c.name].astype(pd.CategoricalDtype(list(c.choices)))
    return out
