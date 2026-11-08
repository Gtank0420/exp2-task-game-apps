"""1台版の記録を被験者ごとに1本の時間軸に並べ、状態のラベルを作る (設計書7章)。

    import sys; sys.path.insert(0, "tools")
    from exp2.single_load import load_single_session
    from exp2.single_timeline import SingleLabelParams, build_single_timeline

    tl = build_single_timeline("data/exp2_single/S01")   # 1人分
    labels = tl.labels()                                 # 100 ms ごとの状態
    windows = tl.windows(labels)                         # 5秒窓 (1つの状態にまるごと収まる窓だけに状態が付く)
    imu = tl.attach_imu(labels=labels)                   # AirPods の各サンプルに状態を付ける
    tl.summary(labels)                                   # 人ごとの指標

2台版 (exp2/timeline.py) との違い:
- 時計は iPad の1つだけ。2台の記録の組み合わせ、時計の補正、iPhone の持ち上げの判定は要らない
- ゲームが出ている時間は、ポップアップ (popups.csv) とゲームのみの区間から直接分かる。ゲームの操作はタッチの記録
  (touches.csv の result) から分かる

状態 (state 列の値。設計書7章の表と 11章 #14):
- compute (計算中、On): 計算の画面にいて、回答間隔が本人の基準の slow_factor 倍未満
- game (ゲーム中、Off): ゲームが出ていて、直前のゲームの操作から game_window_ms[ゲーム] 以内
- game_idle (ゲーム画面で止まっている、別に集計): ゲームが出ているが、操作がそれより前 (結果画面のまま止まっている時間を含む)
- onset (出てから最初の操作まで、評価から除く): 遊んだポップアップの、出てから最初のゲームの操作まで
- dismissed (出てすぐ閉じた、評価から除く): ゲームの操作が1つもないまま閉じたポップアップの全体
- neither (どちらでもない、別に集計): 計算の画面で、回答が gap_ms 以上止まっている
- ambiguous (あいまい、評価から除く): 遅い回答 (基準の slow_factor 倍以上、gap_ms 未満)、状態の切り替わりの前後
回答間隔は、区間の部分の境目と、ポップアップが出た・閉じた時刻でも区切る (ゲームの時間を回答間隔に入れない)。
閾値はすべて SingleLabelParams の1か所にあり、感度分析で変えられる (2台版の LabelParams と同じ考え方)。
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

from .single_load import SingleSession, load_single_session
from .timeline import _blur_transitions, _intervals_mask
from .validate import Issue

STATES = ("compute", "game", "game_idle", "onset", "dismissed", "neither", "ambiguous")
# 評価 (On / Off の判別) に使う状態と、その扱い
ON_STATES = ("compute",)
OFF_STATES = ("game",)
# ゲームの操作として数える touches.csv の result (受け付けなかった操作 blocked は数えない)
GAME_ACTION_PATTERN = r"(?:^|;)(?:drop_|move_|no_move|stack_start)"


@dataclass
class SingleLabelParams:
    """状態のラベルの閾値。感度分析ではここを変えて回す。"""

    # 基準の何倍以上の回答間隔を「遅い回答」(あいまい) とするか (設計書7章: 2倍)
    slow_factor: float = 2.0
    # この長さ以上の回答間隔は「計算していない」(設計書7章: 5秒)
    gap_ms: int = 5_000
    # 基準速度: 計算のみの区間の最初のこの時間を除いた回答間隔の中央値 (設計書7章)
    baseline_skip_ms: int = 30_000
    # 「ゲーム中」とみなす、直前のゲームの操作からの時間 (ゲームごと)。2048 型は考えるゲームで操作の間が長くなりうるので
    # ゲームごとに変えられるようにした (設計書7章)。どちらも仮に5秒 (single_decisions S20)。予備実験の記録を見て決める
    game_window_ms: dict = field(default_factory=lambda: {"stack": 5_000, "merge": 5_000})
    # 状態の切り替わりの前後をあいまいにする幅 (2台版と同じ仮の値)
    transition_margin_ms: int = 1_000
    grid_ms: int = 100


def single_label_params_dict(params: SingleLabelParams) -> dict:
    return asdict(params)


def baseline_interval_ms(session: SingleSession, params: SingleLabelParams) -> tuple[float | None, int]:
    """基準の回答間隔 (計算のみの区間の最初の baseline_skip_ms を除いた、回答間隔の中央値) と、使った間隔の数。
    2台版の timeline.baseline_interval_ms と同じ計算 (計算のみの区間にはポップアップが出ないので、そのまま使える)。"""
    it = session.items[(session.items["segment"] == "focus") & session.items["response"].notna()]
    diffs = []
    for _, g in it.groupby("part"):
        e = g["answered_elapsed_ms"].astype("int64").to_numpy()
        d = np.diff(e)
        diffs.extend(d[e[:-1] >= params.baseline_skip_ms])
    if not diffs:
        return None, 0
    return float(np.median(diffs)), len(diffs)


@dataclass
class SingleTimeline:
    participant_id: str
    session: SingleSession
    params: SingleLabelParams
    issues: list[Issue] = field(default_factory=list)
    baseline_ms: float | None = None

    @property
    def t0_unix_ms(self) -> int:
        """最初の区間 (計算のみ) の開始 (t_s = 0)"""
        return int(self.session.segments["start_unix_ms"].min())

    def _t_s(self, unix):
        return (unix - self.t0_unix_ms) / 1000

    # --- ゲームの画面と操作 ---

    def game_screens(self) -> pd.DataFrame:
        """ゲームが出ていた時間 (ゲームのみの区間の部分と、ポップアップ)。列: start_unix_ms, end_unix_ms, kind, popup_index"""
        rows = []
        s = self.session.segments
        for _, p in s[s["segment"] == "game_only"].iterrows():
            rows.append((int(p["start_unix_ms"]), int(p["end_unix_ms"]), "game_only", pd.NA))
        for _, p in self.session.popups.iterrows():
            rows.append((int(p["shown_unix_ms"]), int(p["closed_unix_ms"]), "popup", int(p["popup_index"])))
        return pd.DataFrame(rows, columns=["start_unix_ms", "end_unix_ms", "kind", "popup_index"])

    def game_actions(self) -> pd.DataFrame:
        """ゲームの操作 (落とした、スワイプした) のタッチ。時刻は触れた時刻、game はそのときのゲーム"""
        t = self.session.touches
        act = t[t["result"].fillna("").astype(str).str.contains(GAME_ACTION_PATTERN)]
        return pd.DataFrame({"unix_ms": act["down_unix_ms"].astype("int64").to_numpy(),
                             "game": act["game"].astype(str).to_numpy(),
                             "popup_index": act["popup_index"].to_numpy()}).sort_values("unix_ms")

    # --- 回答間隔 ---

    def _answer_intervals(self, segment: str) -> pd.DataFrame:
        """計算の画面にいた間を、回答と回答の間に区切る。区間の部分の始めと終わり、ポップアップの出た・閉じた時刻も
        境目にする (ゲームの時間は回答間隔に入れない)。列: part, start_unix_ms, end_unix_ms, duration_ms"""
        rows = []
        items = self.session.items
        pops = self.session.popups
        for _, p in self.session.segments[self.session.segments["segment"] == segment].iterrows():
            it = items[(items["segment"] == segment) & (items["part"] == p["part"]) & items["response"].notna()]
            # 回答の時刻は区間の経過時間から Unix 時刻に直す (2台版と同じ。部分の中で単調時刻と対応する)
            ans = p["start_unix_ms"] + (it["answered_elapsed_ms"].astype("int64").to_numpy() - p["start_elapsed_ms"])
            pp = pops[(pops["shown_unix_ms"] < p["end_unix_ms"]) & (pops["closed_unix_ms"] > p["start_unix_ms"])]
            # 計算の画面にいた時間の切れ目 (部分の始め〜最初のポップアップ、閉じた〜次のポップアップ、…〜部分の終わり)
            edges = [(int(p["start_unix_ms"]), "start")]
            for _, q in pp.iterrows():
                edges.append((int(q["shown_unix_ms"]), "popup_shown"))
                edges.append((int(q["closed_unix_ms"]), "popup_closed"))
            edges.append((int(p["end_unix_ms"]), "end"))
            for k in range(0, len(edges), 2):
                lo, hi = edges[k][0], edges[k + 1][0]
                if hi <= lo:
                    continue
                a = np.sort(ans[(ans > lo) & (ans < hi)])
                bounds = np.concatenate([[lo], a, [hi]]).astype("int64")
                for j in range(len(bounds) - 1):
                    rows.append((int(p["part"]), int(bounds[j]), int(bounds[j + 1]), int(bounds[j + 1] - bounds[j])))
        return pd.DataFrame(rows, columns=["part", "start_unix_ms", "end_unix_ms", "duration_ms"])

    # --- 状態のラベル ---

    def labels(self, segments: tuple[str, ...] = ("focus", "game_only", "free")) -> pd.DataFrame:
        """grid_ms ごとの状態。時刻は各刻みの中央。

        列: on_game_screen (ゲームが出ている)、popup_index、since_shown_ms (ポップアップが出てからの時間、設計書8.2)、
        computing、slow、gap、game_active (直前のゲームの操作から game_window_ms 以内)、raw_state、state
        """
        p = self.params
        gs = self.game_screens()
        actions = self.game_actions()
        act_t = actions["unix_ms"].to_numpy()
        act_window = np.array([p.game_window_ms.get(g, max(p.game_window_ms.values())) for g in actions["game"]],
                              dtype="int64")
        pops = self.session.popups
        out = []
        for seg in segments:
            parts = self.session.segments[self.session.segments["segment"] == seg]
            ai = self._answer_intervals(seg) if seg != "game_only" else pd.DataFrame(
                columns=["part", "start_unix_ms", "end_unix_ms", "duration_ms"])
            for _, part in parts.iterrows():
                n = int((part["end_unix_ms"] - part["start_unix_ms"]) // p.grid_ms)
                if n <= 0:
                    continue
                t = part["start_unix_ms"] + np.arange(n) * p.grid_ms + p.grid_ms // 2
                on_game = _intervals_mask(t, gs["start_unix_ms"].to_numpy(), gs["end_unix_ms"].to_numpy())

                # ポップアップの番号と、出てからの時間
                popup_index = np.full(n, -1)
                since = np.full(n, -1, dtype="int64")
                is_onset = np.zeros(n, dtype=bool)
                is_dismissed = np.zeros(n, dtype=bool)
                for _, q in pops.iterrows():
                    m = (t >= q["shown_unix_ms"]) & (t < q["closed_unix_ms"])
                    popup_index[m] = int(q["popup_index"])
                    since[m] = t[m] - int(q["shown_unix_ms"])
                    if q["n_actions"] == 0:
                        is_dismissed |= m
                    else:
                        is_onset |= m & (t < q["shown_unix_ms"] + int(q["first_action_ms"]))

                # 直前のゲームの操作から、そのゲームの game_window_ms 以内か
                i = np.searchsorted(act_t, t, side="right") - 1
                active = np.zeros(n, dtype=bool)
                ok = i >= 0
                active[ok] = t[ok] - act_t[i[ok]] <= act_window[i[ok]]
                active &= on_game

                # 計算の画面: その時刻を含む回答間隔の長さ
                a = ai[ai["part"] == part["part"]]
                dur = np.full(n, 10 ** 9)
                if len(a):
                    k = np.clip(np.searchsorted(a["start_unix_ms"].to_numpy(), t, side="right") - 1, 0, len(a) - 1)
                    inside = (t >= a["start_unix_ms"].to_numpy()[k]) & (t < a["end_unix_ms"].to_numpy()[k])
                    dur = np.where(inside, a["duration_ms"].to_numpy()[k], dur)
                limit = p.slow_factor * self.baseline_ms if self.baseline_ms else p.gap_ms
                computing = ~on_game & (dur < limit)
                gap = ~on_game & (dur >= p.gap_ms)
                slow = ~on_game & ~computing & ~gap

                raw = np.select(
                    [is_dismissed, is_onset, on_game & active, on_game, computing, gap],
                    ["dismissed", "onset", "game", "game_idle", "compute", "neither"],
                    default="ambiguous")
                state = _blur_transitions(raw, int(p.transition_margin_ms // p.grid_ms))
                out.append(pd.DataFrame({
                    "participant_id": self.participant_id, "segment": seg, "part": int(part["part"]),
                    "unix_ms": t.astype("int64"),
                    "elapsed_ms": (part["start_elapsed_ms"] + np.arange(n) * p.grid_ms + p.grid_ms // 2).astype("int64"),
                    "on_game_screen": on_game,
                    "popup_index": pd.array(np.where(popup_index >= 0, popup_index, None), dtype="Int64"),
                    "since_shown_ms": pd.array(np.where(since >= 0, since, None), dtype="Int64"),
                    "computing": computing, "slow": slow, "gap": gap, "game_active": active,
                    "raw_state": raw, "state": state}))
        if not out:
            return pd.DataFrame()
        df = pd.concat(out, ignore_index=True)
        df.insert(4, "t_s", self._t_s(df["unix_ms"]))
        df["state"] = df["state"].astype(pd.CategoricalDtype(list(STATES)))
        return df

    # --- 窓 ---

    def windows(self, labels: pd.DataFrame | None = None, window_ms: int = 5_000, stride_ms: int = 1_000) -> pd.DataFrame:
        """IMU の窓 (5秒窓、1秒ストライド)。2台版の Timeline.windows と同じ決まり: 窓が1つの状態にまるごと収まるときだけ
        state を付け、境目にまたがる窓とあいまいを含む窓は state を空にする。区間の部分をまたぐ窓は作らない。"""
        labels = self.labels() if labels is None else labels
        p = self.params
        per = window_ms // p.grid_ms
        rows = []
        for (seg, part), g in labels.groupby(["segment", "part"], sort=False):
            states = g["state"].astype(str).to_numpy()
            t = g["unix_ms"].to_numpy()
            el = g["elapsed_ms"].to_numpy()
            for s in range(0, len(g) - per + 1, stride_ms // p.grid_ms):
                w = states[s:s + per]
                uniq = set(w)
                if len(uniq) == 1 and "ambiguous" not in uniq:
                    state, reason = w[0], ""
                else:
                    state, reason = None, ("ambiguous" if "ambiguous" in uniq else "mixed")
                start = int(t[s] - p.grid_ms // 2)
                rows.append((self.participant_id, seg, part, start, start + window_ms, start + window_ms // 2,
                             int(el[s] - p.grid_ms // 2), state, reason))
        df = pd.DataFrame(rows, columns=["participant_id", "segment", "part", "start_unix_ms", "end_unix_ms",
                                         "center_unix_ms", "start_elapsed_ms", "state", "reason"])
        df["center_t_s"] = self._t_s(df["center_unix_ms"])
        return df

    # --- IMU ---

    def attach_imu(self, labels: pd.DataFrame | None = None) -> pd.DataFrame | None:
        """AirPods の各サンプル (センサの時刻 unix_ms) に状態を付ける。記録がなければ None。
        時計は iPad の1つなので補正はない。2台版と同じく、刻みの中央にいちばん近いラベルを付ける。"""
        imu = self.session.headphone
        if imu is None:
            return None
        labels = self.labels() if labels is None else labels
        out = imu.copy()
        out["t_s"] = self._t_s(out["unix_ms"])
        lab = labels[["unix_ms", "segment", "state", "popup_index"]].rename(columns={"unix_ms": "label_unix_ms"})
        merged = pd.merge_asof(out[["unix_ms"]].reset_index().sort_values("unix_ms"), lab.sort_values("label_unix_ms"),
                               left_on="unix_ms", right_on="label_unix_ms", direction="nearest",
                               tolerance=self.params.grid_ms // 2 + 1).set_index("index").sort_index()
        out["segment"] = merged["segment"]
        out["state"] = merged["state"]
        out["popup_index"] = merged["popup_index"]
        return out

    # --- 出来事と区間の表 ---

    def events_table(self) -> pd.DataFrame:
        """出来事 (events.csv、回答、タッチ) を1本の時間軸に並べた表。"""
        s = self.session
        ev = s.events
        rows = [pd.DataFrame({"unix_ms": ev["unix_ms"], "kind": ev["event_type"].astype(str),
                              "segment": ev["segment"].astype(str), "popup_index": ev["popup_index"],
                              "detail": ev["detail"]})]
        it = s.items[s.items["response"].notna()]
        rows.append(pd.DataFrame({"unix_ms": it["answered_unix_ms"].astype("int64"), "kind": "answer",
                                  "segment": it["segment"].astype(str), "popup_index": pd.NA,
                                  "detail": "correct=" + it["is_correct"].astype(int).astype(str)
                                            + " rt_ms=" + it["rt_ms"].astype(str)}))
        tc = s.touches
        rows.append(pd.DataFrame({"unix_ms": tc["down_unix_ms"], "kind": "touch", "segment": tc["segment"].astype(str),
                                  "popup_index": tc["popup_index"],
                                  "detail": tc["screen"].astype(str) + " " + tc["touch_type"].astype(str) + " "
                                            + tc["result"].fillna("").astype(str)}))
        df = pd.concat(rows, ignore_index=True).sort_values("unix_ms", kind="stable").reset_index(drop=True)
        df["segment"] = df["segment"].replace({"nan": None, "None": None})
        df.insert(0, "participant_id", self.participant_id)
        df.insert(2, "t_s", self._t_s(df["unix_ms"]))
        return df

    def intervals_table(self) -> pd.DataFrame:
        """区間、ゲームが出ていた時間 (ポップアップ、ゲームのみの区間)、ゲームの部分、長い回答の空き。"""
        s = self.session
        rows = []
        for _, p in s.segments.iterrows():
            rows.append(("segment", p["start_unix_ms"], p["end_unix_ms"], str(p["segment"]),
                         f"part={p['part']} end_reason={p['end_reason']}"))
        for _, q in s.popups.iterrows():
            rows.append(("popup", q["shown_unix_ms"], q["closed_unix_ms"], str(q["game"]),
                         f"popup_index={q['popup_index']} close_reason={q['close_reason']} n_actions={q['n_actions']}"))
        for _, r in s.rounds.iterrows():
            rows.append(("game_part", r["start_unix_ms"], r["end_unix_ms"], str(r["game"]),
                         f"round_index={r['round_index']} part={r['part']} end_reason={r['end_reason']} "
                         f"score={r['score_start']}->{r['score_end']}"))
        for seg in ("focus", "free"):
            for _, a in self._answer_intervals(seg).iterrows():
                if a["duration_ms"] >= self.params.gap_ms:
                    rows.append(("answer_gap", a["start_unix_ms"], a["end_unix_ms"], seg,
                                 f"duration_ms={a['duration_ms']}"))
        df = pd.DataFrame(rows, columns=["kind", "start_unix_ms", "end_unix_ms", "label", "detail"])
        df = df.astype({"start_unix_ms": "int64", "end_unix_ms": "int64"}).sort_values("start_unix_ms", kind="stable")
        df.insert(0, "participant_id", self.participant_id)
        df["start_t_s"] = self._t_s(df["start_unix_ms"])
        df["end_t_s"] = self._t_s(df["end_unix_ms"])
        return df.reset_index(drop=True)

    # --- 人ごとの指標 ---

    def summary(self, labels: pd.DataFrame | None = None) -> dict:
        """人ごとの指標 (設計書7章のスループットと作業率、状態の割合、9章 ② のポップアップの指標)。"""
        labels = self.labels() if labels is None else labels
        p = self.params
        s = self.session
        free_items = s.items[(s.items["segment"] == "free") & s.items["response"].notna()]
        free_ms = int(s.planned_duration_ms("free"))
        n_correct = int(free_items["is_correct"].fillna(False).sum())
        raw = n_correct / (free_ms / 60_000)
        base_speed = 60_000 / self.baseline_ms if self.baseline_ms else None
        ai = self._answer_intervals("free")
        work = ai[ai["duration_ms"] < p.gap_ms]["duration_ms"].sum()
        frac = labels[labels["segment"] == "free"]["state"].value_counts(normalize=True)
        pops = s.popups
        played = pops[pops["n_actions"] > 0]
        return {
            "participant_id": self.participant_id,
            "baseline_interval_ms": self.baseline_ms,
            "free_n_answered": len(free_items),
            "free_n_correct": n_correct,
            "free_error_rate": 1 - n_correct / len(free_items) if len(free_items) else None,
            "raw_throughput_per_min": raw,
            "calibrated_throughput": raw / base_speed if base_speed else None,
            # 作業率 = 計算の画面で回答間隔が gap_ms 未満の時間 ÷ 区間の長さ (設計書7章。ゲームの時間は分子に入らない)
            "work_rate": work / free_ms,
            **{f"free_frac_{k}": float(frac.get(k, 0.0)) for k in STATES},
            "n_popups": len(pops),
            "n_played": len(played),
            "play_rate": len(played) / len(pops) if len(pops) else None,
            "dismissed_rate": 1 - len(played) / len(pops) if len(pops) else None,
            "popup_s_total": pops["duration_ms"].sum() / 1000,
            "play_s_mean": played["duration_ms"].mean() / 1000 if len(played) else None,
            "first_touch_ms_median": float(pops["first_touch_ms"].median()) if pops["first_touch_ms"].notna().any() else None,
            "first_action_ms_median": float(played["first_action_ms"].median()) if len(played) else None,
            "n_in_guard_touches": int(pops["n_in_guard_touches"].sum()),
        }


def build_single_timeline(folder: str | Path, params: SingleLabelParams | None = None) -> SingleTimeline:
    """1人分の時間軸を作る。"""
    params = params or SingleLabelParams()
    session = load_single_session(folder)
    tl = SingleTimeline(session.participant_id, session, params)
    tl.baseline_ms, n = baseline_interval_ms(session, params)
    if tl.baseline_ms is None:
        tl.issues.append(Issue("WARN", "基準速度", "計算のみの区間の回答間隔がないので、計算中の判定に gap_ms を使います"))
    elif n < 30:
        tl.issues.append(Issue("WARN", "基準速度", f"基準速度を {n} 個の回答間隔から求めています (少ない)"))
    if session.popups.empty:
        tl.issues.append(Issue("WARN", "ポップアップ", "自由区間にポップアップが1回も出ていません"))
    return tl
