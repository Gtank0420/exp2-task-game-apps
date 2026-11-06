"""課題アプリが書き出すファイルの定義 (列名・型・空欄の可否)。

アプリ側の定義 (Packages/ExperimentCore/Sources/ExperimentCore/Records.swift、AirPods の記録は
HeadphoneMotion.swift) と同じでなければならない。
食い違いは tools/tests/test_load_validate.py が Swift のファイルを読んで検出する。
各列の意味は docs/data_spec.md を参照。
"""

from __future__ import annotations

from dataclasses import dataclass

SCHEMA_VERSION = 4

# 区間の順番 (2026-11-04 に練習をなくし、計算のみ → ゲームのみ → 自由区間にした。schema_version 3)
SEGMENT_ORDER = ["focus", "game_only", "free"]

DATA_FOLDER = "exp2_data"
DEV_PREFIX = "DEV_"


@dataclass(frozen=True)
class Column:
    name: str
    # "str" | "int" | "float" | "segment" | "bool01" | "event_type" | "end_reason" | "choice"
    kind: str
    nullable: bool = False
    # kind が "choice" のときに許す値 (ゲームアプリの game、touch_type など)
    choices: tuple[str, ...] = ()


ITEMS = [
    Column("participant_id", "str"),
    Column("segment", "segment"),
    Column("part", "int"),
    Column("item_index", "int"),
    Column("a", "int"),
    Column("b", "int"),
    Column("correct_answer", "int"),
    Column("response", "int", nullable=True),
    Column("is_correct", "bool01", nullable=True),
    Column("shown_unix_ms", "int"),
    Column("shown_mono_ms", "int"),
    Column("answered_unix_ms", "int", nullable=True),
    Column("answered_mono_ms", "int", nullable=True),
    Column("rt_ms", "int", nullable=True),
    Column("shown_elapsed_ms", "int"),
    Column("answered_elapsed_ms", "int", nullable=True),
]

EVENTS = [
    Column("participant_id", "str"),
    Column("event_index", "int"),
    Column("unix_ms", "int"),
    Column("mono_ms", "int"),
    Column("segment", "segment", nullable=True),
    Column("part", "int", nullable=True),
    Column("event_type", "event_type"),
    Column("detail", "str", nullable=True),
]

SEGMENTS = [
    Column("participant_id", "str"),
    Column("segment", "segment"),
    Column("part", "int"),
    Column("order", "int"),
    Column("planned_duration_ms", "int"),
    Column("start_unix_ms", "int"),
    Column("start_mono_ms", "int"),
    Column("end_unix_ms", "int"),
    Column("end_mono_ms", "int"),
    Column("start_elapsed_ms", "int"),
    Column("end_elapsed_ms", "int"),
    Column("end_reason", "end_reason"),
    Column("n_shown", "int"),
    Column("n_answered", "int"),
]

TABLES = {"items.csv": ITEMS, "events.csv": EVENTS, "segments.csv": SEGMENTS}

# アプリの EventType (Records.swift) と同じ順
EVENT_TYPES = [
    "app_launch",
    "session_create",
    "session_resume",
    "screen_show",
    "button",
    "segment_start",
    "segment_end",
    "flash_white_on",
    "flash_black_on",
    "flash_off",
    "shake_prompt_on",
    "shake_prompt_off",
    "tap_ignored",
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
]

END_REASONS = ["timeout", "interrupted"]


# --- AirPods の頭の動き (schema_version 4 から、被験者フォルダに入る。app_decisions #72) ---
# 開発用モードの「AirPods の記録テスト」(exp2_imu_test/) も同じ形。読み込みは load.load_headphone

HEADPHONE_MOTION_FILE = "headphone_motion.csv"
HEADPHONE_EVENTS_FILE = "headphone_events.csv"

# HeadphoneSensorLocation (HeadphoneMotion.swift) と同じ順
HEADPHONE_LOCATIONS = ("default", "left", "right", "unknown")

# アプリの HeadphoneEventType (HeadphoneMotion.swift) と同じ順
HEADPHONE_EVENT_TYPES = (
    "record_start",
    "record_stop",
    "authorization",
    "connected",
    "disconnected",
    "motion_start",
    "motion_stop",
    "motion_unavailable",
    "motion_error",
    "location_change",
    "app_active",
    "app_inactive",
    "app_background",
    "partial_line_recovered",
)

HEADPHONE_MOTION = [
    Column("participant_id", "str"),
    Column("sample_index", "int"),
    Column("unix_ms", "int"),
    Column("mono_ms", "int"),
    Column("sensor_ts_ms", "float"),
    Column("recv_unix_ms", "int"),
    Column("recv_mono_ms", "int"),
    Column("sensor_location", "choice", choices=HEADPHONE_LOCATIONS),
    *[Column(name, "float") for name in [
        "acc_x", "acc_y", "acc_z", "grav_x", "grav_y", "grav_z", "rot_x", "rot_y", "rot_z",
        "quat_w", "quat_x", "quat_y", "quat_z", "pitch", "roll", "yaw",
    ]],
]

HEADPHONE_EVENTS = [
    Column("participant_id", "str"),
    Column("event_index", "int"),
    Column("unix_ms", "int"),
    Column("mono_ms", "int"),
    Column("event_type", "choice", choices=HEADPHONE_EVENT_TYPES),
    Column("detail", "str", nullable=True),
]

HEADPHONE_TABLES = {HEADPHONE_MOTION_FILE: HEADPHONE_MOTION, HEADPHONE_EVENTS_FILE: HEADPHONE_EVENTS}
