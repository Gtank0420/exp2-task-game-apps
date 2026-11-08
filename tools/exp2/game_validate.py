"""ゲームアプリの書き出しデータの検証 (列と型、時刻の順序、回と部分の整合、タッチと操作、動きの記録)。

    python3 tools/validate_session.py <exp2_game の被験者フォルダ、exp2_game、またはその親>

結果は課題アプリの検証 (validate.py) と同じ3段階。ERROR が1つでもあれば終了コード 1。
iPhone 上の簡単なチェック (GameIntegrity.swift) より詳しく、記録どうしの食い違いまで見る。
"""

from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

from . import game_schema
from .load import convert, read_raw
from .merge_game import MergeGame
from .sequence import SplitMix64
from .validate import CLOCK_DRIFT_WARN_MS, SAME_INSTANT_TOLERANCE_MS, Issue, _Report

# 動きの記録の間隔がこれ以上空いたら、記録が止まっていた区間として知らせる (ms)
MOTION_GAP_WARN_MS = 1000
# 動きの記録の間隔の中央値が、設定 (1000 / motion_hz) からこの割合以上ずれたら知らせる
MOTION_RATE_TOLERANCE = 0.2
# 机に置いた iPhone の重力の大きさは 1 G。平均がこれ以上ずれたら、単位か軸の扱いを疑う
GRAVITY_NORM_TOLERANCE = 0.05
# 記録の始まりと終わりで、動きの記録がイベントの記録を覆っているかの許容 (ms)
MOTION_COVERAGE_TOLERANCE_MS = 5000
# タッチが、その部分の時間の範囲に収まっているかの許容 (ms)。タッチの時刻は OS がタッチに付けた時刻で、
# 部分の開始・終了はアプリが操作を受け取った時刻なので、わずかに前後しうる
TOUCH_IN_PART_TOLERANCE_MS = 200


def round_seed(base_seed: int, round_index: int) -> int:
    """回の乱数の種 (GameConfig.roundSeed と同じ: SplitMix64(base + round_index) の最初の値の上位53ビット)。"""
    return SplitMix64(base_seed + round_index).next() >> 11


def validate_game_session(folder: str | Path) -> list[Issue]:
    folder = Path(folder)
    r = _Report()

    # --- ファイル ---
    for name in [game_schema.META_FILE, *game_schema.TABLES]:
        if not (folder / name).exists():
            r.error("ファイル", f"{name} がありません")
    if not (folder / "game_state.json").exists():
        r.warn("ファイル", "game_state.json がありません (作成直後に落ちた可能性)")
    for p in sorted(folder.glob("*.partial_*.txt")):
        r.warn("ファイル", f"途切れた行を移したファイルがあります: {p.name} ({p.stat().st_size} バイト)")
    for p in sorted(folder.glob(".*.tmp")):
        r.warn("ファイル", f"書きかけの一時ファイルが残っています: {p.name}")
    if any(i.level == "ERROR" for i in r.issues):
        return r.issues

    # --- game_meta.json ---
    try:
        meta = json.loads((folder / game_schema.META_FILE).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        r.error("meta", f"{game_schema.META_FILE} が読めません: {e}")
        return r.issues
    _check_meta(meta, folder, r)
    config = meta.get("config_snapshot") or {}
    pid = meta.get("participant_id")

    # --- 列と型 ---
    tables: dict[str, pd.DataFrame] = {}
    for name, columns in game_schema.TABLES.items():
        df, problems = convert(read_raw(folder / name), columns)
        for p in problems:
            r.error(f"列と型 ({name})", p)
        if problems:
            continue
        if not df.empty and set(df["participant_id"]) != {pid}:
            r.error(f"列と型 ({name})", f"participant_id が {game_schema.META_FILE} ({pid}) と違う行があります")
        tables[name] = df
    if len(tables) < len(game_schema.TABLES):
        return r.issues
    events = tables["game_events.csv"]
    rounds = tables["game_rounds.csv"]
    touches = tables["game_touches.csv"]
    motion = tables["game_motion.csv"]

    _check_events(events, meta, r)
    _check_rounds(rounds, events, config, r, completed=bool(meta.get("completed")))
    _check_touches(touches, rounds, config, r)
    _check_guide(events, touches, r)
    _check_motion(motion, events, config, r)
    return r.issues


def _check_meta(meta: dict, folder: Path, r: _Report) -> None:
    for key in ["schema_version", "app_kind", "participant_id", "mode", "created_at", "config_snapshot", "completed",
                "device", "screen"]:
        if key not in meta:
            r.error("meta", f"{key} がありません")
    if meta.get("app_kind") != "game":
        r.error("meta", f"app_kind が game ではありません ({meta.get('app_kind')})")
    if meta.get("schema_version") != game_schema.GAME_SCHEMA_VERSION:
        r.error("meta", f"schema_version が {meta.get('schema_version')} です (このスクリプトは {game_schema.GAME_SCHEMA_VERSION})")
    pid = meta.get("participant_id", "")
    if pid != folder.name:
        r.error("meta", f"participant_id ({pid}) がフォルダ名 ({folder.name}) と違います")
    is_dev = meta.get("mode") == "dev"
    if is_dev != pid.startswith("DEV_"):
        r.error("meta", f"mode ({meta.get('mode')}) と ID の DEV_ の有無が合いません")
    if is_dev:
        r.info("meta", "開発用モードのデータです" + (" (疑似プレイヤー)" if meta.get("config_snapshot", {}).get("simulated_player") else ""))
    if not meta.get("completed"):
        r.error("meta", "記録が終了していません (実験者が記録終了まで進めていない)")


def _check_events(events: pd.DataFrame, meta: dict, r: _Report) -> None:
    check = "時刻の順序 (events)"
    n = len(events)
    if list(events["event_index"]) != list(range(n)):
        r.error(check, "event_index が 0 から連続していません")
    mono_back = events["mono_ms"].diff() < 0
    for i in mono_back[mono_back].index:
        et = events.at[i, "event_type"]
        if et in ("app_launch", "session_resume", "partial_line_recovered"):
            r.warn(check, f"event_index {events.at[i, 'event_index']} ({et}) で単調時刻が戻っています。"
                   "再開の前に端末が再起動された可能性があります")
        else:
            r.error(check, f"event_index {events.at[i, 'event_index']} ({et}) で単調時刻が戻っています")
    if (events["unix_ms"].diff() < 0).any():
        r.warn(check, "Unix 時刻が戻っている箇所があります (端末の時計の補正)")
    boot = mono_back.cumsum()
    offset = events["unix_ms"] - events["mono_ms"]
    drift = (offset.groupby(boot).max() - offset.groupby(boot).min()).max()
    if drift > CLOCK_DRIFT_WARN_MS:
        r.warn(check, f"Unix 時刻と単調時刻の差が最大 {drift} ms 動いています。実験中に端末の時計が補正された可能性があり、"
               "課題アプリや IMU との突き合わせに影響します")
    et = events["event_type"].astype(str)
    if (et == "system_clock_changed").any():
        r.warn(check, "記録中に端末の時計が変更されました (system_clock_changed)")
    bg = int((et == "scene_background").sum())
    if bg:
        r.warn("アプリの状態", f"アプリが背面に回ったことが {bg} 回あります (アクセスガイドが効いていなかった可能性)")
    unavailable = events[et == "motion_unavailable"]
    if not unavailable.empty:
        if unavailable["detail"].fillna("").str.contains("synthetic=1").all():
            # シミュレータの開発用モード: センサの代わりに疑似の動きを記録している
            r.info("アプリの状態", "iPhone の動きのセンサがないため、疑似の動きを記録しています (開発用モード)")
        else:
            r.warn("アプリの状態", "iPhone の動きのセンサが使えませんでした")
    if (et == "motion_error").any():
        r.warn("アプリの状態", "iPhone の動きの記録でエラーがありました")
    if meta.get("mode") == "production":
        ga = events[et.isin(["guided_access_on", "guided_access_off"])]
        starts = events[et == "round_start"]
        first = starts["mono_ms"].min() if not starts.empty else None
        before = ga[ga["mono_ms"] <= first] if first is not None else ga
        if before.empty or str(before.iloc[-1]["event_type"]) != "guided_access_on":
            r.warn("アプリの状態", "最初のゲームを始めたときにアクセスガイドがオンになっていません")
    for t, label in [("session_resume", "再開"), ("memory_warning", "メモリ不足の警告"), ("low_battery", "電池残量の低下")]:
        k = int((et == t).sum())
        if k:
            r.info("イベント", f"{label}: {k} 回")


def _check_rounds(rounds: pd.DataFrame, events: pd.DataFrame, config: dict, r: _Report, completed: bool = True) -> None:
    check = "回と部分"
    if rounds.empty:
        r.warn(check, "ゲームを1回も遊んでいません")
        return
    # 部分は1つずつしか遊べないので、時刻の順に重ならずに並ぶ
    ordered = rounds.sort_values("start_mono_ms")
    if list(ordered.index) != list(rounds.index):
        r.error(check, "game_rounds.csv の行が開始時刻の順になっていません")
    if (rounds["end_mono_ms"] < rounds["start_mono_ms"]).any() or (rounds["end_unix_ms"] < rounds["start_unix_ms"]).any():
        r.error(check, "終了が開始より前の部分があります")
    overlap = ordered["start_mono_ms"].to_numpy()[1:] < ordered["end_mono_ms"].to_numpy()[:-1]
    if overlap.any():
        r.error(check, f"時間が重なっている部分が {int(overlap.sum())} か所あります")

    # 回の番号は、最初に始めた順に 0 から抜けなく振られる
    first_seen = list(dict.fromkeys(ordered["round_index"]))
    if first_seen != list(range(len(first_seen))):
        r.error(check, "round_index が始めた順に 0 から連続していません")
    base = config.get("base_seed")
    for idx, g in rounds.groupby("round_index", sort=True):
        g = g.sort_values("part")
        label = f"round_index {idx}"
        if list(g["part"]) != list(range(len(g))):
            r.error(check, f"{label}: part が 0 から連続していません")
        if g["game"].nunique() != 1 or g["round_seed"].nunique() != 1:
            r.error(check, f"{label}: 部分ごとにゲームか種が違います")
        game = str(g["game"].iloc[0])
        if base is not None and int(g["round_seed"].iloc[0]) != round_seed(base, int(idx)):
            r.error(check, f"{label}: round_seed が設定の種から決まる値と違います")
        if game == "stack" and len(g) > 1:
            r.error(check, f"{label}: 積み上げ型の回が複数の部分に分かれています")
        if (g["score_end"] < g["score_start"]).any():
            r.error(check, f"{label}: 得点が部分の中で減っています")
        if (g["score_start"].to_numpy()[1:] != g["score_end"].to_numpy()[:-1]).any():
            r.error(check, f"{label}: 部分の始めの得点が、前の部分の終わりの得点と違います")
        mid = g["end_reason"].astype(str).iloc[:-1]
        if mid.isin(["game_over", "new_game"]).any():
            r.error(check, f"{label}: 回が終わったあとに続きの部分があります")
        if game == "stack" and int(g["score_start"].iloc[0]) != 0:
            r.error(check, f"{label}: 積み上げ型の得点が 0 から始まっていません")

    # ベストスコア: 部分を始めた時点までに終わった、同じゲームの部分の得点の最大 (被験者ごとに 0 から)
    for game in game_schema.GAMES:
        rows = rounds[rounds["game"] == game]
        for _, p in rows.iterrows():
            earlier = rows[rows["end_mono_ms"] <= p["start_mono_ms"]]["score_end"]
            expected = int(earlier.max()) if not earlier.empty else 0
            if p["best_before"] != expected:
                r.error(check, f"round_index {p['round_index']} part {p['part']}: best_before ({p['best_before']}) が"
                        f"それまでの最高得点 ({expected}) と違います")
                break

    # round_start イベントと一致する。記録を終えていなければ、遊んでいる最中の部分はまだ行がない
    starts = events[events["event_type"].astype(str) == "round_start"]
    if not completed and len(starts) == len(rounds) + 1:
        starts = starts.iloc[:-1]
    if len(starts) != len(rounds):
        r.error(check, f"round_start イベント ({len(starts)}) と部分の数 ({len(rounds)}) が違います")
    else:
        diff = starts["mono_ms"].to_numpy() - ordered["start_mono_ms"].to_numpy()
        if (abs(diff) > SAME_INSTANT_TOLERANCE_MS).any():
            r.error(check, "round_start イベントの時刻が game_rounds.csv と違います")

    interrupted = int((rounds["end_reason"].astype(str) == "interrupted").sum())
    if interrupted:
        r.info(check, f"アプリが落ちて中断した部分: {interrupted}")
    for game in game_schema.GAMES:
        g = rounds[rounds["game"] == game]
        play_s = (g["end_mono_ms"] - g["start_mono_ms"]).sum() / 1000
        r.info(check, f"{game}: {g['round_index'].nunique()} 回、ゲームの画面にいた時間 {play_s:.0f} 秒、"
               f"最高得点 {int(g['score_end'].max()) if not g.empty else 0}")


def _check_touches(touches: pd.DataFrame, rounds: pd.DataFrame, config: dict, r: _Report) -> None:
    check = "タッチ"
    if list(touches["touch_index"]) != list(range(len(touches))):
        r.error(check, "touch_index が 0 から連続していません")
    if (touches["up_mono_ms"] < touches["down_mono_ms"]).any():
        r.error(check, "離した時刻が触れた時刻より前のタッチがあります")
    if (touches["down_mono_ms"].diff() < 0).any():
        r.warn(check, "触れた時刻の順に並んでいない行があります (端末の再起動か、複数の指)")
    if touches.empty:
        r.warn(check, "タッチが1つもありません")
        return
    r.info(check, f"タッチ {len(touches)} 回")

    results = touches["result"].fillna("").astype(str)
    in_round = touches["round_index"].notna()
    merge_cfg = config.get("merge", {})
    for _, p in rounds.iterrows():
        label = f"round_index {p['round_index']} part {p['part']}"
        mask = in_round & (touches["round_index"] == p["round_index"]) & (touches["part"] == p["part"])
        t = touches[mask]
        lo = p["start_mono_ms"] - TOUCH_IN_PART_TOLERANCE_MS
        hi = p["end_mono_ms"] + TOUCH_IN_PART_TOLERANCE_MS
        if ((t["down_mono_ms"] < lo) | (t["down_mono_ms"] > hi)).any():
            r.error(check, f"{label}: 部分の時間の外で触れたタッチが、その部分のものになっています")
        res = results[mask]
        if str(p["game"]) == "stack":
            n_actions = int(res.str.contains("drop_").sum())
            placed = int(res.str.contains(r"drop_(?:placed|perfect)").sum())
            if placed != p["score_end"]:
                r.warn(check, f"{label}: 積めた回数 ({placed}) と得点 ({p['score_end']}) が合いません "
                       "(操作の結果がタッチに結び付かなかった可能性)")
        else:
            n_actions = int(res.str.contains(r"move_|no_move").sum())
        if n_actions != p["n_actions"]:
            r.warn(check, f"{label}: 操作の結果が付いたタッチ ({n_actions}) と n_actions ({p['n_actions']}) が合いません")

    # 2048 型: 記録したスワイプの順から盤を再現し、各部分の終わりの得点と比べる
    for idx, g in rounds[rounds["game"] == "merge"].groupby("round_index"):
        game = MergeGame(int(g["round_seed"].iloc[0]), size=merge_cfg.get("size", 4),
                         initial_tiles=merge_cfg.get("initial_tiles", 2),
                         four_probability=merge_cfg.get("four_probability", 0.25))
        for _, p in g.sort_values("part").iterrows():
            mask = in_round & (touches["round_index"] == idx) & (touches["part"] == p["part"])
            for res in results[mask]:
                for item in res.split(";"):
                    if item.startswith("move_"):
                        moved, _ = game.move(item[len("move_"):])
                        if not moved:
                            r.error(check, f"round_index {idx}: 記録では盤が動いたスワイプが、再現では動きません")
            if game.score != p["score_end"]:
                r.error(check, f"round_index {idx} part {p['part']}: スワイプから再現した得点 ({game.score}) が"
                        f"記録 ({p['score_end']}) と違います")
                break


def _check_guide(events: pd.DataFrame, touches: pd.DataFrame, r: _Report) -> None:
    """操作のガイド (app_decisions #77): 最初の操作で消えた回数が出した回数を超えない。積み上げ型の動き出しのタップ
    (result の stack_start) は、ガイドが消えた回数を超えない。"""
    check = "操作のガイド"
    et = events["event_type"].astype(str)
    shows, hides = int((et == "guide_show").sum()), int((et == "guide_hide").sum())
    if hides > shows:
        r.error(check, f"guide_hide ({hides}) が guide_show ({shows}) より多いです")
    starts = int(touches["result"].fillna("").astype(str).str.contains("stack_start").sum())
    if starts > hides:
        r.error(check, f"動き出しのタップ (stack_start、{starts} 回) が、ガイドが消えた回数 ({hides}) より多いです")
    if shows:
        r.info(check, f"出した {shows} 回、最初の操作で消えた {hides} 回")


def _check_motion(motion: pd.DataFrame, events: pd.DataFrame, config: dict, r: _Report) -> None:
    check = "iPhone の動き"
    if motion.empty:
        r.error(check, "動きが1つも記録されていません")
        return
    if list(motion["sample_index"]) != list(range(len(motion))):
        r.error(check, "sample_index が 0 から連続していません")
    gaps = motion["mono_ms"].diff().dropna()
    if (gaps < 0).any():
        r.warn(check, "単調時刻が戻っている箇所があります (再開の前に端末が再起動された可能性)")
    hz = config.get("motion_hz", 50)
    expected = 1000 / hz
    median = float(gaps[gaps >= 0].median()) if not gaps.empty else expected
    if abs(median - expected) > expected * MOTION_RATE_TOLERANCE:
        r.warn(check, f"記録の間隔の中央値が {median:.1f} ms です (設定は {expected:.1f} ms = {hz} Hz)")
    big = gaps[gaps >= MOTION_GAP_WARN_MS]
    resumes = int((events["event_type"].astype(str) == "session_resume").sum())
    if len(big) > resumes:
        r.warn(check, f"記録が {MOTION_GAP_WARN_MS} ms 以上空いた所が {len(big)} か所あります (最大 {int(big.max())} ms、"
               f"うちアプリの再開 {resumes} 回)")
    elif len(big):
        r.info(check, f"記録の空き {len(big)} か所 (アプリが落ちてから再開するまで。最大 {int(big.max())} ms)")
    norm = (motion["grav_x"] ** 2 + motion["grav_y"] ** 2 + motion["grav_z"] ** 2) ** 0.5
    if abs(norm.mean() - 1) > GRAVITY_NORM_TOLERANCE:
        r.warn(check, f"重力の大きさの平均が {norm.mean():.3f} G です (1 G のはず)")

    # 動きの記録が、記録の始まりから終わりまでを覆っている
    et = events["event_type"].astype(str)
    created = events[et == "session_create"]["mono_ms"]
    stopped = events[et == "recording_stop"]["mono_ms"]
    if not created.empty and motion["mono_ms"].iloc[0] - created.iloc[0] > MOTION_COVERAGE_TOLERANCE_MS:
        r.warn(check, f"動きの記録の始まりが、記録開始より {(motion['mono_ms'].iloc[0] - created.iloc[0]) / 1000:.1f} 秒遅いです")
    if not stopped.empty and stopped.iloc[-1] - motion["mono_ms"].iloc[-1] > MOTION_COVERAGE_TOLERANCE_MS:
        r.warn(check, f"動きの記録の終わりが、記録終了より {(stopped.iloc[-1] - motion['mono_ms'].iloc[-1]) / 1000:.1f} 秒早いです")
    duration_s = (motion["mono_ms"].iloc[-1] - motion["mono_ms"].iloc[0]) / 1000
    r.info(check, f"{len(motion)} サンプル (平均 {len(motion) / max(duration_s, 1):.1f} Hz、{duration_s / 60:.1f} 分)")
