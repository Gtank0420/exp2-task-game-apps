"""書き出したデータの検証 (列と型、時刻の順序、区間の整合性、問題数、AirPods の頭の動きの記録)。

    python3 tools/validate_session.py <被験者フォルダ または exp2_data> [--imu <既存の IMU アプリの .db>]

結果は ERROR (分析に使う前に直す・確かめる必要がある)、WARN (記録は揃っているが確認したほうがよい)、
INFO (参考情報) の3段階で出す。ERROR が1つでもあれば終了コード 1。

iPad 上の簡単なチェック (SessionIntegrity.swift) より詳しく、記録どうしの食い違いまで見る。
"""

from __future__ import annotations

import json
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from . import schema
from .load import convert, load_headphone, read_raw
from .sequence import generate

# 許容誤差 (ミリ秒)
# 区間の終了は約10 ms ごとの tick で判定するので、予定の長さより少し長くなる。
# アプリ側の SessionIntegrity.durationToleranceMs と同じ値にする。
DURATION_TOLERANCE_MS = 100
# 同じ瞬間を2か所に書いた値 (例: segments.csv と events.csv の区間開始) の食い違いの許容
SAME_INSTANT_TOLERANCE_MS = 2
# 点滅の白・黒の長さの許容 (tick の間隔ぶん長くなりうる)
FLASH_TOLERANCE_MS = 50
# Unix 時刻と単調時刻の差がこれ以上動いたら、端末の時計が補正された可能性として知らせる
CLOCK_DRIFT_WARN_MS = 1000
# 1分あたりの回答数がこれを超えたら、人の速さとしてありえないので知らせる (1問1秒前後の想定)
MAX_PLAUSIBLE_ANSWERS_PER_MIN = 150
# IMU の受信が止まった区間として数える長さ。AirPods の記録 (センサの時刻) では、この長さ以上の空きを欠けとして数える
IMU_GAP_WARN_MS = 1000
# 区間の IMU の欠けがこの割合を超えたら知らせる (設計書7章の除外基準「IMU の欠損が10%を超える区間」)
IMU_MISSING_WARN_FRACTION = 0.10


@dataclass
class Issue:
    level: str  # "ERROR" | "WARN" | "INFO"
    check: str
    message: str

    def __str__(self) -> str:
        return f"[{self.level}] {self.check}: {self.message}"


class _Report:
    def __init__(self) -> None:
        self.issues: list[Issue] = []

    def error(self, check: str, message: str) -> None:
        self.issues.append(Issue("ERROR", check, message))

    def warn(self, check: str, message: str) -> None:
        self.issues.append(Issue("WARN", check, message))

    def info(self, check: str, message: str) -> None:
        self.issues.append(Issue("INFO", check, message))


def validate_session(folder: str | Path, imu_db: str | Path | None = None) -> list[Issue]:
    folder = Path(folder)
    r = _Report()

    # --- ファイル ---
    for name in ["meta.json", *schema.TABLES]:
        if not (folder / name).exists():
            r.error("ファイル", f"{name} がありません")
    if not (folder / "state.json").exists():
        r.warn("ファイル", "state.json がありません (作成直後に落ちた可能性)")
    for p in sorted(folder.glob("*.partial_*.txt")):
        r.warn("ファイル", f"途切れた行を移したファイルがあります: {p.name} ({p.stat().st_size} バイト)")
    for p in sorted(folder.glob(".*.tmp")):
        r.warn("ファイル", f"書きかけの一時ファイルが残っています: {p.name}")
    if any(i.level == "ERROR" for i in r.issues):
        return r.issues

    # --- meta.json ---
    try:
        meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        r.error("meta", f"meta.json が読めません: {e}")
        return r.issues
    pid = meta.get("participant_id")
    _check_meta(meta, folder, r)
    config = meta.get("config_snapshot") or {}
    if not config.get("segments"):
        r.error("meta", "config_snapshot に区間の設定がありません")
        return r.issues

    # --- 列と型 ---
    tables: dict[str, pd.DataFrame] = {}
    for name, columns in schema.TABLES.items():
        df, problems = convert(read_raw(folder / name), columns)
        for p in problems:
            r.error(f"列と型 ({name})", p)
        if problems:
            continue
        if not df.empty and set(df["participant_id"]) != {pid}:
            r.error(f"列と型 ({name})", f"participant_id が meta.json ({pid}) と違う行があります")
        tables[name] = df
    if len(tables) < len(schema.TABLES):
        return r.issues
    items, events, segments = tables["items.csv"], tables["events.csv"], tables["segments.csv"]

    _check_events(events, meta, r)
    _check_segments(segments, events, config, r)
    _check_items(items, segments, config, r)
    _check_speech(events, segments, r)
    if config.get("headphone") is not None:
        _check_headphone(folder, meta, events, segments, r)
    if imu_db is not None:
        _check_imu(Path(imu_db), events, r)
    return r.issues


def _check_meta(meta: dict, folder: Path, r: _Report) -> None:
    required = ["schema_version", "participant_id", "handedness", "mode", "created_at", "config_snapshot",
                "completed", "oral_answers"]
    for key in required:
        if key not in meta:
            r.error("meta", f"{key} がありません")
    if meta.get("schema_version") != schema.SCHEMA_VERSION:
        r.error("meta", f"schema_version が {meta.get('schema_version')} です (このスクリプトは {schema.SCHEMA_VERSION})")
    pid = meta.get("participant_id", "")
    if pid != folder.name:
        r.error("meta", f"participant_id ({pid}) がフォルダ名 ({folder.name}) と違います")
    is_dev = meta.get("mode") == "dev"
    if is_dev != pid.startswith(schema.DEV_PREFIX):
        r.error("meta", f"mode ({meta.get('mode')}) と ID の DEV_ の有無が合いません")
    if is_dev:
        r.info("meta", "開発用モードのデータです" + (" (疑似参加者)" if meta.get("config_snapshot", {}).get("simulated_participant") else ""))
    if not meta.get("completed"):
        r.error("meta", "セッションが完了していません (終了時の入力まで進んでいない)")
    # 2026-11-04 から同意の確認をしないので、data_consent は空 (null) が普通 (app_decisions #65)。
    # それより前の記録で、断った (false) ものだけ知らせる
    if meta.get("data_consent") is False:
        r.warn("meta", "データ利用の同意がありません。分析から除いてください (設計書7章の除外基準)")
    for a in meta.get("oral_answers", []):
        if a.get("answer") is None:
            r.warn("meta", f"終了後の質問が未回答です: {a.get('question')}")


def _check_events(events: pd.DataFrame, meta: dict, r: _Report) -> None:
    n = len(events)
    if list(events["event_index"]) != list(range(n)):
        r.error("時刻の順序 (events)", "event_index が 0 から連続していません")

    # 単調増加の時刻は、端末を再起動しない限り戻らない
    mono_back = events["mono_ms"].diff() < 0
    for i in mono_back[mono_back].index:
        et = events.at[i, "event_type"]
        if et in ("app_launch", "session_resume", "partial_line_recovered"):
            r.warn("時刻の順序 (events)", f"event_index {events.at[i, 'event_index']} ({et}) で単調時刻が戻っています。"
                   "再開の前に端末が再起動された可能性があります")
        else:
            r.error("時刻の順序 (events)", f"event_index {events.at[i, 'event_index']} ({et}) で単調時刻が戻っています")
    unix_back = events["unix_ms"].diff() < 0
    if unix_back.any():
        r.warn("時刻の順序 (events)", f"Unix 時刻が戻っている箇所が {int(unix_back.sum())} か所あります (端末の時計の補正)")

    # Unix 時刻と単調時刻の差は、時計が補正されない限り一定 (同じ起動の間)
    boot = mono_back.cumsum()
    offset = events["unix_ms"] - events["mono_ms"]
    drift = (offset.groupby(boot).max() - offset.groupby(boot).min()).max()
    if drift > CLOCK_DRIFT_WARN_MS:
        r.warn("時刻の順序 (events)", f"Unix 時刻と単調時刻の差が最大 {drift} ms 動いています。"
               "実験中に端末の時計が補正された可能性があり、IMU との突き合わせに影響します")
    if (events["event_type"] == "system_clock_changed").any():
        r.warn("時刻の順序 (events)", "実験中に端末の時計が変更されました (system_clock_changed)")

    shakes = int((events["event_type"] == "shake_prompt_on").sum())
    if shakes != 2:
        r.warn("同期の印", f"頭振りの合図が {shakes} 回です (開始時と終了時の2回の想定)")
    bg = int((events["event_type"] == "scene_background").sum())
    if bg:
        r.warn("アプリの状態", f"アプリが背面に回ったことが {bg} 回あります (アクセスガイドが効いていなかった可能性)")
    if meta.get("mode") == "production":
        ga = events[events["event_type"].isin(["guided_access_on", "guided_access_off"])]
        starts = events[events["event_type"] == "segment_start"]
        first_start = starts["mono_ms"].min() if not starts.empty else None
        before = ga[ga["mono_ms"] <= first_start] if first_start is not None else ga
        if before.empty or before.iloc[-1]["event_type"] != "guided_access_on":
            r.warn("アプリの状態", "最初の区間の開始時にアクセスガイドがオンになっていません")
    for et, label in [("session_resume", "再開"), ("tap_ignored", "数えなかったタップ"),
                      ("memory_warning", "メモリ不足の警告"), ("low_battery", "電池残量の低下")]:
        k = int((events["event_type"] == et).sum())
        if k:
            r.info("イベント", f"{label}: {k} 回")


def _check_segments(segments: pd.DataFrame, events: pd.DataFrame, config: dict, r: _Report) -> None:
    check = "区間の整合性"
    configured = [s["id"] for s in config["segments"]]
    extra = set(segments["segment"].astype(str)) - set(configured)
    if extra:
        r.error(check, f"設定にない区間があります: {sorted(extra)}")

    prev_end_unix = None
    starts = events[events["event_type"] == "segment_start"]
    ends = events[events["event_type"] == "segment_end"]
    white_ms, black_ms = config.get("flash_white_ms", 0), config.get("flash_black_ms", 0)
    for order, seg in enumerate(config["segments"]):
        sid, planned = seg["id"], seg["duration_ms"]
        parts = segments[segments["segment"] == sid].sort_values("part")
        if parts.empty:
            r.error(check, f"{sid}: segments.csv に行がありません")
            continue
        if list(parts["part"]) != list(range(len(parts))):
            r.error(check, f"{sid}: part が 0 から連続していません")
        if (parts["order"] != order).any():
            r.error(check, f"{sid}: order が設定の順番 ({order}) と違います")
        if (parts["planned_duration_ms"] != planned).any():
            r.error(check, f"{sid}: planned_duration_ms が設定 ({planned}) と違います")

        # 部分をつなぐと、経過時間 0 から予定の長さまでを抜けも重なりもなく覆う
        expected_start = 0
        for _, p in parts.iterrows():
            if abs(p["start_elapsed_ms"] - expected_start) > DURATION_TOLERANCE_MS:
                r.error(check, f"{sid} part {p['part']}: 開始の経過時間 {p['start_elapsed_ms']} ms が"
                        f"前の部分の終わり ({expected_start} ms) とつながりません")
            if p["end_elapsed_ms"] < p["start_elapsed_ms"] or p["end_mono_ms"] < p["start_mono_ms"] \
                    or p["end_unix_ms"] < p["start_unix_ms"]:
                r.error(check, f"{sid} part {p['part']}: 終了が開始より前です")
            if p["end_reason"] == "timeout":
                wall = p["end_mono_ms"] - p["start_mono_ms"]
                counted = p["end_elapsed_ms"] - p["start_elapsed_ms"]
                if abs(wall - counted) > SAME_INSTANT_TOLERANCE_MS:
                    r.error(check, f"{sid} part {p['part']}: 単調時刻の長さ ({wall} ms) と経過時間の長さ ({counted} ms) が違います")
            expected_start = p["end_elapsed_ms"]
        if abs(expected_start - planned) > DURATION_TOLERANCE_MS:
            r.error(check, f"{sid}: 区間の長さ {expected_start} ms が予定 ({planned} ms) と違います")
        if parts.iloc[-1]["end_reason"] != "timeout":
            r.warn(check, f"{sid}: 最後の部分が中断で終わっています")
        interrupted = int((parts["end_reason"] == "interrupted").sum())
        if interrupted:
            r.info(check, f"{sid}: 中断 {interrupted} 回 (中断前後の部分に分かれています)")

        # 区間は設定の順番に、時間が重ならずに並ぶ
        if prev_end_unix is not None and parts.iloc[0]["start_unix_ms"] < prev_end_unix:
            r.error(check, f"{sid}: 前の区間が終わる前に始まっています")
        prev_end_unix = parts.iloc[-1]["end_unix_ms"]

        # segments.csv と events.csv の区間開始・終了が一致する
        seg_starts = starts[starts["segment"] == sid].sort_values("event_index")
        if len(seg_starts) != len(parts):
            r.error(check, f"{sid}: segment_start イベント ({len(seg_starts)}) と部分の数 ({len(parts)}) が違います")
        else:
            diff = (seg_starts["mono_ms"].to_numpy() - parts["start_mono_ms"].to_numpy())
            if (abs(diff) > SAME_INSTANT_TOLERANCE_MS).any():
                r.error(check, f"{sid}: segment_start イベントの時刻が segments.csv と違います")
        timeout_parts = parts[parts["end_reason"] == "timeout"]
        seg_ends = ends[ends["segment"] == sid]
        for _, p in timeout_parts.iterrows():
            if not (abs(seg_ends["mono_ms"] - p["end_mono_ms"]) <= SAME_INSTANT_TOLERANCE_MS).any():
                r.error(check, f"{sid} part {p['part']}: 対応する segment_end イベントがありません")

        # 区間の開始の直前に、白→黒の点滅がある (カメラとの同期の印)。点滅の長さが 0 の設定 (1台版、
        # single_decisions S58) は点滅しないので見ない
        for _, st in (seg_starts.iterrows() if white_ms + black_ms > 0 else []):
            before = events[events["event_index"] < st["event_index"]]
            flash = {et: before[before["event_type"] == et]["mono_ms"].max()
                     for et in ("flash_white_on", "flash_black_on", "flash_off")}
            if any(pd.isna(v) for v in flash.values()):
                r.error("同期の印", f"{sid}: 区間開始の前に点滅の記録がありません")
                continue
            white_len = flash["flash_black_on"] - flash["flash_white_on"]
            total_len = flash["flash_off"] - flash["flash_white_on"]
            if not (white_ms <= white_len <= white_ms + FLASH_TOLERANCE_MS) or \
                    not (white_ms + black_ms <= total_len <= white_ms + black_ms + 2 * FLASH_TOLERANCE_MS):
                r.warn("同期の印", f"{sid}: 点滅の長さが設定と違います (白 {white_len} ms、全体 {total_len} ms)")
            if abs(flash["flash_off"] - st["mono_ms"]) > SAME_INSTANT_TOLERANCE_MS:
                r.error("同期の印", f"{sid}: 点滅の終わりと区間の開始がずれています")


def _check_items(items: pd.DataFrame, segments: pd.DataFrame, config: dict, r: _Report) -> None:
    check = "問題数"
    digit_min, digit_max = config["digit_min"], config["digit_max"]
    seeds = {s["id"]: s.get("seed") for s in config["segments"]}
    no_problem = [sid for sid, seed in seeds.items() if seed is None]
    if items["segment"].isin(no_problem).any():
        r.error(check, f"出題しない区間 ({no_problem}) に問題の行があります")

    # 1行の中の整合 (回答したかどうかで、空欄になる列が揃っている)
    answered = items["response"].notna()
    for col in ["is_correct", "answered_unix_ms", "answered_mono_ms", "rt_ms", "answered_elapsed_ms"]:
        if (items[col].notna() != answered).any():
            r.error("列と型 (items.csv)", f"{col} の空欄が response の空欄と揃っていません")
    if ((items["a"] < digit_min) | (items["a"] > digit_max) | (items["b"] < digit_min) | (items["b"] > digit_max)).any():
        r.error("列と型 (items.csv)", f"a, b に {digit_min}〜{digit_max} 以外の値があります")
    if (items["correct_answer"] != (items["a"] + items["b"]) % 10).any():
        r.error("列と型 (items.csv)", "correct_answer が (a + b) の1の位になっていません")
    a = items[answered]
    if ((a["response"] < 0) | (a["response"] > 9)).any():
        r.error("列と型 (items.csv)", "response に 0〜9 以外の値があります")
    if (a["is_correct"] != (a["response"] == a["correct_answer"])).any():
        r.error("列と型 (items.csv)", "is_correct が response と correct_answer の比較と合いません")
    if (a["rt_ms"] != a["answered_mono_ms"] - a["shown_mono_ms"]).any():
        r.error("列と型 (items.csv)", "rt_ms が answered_mono_ms − shown_mono_ms と合いません")
    if (a["rt_ms"] < 0).any():
        r.error("時刻の順序 (items)", "表示より前に回答している行があります")

    for sid, seed in seeds.items():
        if seed is None:
            continue
        rows = items[items["segment"] == sid]
        planned = next(s["duration_ms"] for s in config["segments"] if s["id"] == sid)
        if list(rows["item_index"]) != list(range(len(rows))):
            r.error(check, f"{sid}: item_index が 0 から連続していません (中断をまたいでも続き番号の想定)")
        expected = generate(seed, len(rows), digit_min, digit_max)
        if list(zip(rows["a"], rows["b"])) != expected:
            r.error(check, f"{sid}: 出題が乱数の種 ({seed}) から再現できません")

        n_answered = int(rows["response"].notna().sum())
        if n_answered == 0:
            r.warn(check, f"{sid}: 回答が1つもありません")
        per_min = n_answered / (planned / 60_000)
        if per_min > MAX_PLAUSIBLE_ANSWERS_PER_MIN:
            r.warn(check, f"{sid}: 1分あたり {per_min:.0f} 問の回答は速すぎます")
        r.info(check, f"{sid}: 回答 {n_answered} 問 (正答 {int(rows['is_correct'].fillna(False).sum())})")

        for _, p in segments[segments["segment"] == sid].iterrows():
            pr = rows[rows["part"] == p["part"]]
            label = f"{sid} part {p['part']}"
            if len(pr) != p["n_shown"]:
                r.error(check, f"{label}: 行数 ({len(pr)}) が segments.csv の n_shown ({p['n_shown']}) と違います")
            if pr["response"].notna().sum() != p["n_answered"]:
                r.error(check, f"{label}: 回答数が segments.csv の n_answered ({p['n_answered']}) と違います")
            unanswered = pr["response"].isna()
            if p["end_reason"] == "timeout":
                if unanswered.sum() > 1 or (unanswered.any() and not unanswered.iloc[-1]):
                    r.error(check, f"{label}: 未回答の行は、区間の終わりに表示中だった最後の1問だけのはずです")
            elif unanswered.any():
                r.error(check, f"{label}: 中断した部分に未回答の行があります")

            # 時刻の順序: 次の問題は前の回答のあとに出る
            shown = pr["shown_mono_ms"].to_numpy()
            ans = pr["answered_mono_ms"].to_numpy()
            if (shown[1:] < shown[:-1]).any() or any(
                    not pd.isna(ans[i]) and shown[i + 1] < ans[i] for i in range(len(pr) - 1)):
                r.error("時刻の順序 (items)", f"{label}: 問題の表示が前の回答より前になっている行があります")
            # 経過時間はこの部分の範囲に収まり、単調時刻と対応する
            lo, hi = p["start_elapsed_ms"], p["end_elapsed_ms"]
            if ((pr["shown_elapsed_ms"] < lo) | (pr["shown_elapsed_ms"] > hi)).any() or \
                    (pr["answered_elapsed_ms"].dropna() > hi).any():
                r.error("時刻の順序 (items)", f"{label}: 経過時間が部分の範囲 ({lo}〜{hi} ms) の外にある行があります")
            implied = lo + (pr["shown_mono_ms"] - p["start_mono_ms"])
            if (abs(pr["shown_elapsed_ms"] - implied) > SAME_INSTANT_TOLERANCE_MS).any():
                r.error("時刻の順序 (items)", f"{label}: shown_elapsed_ms が単調時刻から計算した値と合いません")


def _check_speech(events: pd.DataFrame, segments: pd.DataFrame, r: _Report) -> None:
    """音声ガイド (1台版の single_decisions S52、2台版の app_decisions #75): 流し始めと終わりが組になっていて、
    区間の最中に流し始めていない。1台版の検証もこれを使う。"""
    check = "音声ガイド"
    sp = events[events["event_type"].astype(str).isin(["speech_start", "speech_end"])]
    if sp.empty:
        return
    kinds = list(sp["event_type"].astype(str))
    unpaired = sum(1 for a, b in zip(kinds, kinds[1:] + [""]) if a == "speech_start" and b != "speech_end")
    if unpaired:
        r.warn(check, f"終わりの記録がない読み上げが {unpaired} 回あります (読んでいる最中にアプリが落ちた可能性)")
    # 区間の部分 (点滅のあとの計算とゲームの時間) の中で読み始めていない
    starts = sp[sp["event_type"].astype(str) == "speech_start"]["mono_ms"].to_numpy()
    for _, p in segments.iterrows():
        if ((starts > p["start_mono_ms"]) & (starts < p["end_mono_ms"])).any():
            r.error(check, f"{p['segment']} 部分 {p['part']} の最中に読み上げを始めています")
    reasons = sp["detail"].astype(str).str.extract(r"reason=(\w+)")[0].value_counts()
    r.info(check, f"読み上げ {len(starts)} 回 (" + "、".join(f"{k} {v}" for k, v in reasons.items()) + ")")


def _check_headphone(folder: Path, meta: dict, events: pd.DataFrame, segments: pd.DataFrame, r: _Report) -> None:
    """AirPods の頭の動きの記録 (schema_version 4 から被験者フォルダに入る。app_decisions #72)。

    時刻はセンサの時刻 (unix_ms, mono_ms) で見る。受け取った時刻 (recv_*) の止まりは、サンプルが
    あとからまとめて届くだけなので数えない (docs/data_spec.md 6章)。iPad の時計で記録しているので、
    課題アプリの記録とのずれはない。
    """
    check = "AirPods の記録"
    pid = meta.get("participant_id")
    config = meta.get("config_snapshot") or {}
    missing = [name for name in schema.HEADPHONE_TABLES if not (folder / name).exists()]
    if missing:
        if config.get("simulated_participant"):
            r.info(check, "疑似参加者のデータなので、AirPods の記録はありません")
        else:
            r.error(check, f"{', '.join(missing)} がありません")
        return
    for name, columns in schema.HEADPHONE_TABLES.items():
        problems = convert(read_raw(folder / name), columns)[1]
        for p in problems:
            r.error(f"列と型 ({name})", p)
        if problems:
            return
    motion, hevents = load_headphone(folder)
    for name, df in [(schema.HEADPHONE_MOTION_FILE, motion), (schema.HEADPHONE_EVENTS_FILE, hevents)]:
        if not df.empty and set(df["participant_id"]) != {pid}:
            r.error(f"列と型 ({name})", f"participant_id が meta.json ({pid}) と違う行があります")
    if list(motion["sample_index"]) != list(range(len(motion))):
        r.error(check, "sample_index が 0 から連続していません")
    if list(hevents["event_index"]) != list(range(len(hevents))):
        r.error(check, "headphone_events.csv の event_index が 0 から連続していません")

    kinds = hevents["event_type"].astype(str)
    if (kinds == "motion_unavailable").any():
        r.error(check, "AirPods の動きを読めない端末で記録されています (シミュレータなど)")
    if motion.empty:
        r.error(check, "AirPods の動きが1つも記録されていません (つながっていなかった、許可されていなかったなど)")
        return

    # センサの時刻の逆行 (届いた順に書くので、ふつうは起きない)
    back = int((motion["mono_ms"].diff().dropna() <= 0).sum())
    if back:
        r.warn(check, f"センサの時刻が前のサンプルより戻っている (または同じ) ところが {back} か所あります")

    # 区間ごとの欠け: 空き (IMU_GAP_WARN_MS 以上) の合計 ÷ 区間の長さ。端の空き (記録の始まりより前、終わりより後) も含める
    hz = float(config["headphone"].get("reference_hz", 50.0))
    mono = motion["mono_ms"].to_numpy()
    for _, p in segments.iterrows():
        lo, hi = int(p["start_mono_ms"]), int(p["end_mono_ms"])
        inside = mono[(mono >= lo) & (mono <= hi)]
        edges = [lo, *inside.tolist(), hi]
        gaps = pd.Series(edges).diff().dropna()
        lost = float(gaps[gaps >= IMU_GAP_WARN_MS].sum())
        frac = lost / max(hi - lo, 1)
        label = f"{p['segment']} (部分 {p['part']})" if (segments["segment"] == p["segment"]).sum() > 1 else str(p["segment"])
        rate = len(inside) / max((hi - lo) / 1000, 1e-9)
        msg = f"{label}: {len(inside)} サンプル (平均 {rate:.1f} Hz、{IMU_GAP_WARN_MS} ms 以上の空きの合計 {lost / 1000:.1f} 秒 = {frac:.1%})"
        if frac > IMU_MISSING_WARN_FRACTION:
            r.warn(check, msg + f"。欠けが {IMU_MISSING_WARN_FRACTION:.0%} を超えています (設計書7章の除外基準)")
        elif lost > 0:
            r.warn(check, msg)
        else:
            r.info(check, msg)
        if len(inside) and rate < hz * 0.8 and lost == 0:
            r.warn(check, f"{label}: 平均 {rate:.1f} Hz で、目安の {hz:.0f} Hz より少ないです")

    # 頭振りの合図 (時刻合わせの目印) のときに記録しているか
    for _, e in events[events["event_type"] == "shake_prompt_on"].iterrows():
        t = int(e["mono_ms"])
        if not ((mono >= t) & (mono <= t + 5_000)).any():
            r.warn(check, f"頭振りの合図 (event_index {e['event_index']}) から5秒間、AirPods の動きがありません")

    def when(t_mono: int) -> str:
        """イベントの時刻が、どの区間の何分目かを示す (区間の外なら空)"""
        for _, p in segments.iterrows():
            if p["start_mono_ms"] <= t_mono <= p["end_mono_ms"]:
                return f" ({p['segment']} の {(t_mono - p['start_mono_ms']) / 60_000:.1f} 分)"
        return ""

    disc = hevents[kinds == "disconnected"]
    if len(disc):
        at = "、".join(f"event_index {i}{when(int(t))}" for i, t in zip(disc["event_index"], disc["mono_ms"]))
        r.warn(check, f"AirPods の切断が {len(disc)} 回あります: {at}")
    for kind, text in [("motion_error", "受け取りのエラー"), ("partial_line_recovered", "途切れた行の退避")]:
        n = int((kinds == kind).sum())
        if n:
            r.warn(check, f"{text}が {n} 回あります (headphone_events.csv の {kind})")
    restarts = hevents[(kinds == "motion_start") & hevents["detail"].str.contains("auto_restart", na=False)]
    if len(restarts):
        r.warn(check, f"AirPods の動きが届かず、受け取りを自動で {len(restarts)} 回始め直しています (app_decisions #74)")
    denied = hevents[(kinds == "authorization") & hevents["detail"].isin(["status=denied", "status=restricted"])]
    if len(denied):
        r.warn(check, "記録の開始時に、動きの読み取りが許可されていませんでした")

    # 測っている側 (左右) の切り替わり。左右で軸の向きが違うので、分析では切り替わりで分けて扱う
    loc = motion["sensor_location"].astype(str)
    changes = int((loc != loc.shift()).iloc[1:].sum())
    counts = ", ".join(f"{k} {v}" for k, v in loc.value_counts().items())
    r.info(check, f"測っている側: {counts}" + (f" (切り替わり {changes} 回。分析では切り替わりで分けて扱う)" if changes else ""))
    n_start = int((kinds == "record_start").sum())
    if n_start > 1:
        r.info(check, f"記録の開始が {n_start} 回あります (アプリが落ちたあとの再開)")
    r.info(check, f"初期化中の値として除くサンプル (受け取りの開始とつながり直しの直後): {int(motion['first_after_start'].sum())} 個")


def _check_imu(path: Path, events: pd.DataFrame, r: _Report) -> None:
    check = "IMU との突き合わせ"
    if not path.exists():
        r.error(check, f"{path} がありません")
        return
    with closing(sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)) as con:
        ts = pd.read_sql_query("SELECT ZTIMESTAMP FROM ZSENSINGHEADPHONEMOTION", con)["ZTIMESTAMP"].astype("int64")
    ts = ts.sort_values().reset_index(drop=True)
    start, end = int(events["unix_ms"].min()), int(events["unix_ms"].max())
    if ts.empty or ts.iloc[-1] < start or ts.iloc[0] > end:
        r.error(check, "IMU の記録が課題アプリの記録と時間的に重なっていません (ファイルの取り違え、端末の時計のずれ)")
        return
    if ts.iloc[0] > start:
        r.warn(check, f"IMU の記録の開始が、課題アプリの記録の開始より {(ts.iloc[0] - start) / 1000:.1f} 秒遅いです")
    if ts.iloc[-1] < end:
        r.warn(check, f"IMU の記録の終了が、課題アプリの記録の終了より {(end - ts.iloc[-1]) / 1000:.1f} 秒早いです")
    inside = ts[(ts >= start) & (ts <= end)]
    gaps = inside.diff().dropna()
    big = gaps[gaps >= IMU_GAP_WARN_MS]
    rate = len(inside) / max((end - start) / 1000, 1)
    r.info(check, f"課題アプリの記録中の IMU: {len(inside)} サンプル (平均 {rate:.1f} Hz)")
    if not big.empty:
        r.warn(check, f"IMU の受信時刻に {IMU_GAP_WARN_MS} ms 以上の空きが {len(big)} か所あります (最大 {int(big.max())} ms)。"
               "IMU アプリの受信の止まりで、サンプル自体は直後にまとめて入っていることが多い (docs/data_spec.md 6章)")


def format_report(folder: Path, issues: list[Issue]) -> str:
    n_err = sum(i.level == "ERROR" for i in issues)
    n_warn = sum(i.level == "WARN" for i in issues)
    status = "NG" if n_err else "OK"
    lines = [f"== {folder.name}: {status} (エラー {n_err}、警告 {n_warn})"]
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    lines += [f"  {i}" for i in sorted(issues, key=lambda i: order[i.level])]
    return "\n".join(lines)
