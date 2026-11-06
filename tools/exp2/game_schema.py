"""ゲームアプリ (研究室の iPhone) が書き出すファイルの定義 (列名・型・空欄の可否)。

アプリ側の定義 (Packages/ExperimentCore/Sources/GameCore/GameRecords.swift) と同じでなければならない。
食い違いは tools/tests/test_game.py が GameRecords.swift を読んで検出する。
各列の意味は docs/data_spec.md を参照。決まり (時刻の組、空欄、0/1) は課題アプリと同じ。
"""

from __future__ import annotations

from .schema import Column

GAME_SCHEMA_VERSION = 1

DATA_FOLDER = "exp2_game"
META_FILE = "game_meta.json"

GAMES = ("stack", "merge")

# アプリの GameEventType (GameRecords.swift) と同じ順
GAME_EVENT_TYPES = (
    "app_launch",
    "session_create",
    "session_resume",
    "screen_show",
    "button",
    "round_start",
    "round_end",
    "best_score_update",
    "experimenter_open",
    "experimenter_close",
    "recording_stop",
    "motion_start",
    "motion_unavailable",
    "motion_error",
    "scene_active",
    "scene_inactive",
    "scene_background",
    "guided_access_on",
    "guided_access_off",
    "system_clock_changed",
    "timezone_changed",
    "low_battery",
    "memory_warning",
    "partial_line_recovered",
    "meta_updated",
)

# アプリの RoundEndReason と同じ順
ROUND_END_REASONS = ("game_over", "back_to_menu", "new_game", "recording_stop", "interrupted")

# アプリの TouchType と同じ順
TOUCH_TYPES = ("tap", "long", "swipe_left", "swipe_right", "swipe_up", "swipe_down", "cancelled")

EVENTS = [
    Column("participant_id", "str"),
    Column("event_index", "int"),
    Column("unix_ms", "int"),
    Column("mono_ms", "int"),
    Column("game", "choice", nullable=True, choices=GAMES),
    Column("round_index", "int", nullable=True),
    Column("part", "int", nullable=True),
    Column("event_type", "choice", choices=GAME_EVENT_TYPES),
    Column("detail", "str", nullable=True),
]

ROUNDS = [
    Column("participant_id", "str"),
    Column("game", "choice", choices=GAMES),
    Column("round_index", "int"),
    Column("part", "int"),
    Column("start_unix_ms", "int"),
    Column("start_mono_ms", "int"),
    Column("end_unix_ms", "int"),
    Column("end_mono_ms", "int"),
    Column("end_reason", "choice", choices=ROUND_END_REASONS),
    Column("score_start", "int"),
    Column("score_end", "int"),
    Column("best_before", "int"),
    Column("n_actions", "int"),
    Column("round_seed", "int"),
]

TOUCHES = [
    Column("participant_id", "str"),
    Column("touch_index", "int"),
    Column("down_unix_ms", "int"),
    Column("down_mono_ms", "int"),
    Column("up_unix_ms", "int"),
    Column("up_mono_ms", "int"),
    Column("screen", "str"),
    Column("game", "choice", nullable=True, choices=GAMES),
    Column("round_index", "int", nullable=True),
    Column("part", "int", nullable=True),
    Column("touch_type", "choice", choices=TOUCH_TYPES),
    Column("down_x", "float"),
    Column("down_y", "float"),
    Column("up_x", "float"),
    Column("up_y", "float"),
    Column("result", "str", nullable=True),
]

MOTION = [
    Column("participant_id", "str"),
    Column("sample_index", "int"),
    Column("unix_ms", "int"),
    Column("mono_ms", "int"),
    Column("sensor_ts_ms", "float"),
    *[Column(f"{k}_{a}", "float") for k in ("acc", "grav", "rot") for a in ("x", "y", "z")],
    *[Column(f"quat_{a}", "float") for a in ("w", "x", "y", "z")],
]

TABLES = {
    "game_events.csv": EVENTS,
    "game_rounds.csv": ROUNDS,
    "game_touches.csv": TOUCHES,
    "game_motion.csv": MOTION,
}
