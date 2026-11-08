"""1台版の書き出しデータの検証 (列と型、時刻の順序、区間、問題数、ポップアップ、ゲームの回とタッチ、AirPods)。

    python3 tools/validate_session.py <exp2_single の被験者フォルダ、exp2_single、またはその親>

結果は2台版の検証 (validate.py) と同じ3段階。ERROR が1つでもあれば終了コード 1。
2台版と同じ形の部分 (区間、イベントの時刻、ゲームの回とタッチ、AirPods) は2台版の検証をそのまま使い、
1台版で増えたもの (ポップアップ、未回答の理由、受け付けない時間、ゲームのみの区間の切り替え) を足して確かめる。
iPad 上の簡単なチェック (SingleIntegrity.swift) より詳しく、記録どうしの食い違いまで見る。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pandas as pd

from . import single_schema
from .game_validate import _check_rounds, _check_touches
from .load import convert, read_raw
from .sequence import generate
from .validate import (
    DURATION_TOLERANCE_MS,
    MAX_PLAUSIBLE_ANSWERS_PER_MIN,
    SAME_INSTANT_TOLERANCE_MS,
    Issue,
    _check_events,
    _check_headphone,
    _check_segments,
    _check_speech,
    _Report,
)

# ポップアップは tick (約10 ms ごと) で出すので、計算の画面にいた時間は待ち時間より少し長くなりうる (ms)
POPUP_WAIT_TOLERANCE_MS = 50
# タッチの時刻 (OS がタッチに付けた時刻) と、アプリが画面を切り替えた時刻は、わずかに前後しうる (ms)
TOUCH_TOLERANCE_MS = 200

GAME_ACTION = re.compile(r"(?:^|;)(?:drop_|move_|no_move|stack_start)")


def validate_single_session(folder: str | Path) -> list[Issue]:
    folder = Path(folder)
    r = _Report()

    # --- ファイル ---
    for name in [single_schema.META_FILE, *single_schema.TABLES]:
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
        meta = json.loads((folder / single_schema.META_FILE).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        r.error("meta", f"meta.json が読めません: {e}")
        return r.issues
    _check_meta(meta, folder, r)
    config = meta.get("config_snapshot") or {}
    if not config.get("segments") or not config.get("popup") or not config.get("games"):
        r.error("meta", "config_snapshot に区間、ポップアップ、ゲームの設定がありません")
        return r.issues

    # --- 列と型 ---
    pid = meta.get("participant_id")
    tables: dict[str, pd.DataFrame] = {}
    for name, columns in single_schema.TABLES.items():
        df, problems = convert(read_raw(folder / name), columns)
        for p in problems:
            r.error(f"列と型 ({name})", p)
        if problems:
            continue
        if not df.empty and set(df["participant_id"]) != {pid}:
            r.error(f"列と型 ({name})", f"participant_id が meta.json ({pid}) と違う行があります")
        tables[name] = df
    if len(tables) < len(single_schema.TABLES):
        return r.issues
    items, events, segments = tables["items.csv"], tables["events.csv"], tables["segments.csv"]
    popups, rounds, touches = tables["popups.csv"], tables["game_rounds.csv"], tables["touches.csv"]

    # 2台版と同じ形の部分は、2台版の検証をそのまま使う
    _check_events(events, meta, r)
    _check_segments(segments, events, config, r)
    _check_items(items, segments, popups, config, r)
    _check_popups(popups, items, events, segments, config, r)
    _check_rounds(rounds, events, config["games"], r, completed=bool(meta.get("completed")))
    _check_touches(touches, rounds, config["games"], r)
    _check_game_segments(rounds, popups, events, segments, config, r)
    _check_guard(touches, popups, config, r)
    _check_guide(events, touches, popups, r)
    _check_speech(events, segments, r)
    _check_headphone(folder, meta, events, segments, r)
    return r.issues


def _check_meta(meta: dict, folder: Path, r: _Report) -> None:
    required = ["schema_version", "app_kind", "participant_id", "handedness", "mode", "created_at", "screen",
                "config_snapshot", "completed", "oral_answers"]
    for key in required:
        if key not in meta:
            r.error("meta", f"{key} がありません")
    if meta.get("app_kind") != single_schema.APP_KIND:
        r.error("meta", f"app_kind が {meta.get('app_kind')} です (1台版は {single_schema.APP_KIND})")
    if meta.get("schema_version") != single_schema.SINGLE_SCHEMA_VERSION:
        r.error("meta", f"schema_version が {meta.get('schema_version')} です "
                f"(このスクリプトは1台版の {single_schema.SINGLE_SCHEMA_VERSION})")
    pid = meta.get("participant_id", "")
    if pid != folder.name:
        r.error("meta", f"participant_id ({pid}) がフォルダ名 ({folder.name}) と違います")
    is_dev = meta.get("mode") == "dev"
    if is_dev != pid.startswith("DEV_"):
        r.error("meta", f"mode ({meta.get('mode')}) と ID の DEV_ の有無が合いません")
    config = meta.get("config_snapshot") or {}
    if not is_dev:
        patterns = config.get("production_id_patterns") or []
        if not any(re.search(p, pid) for p in patterns):
            r.error("meta", f"ID ({pid}) が1台版の決まり ({', '.join(patterns)}) に合いません (2台版の ID の取り違え?)")
    else:
        r.info("meta", "開発用モードのデータです" + (" (疑似参加者)" if config.get("simulated_participant") else ""))
    if not meta.get("completed"):
        r.error("meta", "セッションが完了していません (終了時の入力まで進んでいない)")
    for a in meta.get("oral_answers", []):
        if a.get("answer") is None:
            r.warn("meta", f"終了後の質問が未回答です: {a.get('question')}")


def _check_items(items: pd.DataFrame, segments: pd.DataFrame, popups: pd.DataFrame, config: dict, r: _Report) -> None:
    """2台版の validate._check_items と同じ確かめに、未回答の理由 (時間切れ / ポップアップ) を足したもの。"""
    check = "問題数"
    digit_min, digit_max = config["digit_min"], config["digit_max"]
    seeds = {s["id"]: s.get("seed") for s in config["segments"]}
    no_problem = [sid for sid, seed in seeds.items() if seed is None]
    if items["segment"].isin(no_problem).any():
        r.error(check, f"出題しない区間 ({no_problem}) に問題の行があります")

    answered = items["response"].notna()
    for col in ["is_correct", "answered_unix_ms", "answered_mono_ms", "rt_ms", "answered_elapsed_ms"]:
        if (items[col].notna() != answered).any():
            r.error("列と型 (items.csv)", f"{col} の空欄が response の空欄と揃っていません")
    if (items["unanswered_reason"].notna() == answered).any():
        r.error("列と型 (items.csv)", "unanswered_reason は未回答の行にだけ、必ず書かれるはずです")
    by_popup = items["unanswered_reason"] == "popup"
    if (items["popup_index"].notna() != by_popup.fillna(False)).any():
        r.error("列と型 (items.csv)", "popup_index は、ポップアップで中断した行にだけ書かれるはずです")
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
        if list(zip(rows["a"], rows["b"])) != generate(seed, len(rows), digit_min, digit_max):
            r.error(check, f"{sid}: 出題が乱数の種 ({seed}) から再現できません")
        n_answered = int(rows["response"].notna().sum())
        if n_answered == 0:
            r.warn(check, f"{sid}: 回答が1つもありません")
        per_min = n_answered / (planned / 60_000)
        if per_min > MAX_PLAUSIBLE_ANSWERS_PER_MIN:
            r.warn(check, f"{sid}: 1分あたり {per_min:.0f} 問の回答は速すぎます")
        n_popup = int((rows["unanswered_reason"] == "popup").sum())
        r.info(check, f"{sid}: 回答 {n_answered} 問 (正答 {int(rows['is_correct'].fillna(False).sum())})"
               + (f"、ポップアップで中断 {n_popup} 問" if n_popup else ""))

        for _, p in segments[segments["segment"] == sid].iterrows():
            pr = rows[rows["part"] == p["part"]]
            label = f"{sid} part {p['part']}"
            if len(pr) != p["n_shown"]:
                r.error(check, f"{label}: 行数 ({len(pr)}) が segments.csv の n_shown ({p['n_shown']}) と違います")
            if pr["response"].notna().sum() != p["n_answered"]:
                r.error(check, f"{label}: 回答数が segments.csv の n_answered ({p['n_answered']}) と違います")
            timeout = (pr["unanswered_reason"] == "timeout").fillna(False)
            if timeout.sum() > 1 or (timeout.any() and not timeout.iloc[-1]):
                r.error(check, f"{label}: 時間切れの未回答の行は、区間の終わりに表示中だった最後の1問だけのはずです")
            if timeout.any() and p["end_reason"] != "timeout":
                r.error(check, f"{label}: 中断した部分に時間切れの未回答の行があります")

            # 時刻の順序: 次の問題は前の回答 (またはポップアップを閉じたあと) に出る
            shown = pr["shown_mono_ms"].to_numpy()
            ans = pr["answered_mono_ms"].to_numpy()
            if (shown[1:] < shown[:-1]).any() or any(
                    not pd.isna(ans[i]) and shown[i + 1] < ans[i] for i in range(len(pr) - 1)):
                r.error("時刻の順序 (items)", f"{label}: 問題の表示が前の回答より前になっている行があります")
            lo, hi = p["start_elapsed_ms"], p["end_elapsed_ms"]
            if ((pr["shown_elapsed_ms"] < lo) | (pr["shown_elapsed_ms"] > hi)).any() or \
                    (pr["answered_elapsed_ms"].dropna() > hi).any():
                r.error("時刻の順序 (items)", f"{label}: 経過時間が部分の範囲 ({lo}〜{hi} ms) の外にある行があります")
            implied = lo + (pr["shown_mono_ms"] - p["start_mono_ms"])
            if (abs(pr["shown_elapsed_ms"] - implied) > SAME_INSTANT_TOLERANCE_MS).any():
                r.error("時刻の順序 (items)", f"{label}: shown_elapsed_ms が単調時刻から計算した値と合いません")

    # ポップアップが出ている間に回答していない
    for _, p in popups.iterrows():
        inside = items["answered_mono_ms"].between(p["shown_mono_ms"], p["closed_mono_ms"] - 1)
        if inside.any():
            r.error(check, f"popup_index {p['popup_index']}: ポップアップが出ている間に回答した行があります")


def _check_popups(popups: pd.DataFrame, items: pd.DataFrame, events: pd.DataFrame, segments: pd.DataFrame,
                  config: dict, r: _Report) -> None:
    """ポップアップ (設計書3章): 番号、待ち時間の列、出すゲーム、閉じた理由、中断した問題、イベントとの一致。"""
    check = "ポップアップ"
    pc = config["popup"]
    sid = pc["segment"]
    duration = next(s["duration_ms"] for s in config["segments"] if s["id"] == sid)
    if (popups["segment"] != sid).any():
        r.error(check, f"{sid} 以外の区間にポップアップがあります")
    if list(popups["popup_index"]) != list(range(len(popups))):
        r.error(check, "popup_index が 0 から連続していません")
        return
    if (popups["closed_mono_ms"] < popups["shown_mono_ms"]).any() or \
            (popups["shown_mono_ms"].to_numpy()[1:] < popups["closed_mono_ms"].to_numpy()[:-1]).any():
        r.error(check, "ポップアップの時刻が重なっているか、閉じた時刻が出た時刻より前です")
    if (popups["duration_ms"] != popups["closed_mono_ms"] - popups["shown_mono_ms"]).any():
        r.error(check, "duration_ms が closed_mono_ms − shown_mono_ms と合いません")

    prev_closed = 0
    for _, p in popups.iterrows():
        k = int(p["popup_index"])
        label = f"popup_index {k}"
        if p["game"] != single_schema.popup_game(pc, k):
            r.error(check, f"{label}: ゲーム ({p['game']}) が交互の順 ({single_schema.popup_game(pc, k)}) と違います")
        planned = single_schema.popup_wait_ms(pc, k)
        if p["planned_wait_ms"] != planned:
            r.error(check, f"{label}: planned_wait_ms ({p['planned_wait_ms']}) が待ち時間の列 ({planned}) と違います")
        if p["compute_ms_before"] != p["shown_elapsed_ms"] - prev_closed:
            r.error(check, f"{label}: compute_ms_before が、前に閉じてから出るまでの経過時間と合いません")
        if not (0 <= p["compute_ms_before"] - planned <= POPUP_WAIT_TOLERANCE_MS):
            r.error(check, f"{label}: 計算の画面にいた時間 ({p['compute_ms_before']} ms) が待ち時間 ({planned} ms) と合いません")
        if p["close_reason"] == "segment_end" and abs(p["closed_elapsed_ms"] - duration) > DURATION_TOLERANCE_MS:
            r.error(check, f"{label}: 区間の終わりで閉じたのに、閉じた時刻が区間の終わりと違います")
        if p["close_reason"] == "interrupted":
            part = segments[(segments["segment"] == sid) & (segments["part"] == p["segment_part"])]
            if part.empty or part.iloc[0]["end_reason"] != "interrupted" or \
                    part.iloc[0]["end_elapsed_ms"] != p["closed_elapsed_ms"]:
                r.error(check, f"{label}: 中断で閉じたのに、segments.csv の中断した部分と合いません")
        prev_closed = int(p["closed_elapsed_ms"])

    # 最後のポップアップのあと、区間の終わりまでに待ち時間がたったのに出ていない
    if popups.empty or popups.iloc[-1]["close_reason"] != "segment_end":
        due = prev_closed + single_schema.popup_wait_ms(pc, len(popups))
        if due < duration - DURATION_TOLERANCE_MS:
            r.error(check, f"区間の経過時間 {due} ms に出るはずのポップアップ (popup_index {len(popups)}) がありません")

    # 中断した問題: ポップアップの番号が付いた未回答の行と1対1
    by_popup = items[items["unanswered_reason"] == "popup"]
    for _, p in popups.iterrows():
        rows = by_popup[by_popup["popup_index"] == p["popup_index"]]
        expected = p["interrupted_item_index"]
        if pd.isna(expected):
            if len(rows):
                r.error(check, f"popup_index {p['popup_index']}: 中断した問題がないのに、items.csv に行があります")
            continue
        if len(rows) != 1 or rows.iloc[0]["item_index"] != expected or rows.iloc[0]["segment"] != sid:
            r.error(check, f"popup_index {p['popup_index']}: 中断した問題 ({expected}) の行が items.csv と合いません")
        elif rows.iloc[0]["shown_mono_ms"] > p["shown_mono_ms"]:
            r.error(check, f"popup_index {p['popup_index']}: 中断した問題が、ポップアップより後に出ています")
    if len(by_popup) != popups["interrupted_item_index"].notna().sum():
        r.error(check, "ポップアップで中断した問題の行の数が popups.csv と合いません")

    # events.csv の popup_show / popup_close と一致する
    et = events["event_type"].astype(str)
    shows = events[et == "popup_show"]
    closes = events[et == "popup_close"]
    if len(shows) != len(popups) or len(closes) != len(popups):
        r.error(check, f"popup_show ({len(shows)})、popup_close ({len(closes)}) のイベントと行の数 ({len(popups)}) が違います")
    else:
        if (abs(shows["mono_ms"].to_numpy() - popups["shown_mono_ms"].to_numpy()) > SAME_INSTANT_TOLERANCE_MS).any() \
                or list(shows["popup_index"]) != list(popups["popup_index"]):
            r.error(check, "popup_show イベントが popups.csv の出た時刻と合いません")
        normal = (popups["close_reason"] != "interrupted").to_numpy()
        diff = abs(closes["mono_ms"].to_numpy() - popups["closed_mono_ms"].to_numpy())
        if (diff[normal] > SAME_INSTANT_TOLERANCE_MS).any():
            r.error(check, "popup_close イベントが popups.csv の閉じた時刻と合いません")

    if popups.empty:
        r.warn(check, "ポップアップが1回も出ていません")
        return
    played = popups["n_actions"] > 0
    r.info(check, f"{len(popups)} 回 (遊んだ {int(played.sum())} 回、出てすぐ閉じた {int((~played).sum())} 回)、"
           f"出ていた時間の合計 {popups['duration_ms'].sum() / 1000:.0f} 秒、閉じた理由: "
           + "、".join(f"{k} {v}" for k, v in popups["close_reason"].astype(str).value_counts().items()))


def _check_game_segments(rounds: pd.DataFrame, popups: pd.DataFrame, events: pd.DataFrame, segments: pd.DataFrame,
                         config: dict, r: _Report) -> None:
    """ゲームの部分が、ゲームのみの区間か、ポップアップの中に収まっている。ゲームのみの区間の切り替え。"""
    check = "ゲームの区間"
    psid = config["popup"]["segment"]
    in_popup = rounds[rounds["segment"] == psid]
    if in_popup["popup_index"].isna().any():
        r.error(check, f"{psid} のゲームの部分に popup_index がありません")
    for _, g in in_popup.iterrows():
        p = popups[popups["popup_index"] == g["popup_index"]]
        if p.empty or g["start_mono_ms"] < p.iloc[0]["shown_mono_ms"] or g["end_mono_ms"] > p.iloc[0]["closed_mono_ms"]:
            r.error(check, f"round_index {g['round_index']} part {g['part']}: ポップアップの時間の外にあります")
    others = rounds[rounds["segment"] != psid]
    if others["popup_index"].notna().any():
        r.error(check, f"{psid} 以外のゲームの部分に popup_index があります")
    if not set(others["segment"].astype(str)) <= {"game_only"}:
        r.error(check, "ゲームのみの区間と自由区間以外に、ゲームの部分があります")

    # ゲームのみの区間: 前半は first_game、後半はもう一方。切り替えは区間の経過時間で決まる
    go = config.get("game_only") or {}
    seg = next((s for s in config["segments"] if s["id"] == "game_only"), None)
    if seg is None or not go:
        return
    switch_ms = single_schema.game_only_switch_ms(go, seg["duration_ms"])
    first = go["first_game"]
    second = "merge" if first == "stack" else "stack"
    parts = segments[segments["segment"] == "game_only"]
    rows = rounds[rounds["segment"] == "game_only"]
    for _, g in rows.iterrows():
        part = parts[(parts["start_mono_ms"] <= g["start_mono_ms"]) & (g["start_mono_ms"] <= parts["end_mono_ms"])]
        if part.empty:
            r.error(check, f"round_index {g['round_index']}: ゲームのみの区間の時間の外にあります")
            continue
        p = part.iloc[0]
        elapsed = p["start_elapsed_ms"] + (g["start_mono_ms"] - p["start_mono_ms"])
        expected = first if elapsed < switch_ms else second
        if g["game"] != expected:
            r.error(check, f"round_index {g['round_index']}: ゲームのみの区間の経過時間 {elapsed} ms に {g['game']} "
                    f"(前半 {first}、後半 {second}、切り替え {switch_ms} ms)")
    if not parts.empty and parts["end_elapsed_ms"].max() > switch_ms + DURATION_TOLERANCE_MS:
        switches = int((events["event_type"].astype(str) == "game_switch").sum())
        crossed = int(((parts["start_elapsed_ms"] < switch_ms) & (parts["end_elapsed_ms"] > switch_ms)).sum())
        if switches != crossed:
            r.error(check, f"game_switch イベント ({switches}) が、切り替えの時点をまたいだ部分の数 ({crossed}) と違います")


def _check_guide(events: pd.DataFrame, touches: pd.DataFrame, popups: pd.DataFrame, r: _Report) -> None:
    """操作のガイド (single_decisions S47、S48): ポップアップごとに1回出て、最初の操作で消える。
    積み上げ型で遊んだポップアップには、ブロックを動き出させたタップ (stack_start) が1回ある。"""
    check = "操作のガイド"
    et = events["event_type"].astype(str)
    shows, hides = events[et == "guide_show"], events[et == "guide_hide"]
    if len(hides) > len(shows):
        r.error(check, f"guide_hide ({len(hides)}) が guide_show ({len(shows)}) より多いです")
    shown_popups = shows["popup_index"].dropna().astype(int)
    if sorted(shown_popups) != sorted(popups["popup_index"].astype(int)):
        r.error(check, "ガイドを出したポップアップが、ポップアップごとに1回になっていません")
    results = touches["result"].fillna("").astype(str)
    for _, p in popups[(popups["game"] == "stack") & (popups["n_actions"] > 0)].iterrows():
        n = int(results[touches["popup_index"] == p["popup_index"]].str.contains("stack_start").sum())
        if n != 1:
            r.warn(check, f"popup_index {p['popup_index']}: 動き出しのタップ (stack_start) が {n} 回です "
                   "(操作の結果がタッチに結び付かなかった可能性)")
    r.info(check, f"出した {len(shows)} 回、最初の操作で消えた {len(hides)} 回")


def _check_guard(touches: pd.DataFrame, popups: pd.DataFrame, config: dict, r: _Report) -> None:
    """出た直後の受け付けない時間 (inputGuardMs): その間に触れたタッチでゲームの操作が起きていない (設計書3.2)。"""
    check = "受け付けない時間"
    guard = config["popup"]["input_guard_ms"]
    results = touches["result"].fillna("").astype(str)
    for _, p in popups.iterrows():
        t = touches[touches["popup_index"] == p["popup_index"]]
        if ((t["down_mono_ms"] < p["shown_mono_ms"] - TOUCH_TOLERANCE_MS) |
                (t["down_mono_ms"] > p["closed_mono_ms"] + TOUCH_TOLERANCE_MS)).any():
            r.error(check, f"popup_index {p['popup_index']}: ポップアップの時間の外で触れたタッチが、その回のものになっています")
        since = t["down_mono_ms"] - p["shown_mono_ms"]
        expected = (since >= 0) & (since < guard)
        if (t["in_guard"].astype(bool) != expected).any():
            r.error(check, f"popup_index {p['popup_index']}: in_guard が、出てから触れるまでの時間と合いません")
        if (t["in_guard"].astype(bool) & results[t.index].str.contains(GAME_ACTION)).any():
            r.error(check, f"popup_index {p['popup_index']}: 受け付けない時間に触れたタッチで、ゲームが動いています")
        if int(t["in_guard"].sum()) > p["n_in_guard_touches"] or len(t) > p["n_touches"]:
            r.error(check, f"popup_index {p['popup_index']}: タッチの行の数が popups.csv の数より多いです")
    n_blocked = int(results.str.contains("blocked").sum())
    if n_blocked:
        r.info(check, f"受け付けなかったゲームの操作: {n_blocked} 回")
