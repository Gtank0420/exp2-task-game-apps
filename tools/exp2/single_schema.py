"""1台版 (iPad 1台で、計算問題の途中にゲームが割り込む形式) が書き出すファイルの定義 (列名・型・空欄の可否)。

アプリ側の定義 (Packages/ExperimentCore/Sources/SingleCore/SingleRecords.swift) と同じでなければならない。
食い違いは tools/tests/test_single.py が Swift のファイルを読んで検出する。
各列の意味は docs/data_spec_single.md を参照。決まり (時刻の組、空欄、0/1) は2台版と同じ。

2台版と同じ名前のファイルは、2台版の列をそのままの順番で前に置き、足す列は最後に付けている
(docs/single_decisions.md S16)。ここでも2台版の定義 (schema.py、game_schema.py) を土台にして作る。
"""

from __future__ import annotations

import math

from . import game_schema, schema
from .schema import Column
from .sequence import SplitMix64

SINGLE_SCHEMA_VERSION = 2
DATA_FOLDER = "exp2_single"
META_FILE = "meta.json"
APP_KIND = "single"

# アプリの SingleEventType (SingleRecords.swift) と同じ順
SINGLE_EVENT_TYPES = (
    *schema.EVENT_TYPES,
    "round_start",
    "round_end",
    "best_score_update",
    "popup_show",
    "popup_close",
    "popup_input_blocked",
    "game_switch",
    "guide_show",
    "guide_hide",
)
# speech_start / speech_end は 2台版の課題アプリにも入った (schema.EVENT_TYPES、2026-11-08) ので、そちらに含まれる

# アプリの UnansweredReason、PopupCloseReason、SingleRoundEndReason と同じ順
UNANSWERED_REASONS = ("timeout", "popup")
POPUP_CLOSE_REASONS = ("close_button", "segment_end", "interrupted")
ROUND_END_REASONS = ("game_over", "new_game", "closed", "segment_end", "game_switch", "interrupted")


def _replace(columns: list[Column], **new: Column) -> list[Column]:
    """2台版の列の定義のうち、値の種類が増えた列だけを差し替える (列の名前と順番は変えない)。"""
    return [new.get(c.name, c) for c in columns]


ITEMS = [
    *schema.ITEMS,
    Column("unanswered_reason", "choice", nullable=True, choices=UNANSWERED_REASONS),
    Column("popup_index", "int", nullable=True),
]

EVENTS = [
    *_replace(schema.EVENTS, event_type=Column("event_type", "choice", choices=SINGLE_EVENT_TYPES)),
    Column("game", "choice", nullable=True, choices=game_schema.GAMES),
    Column("round_index", "int", nullable=True),
    Column("popup_index", "int", nullable=True),
]

SEGMENTS = schema.SEGMENTS

POPUPS = [
    Column("participant_id", "str"),
    Column("popup_index", "int"),
    Column("segment", "segment"),
    Column("segment_part", "int"),
    Column("game", "choice", choices=game_schema.GAMES),
    Column("planned_wait_ms", "int"),
    Column("compute_ms_before", "int"),
    Column("shown_unix_ms", "int"),
    Column("shown_mono_ms", "int"),
    Column("shown_elapsed_ms", "int"),
    Column("closed_unix_ms", "int"),
    Column("closed_mono_ms", "int"),
    Column("closed_elapsed_ms", "int"),
    Column("duration_ms", "int"),
    Column("close_reason", "choice", choices=POPUP_CLOSE_REASONS),
    Column("interrupted_item_index", "int", nullable=True),
    Column("n_touches", "int"),
    Column("n_in_guard_touches", "int"),
    Column("n_actions", "int"),
    Column("n_game_parts", "int"),
    Column("first_touch_ms", "int", nullable=True),
    Column("first_action_ms", "int", nullable=True),
]

ROUNDS = [
    *_replace(game_schema.ROUNDS, end_reason=Column("end_reason", "choice", choices=ROUND_END_REASONS)),
    Column("segment", "segment"),
    Column("popup_index", "int", nullable=True),
]

TOUCHES = [
    *game_schema.TOUCHES,
    Column("segment", "segment", nullable=True),
    Column("segment_part", "int", nullable=True),
    Column("popup_index", "int", nullable=True),
    Column("in_guard", "bool01"),
]

TABLES = {
    "items.csv": ITEMS,
    "events.csv": EVENTS,
    "segments.csv": SEGMENTS,
    "popups.csv": POPUPS,
    "game_rounds.csv": ROUNDS,
    "touches.csv": TOUCHES,
}


def popup_wait_ms(popup: dict, k: int) -> int:
    """k 回目 (0始まり) のポップアップの待ち時間 (ms)。PopupConfig.waitMs (SingleConfig.swift) と同じ手順:
    SplitMix64(seed + k) の最初の値 v を取り、wait_min_ms + wait_step_ms × (v mod 刻みの数)。"""
    steps = (popup["wait_max_ms"] - popup["wait_min_ms"]) // popup["wait_step_ms"] + 1
    v = SplitMix64(popup["seed"] + k).next()
    return popup["wait_min_ms"] + popup["wait_step_ms"] * (v % steps)


def popup_game(popup: dict, k: int) -> str:
    """k 回目のポップアップに出すゲーム (偶数回は first_game、奇数回はもう一方)。"""
    first = popup["first_game"]
    return first if k % 2 == 0 else ("merge" if first == "stack" else "stack")


def game_only_switch_ms(game_only: dict, duration_ms: int) -> int:
    """ゲームのみの区間で、後半のゲームに切り替える経過時間 (GameOnlyConfig.switchAtMs と同じ。
    Swift の rounded() は 0.5 を0から遠いほうへ丸めるので、Python の round (偶数へ丸める) は使わない)。"""
    return int(math.floor(duration_ms * game_only["switch_fraction"] + 0.5))
