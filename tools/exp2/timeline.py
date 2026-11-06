"""2つのアプリ (課題アプリ、ゲームアプリ) の記録を、被験者ごとに1本の時間軸に統合し、状態のラベルを作る。

    import sys; sys.path.insert(0, "tools")
    from exp2.timeline import pair_sessions, build_timeline, LabelParams

    pairs = pair_sessions("data")                     # data/exp2_data と data/exp2_game の組を決める (ID の食い違いを警告)
    tl = build_timeline(pairs[0])                     # 1人分
    tl.events_table()                                 # 3つの記録の出来事を1本の時間軸に並べた表
    labels = tl.labels()                              # 100 ms ごとの状態 (設計書7章)
    windows = tl.windows()                            # 5秒窓 (1つの状態にまるごと収まる窓だけに状態が付く)
    imu = tl.attach_imu()                             # AirPods の各サンプルに状態を付ける (課題アプリの記録、schema_version 4 から)
    imu = tl.attach_imu(load_imu_sqlite("imu.db"))    # 既存の IMU アプリの記録 (それより前) を使うとき

時間軸:
- 共通の時間軸は iPad (課題アプリ) の Unix 時刻 (ms)。ゲームアプリと IMU の時刻は、それぞれの補正値
  (game_offset_ms、imu_offset_ms) を「足して」iPad の時間軸にそろえる。iPhone の時計が 3 秒進んでいたら
  game_offset_ms = -3000。補正値は初期値 0 で、estimate_game_offset() が確かめる材料を出す
- 2026-11-04 から AirPods の IMU は課題アプリが iPad の時計で記録する (app_decisions #72) ので、imu_offset_ms は 0 のまま。
  時刻はセンサの時刻 (unix_ms) を使う
- t_s は、最初の区間 (計算のみ) の開始 (点滅が終わった瞬間) を 0 とした秒。図や確認用

状態 (設計書7章。state 列の値):
- compute (計算中): 回答間隔が本人の基準 (計算のみの区間の回答間隔の中央値) の slow_factor 倍未満で続いていて、
  ゲーム用 iPhone を持っていない
- game (ゲーム中): iPhone を持ち上げてから置くまで (動きから判定)。机に置いたまま遊んだ場合は、ゲームの画面にいて、
  直前のタッチから touch_window_ms 以内
- neither (どちらでもない): 回答が gap_ms 以上止まっていて、ゲームもしていない
- ambiguous (あいまい): 遅い回答 (基準の slow_factor 倍以上、gap_ms 未満)、計算中とゲーム中の条件を両方満たす時間、
  状態の切り替わりの前後 transition_margin_ms
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

from . import game_schema
from .game_load import GameSession, game_session_folders, load_game_session
from .load import Session, load_session, session_folders
from .validate import Issue

STATES = ("compute", "game", "neither", "ambiguous")


@dataclass
class LabelParams:
    """状態のラベルの閾値。感度分析 (設計書7章: 3秒・10秒など) ではここを変えて回す。"""

    # 基準の何倍以上の回答間隔を「遅い回答」(あいまい) とするか (設計書7章: 2倍)
    slow_factor: float = 2.0
    # この長さ以上の回答間隔は「計算していない」(設計書7章: 5秒。IMU の窓と同じ長さ)
    gap_ms: int = 5_000
    # 基準速度: 計算のみの区間の最初のこの時間を除いた回答間隔の中央値 (設計書7章: 最初の30秒を除く)
    baseline_skip_ms: int = 30_000
    # 机に置いたまま遊んだ場合、直前のタッチからこの時間まではゲーム中 (設計書7章: 5秒)
    touch_window_ms: int = 5_000
    # 状態の切り替わりの前後をあいまいにする幅。設計書に値がないので仮の値 (2026-11-01 の相談で「適当な値で」)
    transition_margin_ms: int = 1_000
    # ラベルの時間の刻み
    grid_ms: int = 100
    # 持ち上げの判定 (予備実験⑦でカメラ映像と照らし合わせて決める。いまは仮の値)。傾きと手の揺れの両方を見る:
    # - 傾き: 画面を上にして机に置いた状態からの傾きが lift_enter_deg を超えたら持ち上げ、lift_exit_deg を
    #   下回ったら置いた (行ったり来たりしないよう、入りと出で値を変える)
    # - 揺れ: 回転の速さ (3軸の大きさ) の still_window_ms ごとの中央値が still_rot_rad_s 未満なら静止。
    #   実機 (2026-11-03) では、机の上は 0.004 rad/s 以下、手の中は平らに近く持っていても 0.018 rad/s 以上だった。
    #   傾きだけだと、平らに近く (10〜17°) 持って遊んだ時間を「置いた」と判定したため足した
    # 傾きが小さく、かつ静止しているときだけ「置いている」とし、それ以外は持っているとする
    lift_enter_deg: float = 20.0
    lift_exit_deg: float = 12.0
    still_rot_rad_s: float = 0.01
    still_window_ms: int = 1_000
    # これより短い「置いた」間はつなぎ、これより短い「持ち上げ」は捨てる
    lift_merge_gap_ms: int = 1_500
    lift_min_duration_ms: int = 1_000
    # 2台の記録の組を時間で決めるとき、課題アプリの記録の時間のうち、この割合以上がゲームアプリの記録と重なること
    pair_min_overlap: float = 0.5


# MARK: - 組み合わせ


@dataclass
class Pair:
    """1人分の、課題アプリとゲームアプリの記録の組"""

    participant_id: str
    task_folder: Path
    game_folder: Path | None
    game_participant_id: str | None
    issues: list[Issue] = field(default_factory=list)


def _span(folder: Path, events_file: str, meta_file: str) -> tuple[int, int, str]:
    meta = json.loads((folder / meta_file).read_text(encoding="utf-8"))
    ev = pd.read_csv(folder / events_file, usecols=["unix_ms"])
    return int(ev["unix_ms"].min()), int(ev["unix_ms"].max()), meta.get("mode", "")


def pair_sessions(root: str | Path, game_root: str | Path | None = None,
                  overrides: dict[str, str] | None = None, params: LabelParams | None = None) -> list[Pair]:
    """課題アプリの被験者ごとに、ゲームアプリの記録を組にする。

    root の下の exp2_data と exp2_game を見る (game_root を指定すればそちらから探す)。
    - 同じ ID があり、記録の時間が重なる: そのまま組にする
    - 同じ ID があるが、時間が重ならない: ERROR (ファイルの取り違えか、端末の時計の大きなずれ)
    - 同じ ID がない (2台で入力した ID が食い違う): 時間が重なる記録が1つだけなら、それと組にして WARN
    - overrides {課題の ID: ゲームの ID} で手で決めることもできる (pairs.csv から読む)
    """
    params = params or LabelParams()
    overrides = overrides or {}
    root = Path(root)
    task_folders = session_folders(root)
    game_folders = game_session_folders(Path(game_root) if game_root else root)
    games = {f.name: (f, *_span(f, "game_events.csv", game_schema.META_FILE)) for f in game_folders}
    used: set[str] = set()
    pairs = []

    def overlap(a0, a1, b0, b1) -> float:
        return max(0, min(a1, b1) - max(a0, b0)) / max(a1 - a0, 1)

    for tf in task_folders:
        pid = tf.name
        t0, t1, mode = _span(tf, "events.csv", "meta.json")
        p = Pair(pid, tf, None, None)
        candidates = [g for g, (_, g0, g1, _) in games.items() if overlap(t0, t1, g0, g1) >= params.pair_min_overlap]
        if pid in overrides:
            gid = overrides[pid]
            if gid not in games:
                p.issues.append(Issue("ERROR", "組み合わせ", f"対応表のゲームの ID {gid} の記録がありません"))
            else:
                p.game_participant_id = gid
                p.issues.append(Issue("INFO", "組み合わせ", f"対応表で iPhone の {gid} と組にしました"))
        elif pid in games:
            g0, g1 = games[pid][1], games[pid][2]
            if overlap(t0, t1, g0, g1) >= params.pair_min_overlap:
                p.game_participant_id = pid
            else:
                p.issues.append(Issue("ERROR", "組み合わせ", f"iPhone に同じ ID ({pid}) の記録がありますが、時間が重なりません"
                                      "。ファイルの取り違えか、端末の時計の大きなずれを確かめてください"))
        if p.game_participant_id is None and pid not in overrides:
            others = [g for g in candidates if g not in used and g != pid]
            if len(others) == 1:
                p.game_participant_id = others[0]
                p.issues.append(Issue("WARN", "組み合わせ", f"ID が食い違っています (iPad: {pid}、iPhone: {others[0]})。"
                                      "記録の時間が重なるので組にしました。実験記録で確かめてください"))
            elif len(others) > 1:
                p.issues.append(Issue("ERROR", "組み合わせ", f"時間が重なる iPhone の記録が複数あり、決められません: {others}"))
            elif pid not in games:
                p.issues.append(Issue("WARN", "組み合わせ", "iPhone の記録が見つかりません (ゲームの記録なしで統合します)"))
        if p.game_participant_id:
            gf, _, _, gmode = games[p.game_participant_id]
            p.game_folder = gf
            used.add(p.game_participant_id)
            if gmode != mode:
                p.issues.append(Issue("ERROR", "組み合わせ", f"本番と開発用が混ざっています (iPad: {mode}、iPhone: {gmode})"))
        pairs.append(p)
    for g in games:
        if g not in used:
            pairs_issue = Issue("WARN", "組み合わせ", f"iPhone の記録 {g} に対応する iPad の記録がありません")
            if pairs:
                pairs[-1].issues.append(pairs_issue)
    return pairs


# MARK: - 1人分の時間軸


def _intervals_mask(t: np.ndarray, starts: np.ndarray, ends: np.ndarray) -> np.ndarray:
    """時刻 t が、重ならない区間 [start, end) のどれかに入っているか。"""
    if len(starts) == 0:
        return np.zeros(len(t), dtype=bool)
    order = np.argsort(starts)
    s, e = starts[order], ends[order]
    i = np.searchsorted(s, t, side="right") - 1
    ok = i >= 0
    out = np.zeros(len(t), dtype=bool)
    out[ok] = t[ok] < e[i[ok]]
    return out


def detect_holding(motion: pd.DataFrame, params: LabelParams) -> pd.DataFrame:
    """iPhone の動きから、手に持っていた区間 (持ち上げてから置くまで) を求める。時刻はゲームアプリの Unix 時刻。

    画面を上にして机に置くと、重力はほぼ -z (grav_z ≈ -1)。手に持つと画面を手前に傾けるので、
    -z からの傾きが大きくなる。傾きが lift_enter_deg を超えたら持ち上げ、lift_exit_deg を下回ったら置いたとする。
    ただし平らに近く持たれることもあるので、傾きが小さくても、手の揺れ (回転の速さ) があれば持っているとする。
    机の上ではほとんど回転しない。揺れは still_window_ms の中央値で見る (机を叩いたときの一瞬の揺れを無視する)。
    """
    cols = ["start_unix_ms", "end_unix_ms"]
    if motion is None or motion.empty:
        return pd.DataFrame(columns=cols, dtype="int64")
    t = motion["unix_ms"].to_numpy()
    tilt = np.degrees(np.arccos(np.clip(-motion["grav_z"].to_numpy(), -1, 1)))
    tilted = np.zeros(len(t), dtype=bool)
    state = False
    for i, a in enumerate(tilt):
        state = a > params.lift_exit_deg if state else a > params.lift_enter_deg
        tilted[i] = state
    step = int(np.median(np.diff(t))) if len(t) > 1 else 20
    rot = np.sqrt(motion["rot_x"] ** 2 + motion["rot_y"] ** 2 + motion["rot_z"] ** 2)
    window = max(1, round(params.still_window_ms / max(step, 1)))
    shaking = (rot.rolling(window, center=True, min_periods=1).median() >= params.still_rot_rad_s).to_numpy()
    held = tilted | shaking
    # 連続した「持っている」サンプルを区間にする
    edges = np.diff(np.concatenate([[False], held, [False]]).astype(int))
    starts, ends = np.where(edges == 1)[0], np.where(edges == -1)[0] - 1
    iv = [[int(t[a]), int(t[b]) + step] for a, b in zip(starts, ends)]
    merged: list[list[int]] = []
    for a, b in iv:
        if merged and a - merged[-1][1] < params.lift_merge_gap_ms:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    merged = [m for m in merged if m[1] - m[0] >= params.lift_min_duration_ms]
    return pd.DataFrame(merged, columns=cols, dtype="int64")


def baseline_interval_ms(task: Session, params: LabelParams) -> tuple[float | None, int]:
    """基準の回答間隔 (計算のみの区間の最初の baseline_skip_ms を除いた、回答間隔の中央値) と、使った間隔の数。"""
    it = task.items[(task.items["segment"] == "focus") & task.items["response"].notna()]
    diffs = []
    for _, g in it.groupby("part"):
        e = g["answered_elapsed_ms"].astype("int64").to_numpy()
        d = np.diff(e)
        keep = e[:-1] >= params.baseline_skip_ms
        diffs.extend(d[keep])
    if not diffs:
        return None, 0
    return float(np.median(diffs)), len(diffs)


@dataclass
class Timeline:
    participant_id: str
    game_participant_id: str | None
    task: Session
    game: GameSession | None
    params: LabelParams
    game_offset_ms: int = 0
    issues: list[Issue] = field(default_factory=list)
    holding: pd.DataFrame = field(default_factory=pd.DataFrame)
    baseline_ms: float | None = None

    @property
    def t0_unix_ms(self) -> int:
        """最初の区間 (計算のみ) の開始 (t_s = 0)"""
        return int(self.task.segments["start_unix_ms"].min())

    def _t_s(self, unix: pd.Series) -> pd.Series:
        return (unix - self.t0_unix_ms) / 1000

    # --- 出来事の表 ---

    def events_table(self) -> pd.DataFrame:
        """3つの記録の出来事を1本の時間軸に並べた表 (動きのサンプルは多すぎるので入れない)。"""
        rows = []
        ev = self.task.events
        rows.append(pd.DataFrame({
            "source": "task", "unix_ms": ev["unix_ms"], "kind": ev["event_type"], "segment": ev["segment"].astype(str),
            "game": None, "round_index": pd.NA, "detail": ev["detail"]}))
        it = self.task.items[self.task.items["response"].notna()]
        rows.append(pd.DataFrame({
            "source": "task", "unix_ms": it["answered_unix_ms"].astype("int64"), "kind": "answer",
            "segment": it["segment"].astype(str), "game": None, "round_index": pd.NA,
            "detail": "correct=" + it["is_correct"].astype(int).astype(str) + " rt_ms=" + it["rt_ms"].astype(str)}))
        if self.game is not None:
            off = self.game_offset_ms
            gev = self.game.events
            rows.append(pd.DataFrame({
                "source": "game", "unix_ms": gev["unix_ms"] + off, "kind": gev["event_type"].astype(str), "segment": None,
                "game": gev["game"].astype(object), "round_index": gev["round_index"], "detail": gev["detail"]}))
            tc = self.game.touches
            rows.append(pd.DataFrame({
                "source": "game", "unix_ms": tc["down_unix_ms"] + off, "kind": "touch", "segment": None,
                "game": tc["game"].astype(object), "round_index": tc["round_index"],
                "detail": tc["touch_type"].astype(str) + " " + tc["result"].fillna("").astype(str)}))
            for _, h in self.holding.iterrows():
                rows.append(pd.DataFrame({"source": ["game", "game"], "unix_ms": [h["start_unix_ms"], h["end_unix_ms"]],
                                          "kind": ["lift", "put_down"], "segment": None, "game": None,
                                          "round_index": pd.NA, "detail": ""}))
        df = pd.concat(rows, ignore_index=True).sort_values(["unix_ms", "source"], kind="stable").reset_index(drop=True)
        df.insert(0, "participant_id", self.participant_id)
        df.insert(3, "t_s", self._t_s(df["unix_ms"]))
        df["segment"] = df["segment"].replace({"nan": None, "None": None})
        return df

    # --- 区間の表 ---

    def intervals_table(self) -> pd.DataFrame:
        """区間 (課題アプリの区間、ゲームの部分、持ち上げ、長い回答の空き) を開始と終了の組で並べた表。"""
        rows = []
        for _, s in self.task.segments.iterrows():
            rows.append(("task", "segment", s["start_unix_ms"], s["end_unix_ms"], str(s["segment"]),
                         f"part={s['part']} end_reason={s['end_reason']}"))
        if self.game is not None:
            off = self.game_offset_ms
            for _, r in self.game.rounds.iterrows():
                rows.append(("game", "game_part", r["start_unix_ms"] + off, r["end_unix_ms"] + off, str(r["game"]),
                             f"round_index={r['round_index']} part={r['part']} end_reason={r['end_reason']} "
                             f"score={r['score_start']}->{r['score_end']}"))
            for _, h in self.holding.iterrows():
                rows.append(("game", "holding", h["start_unix_ms"], h["end_unix_ms"], "", ""))
        for seg in ("focus", "free"):
            for _, a in self._answer_intervals(seg).iterrows():
                if a["duration_ms"] >= self.params.gap_ms:
                    rows.append(("task", "answer_gap", a["start_unix_ms"], a["end_unix_ms"], seg,
                                 f"duration_ms={a['duration_ms']}"))
        df = pd.DataFrame(rows, columns=["source", "kind", "start_unix_ms", "end_unix_ms", "label", "detail"])
        df = df.astype({"start_unix_ms": "int64", "end_unix_ms": "int64"}).sort_values("start_unix_ms", kind="stable")
        df.insert(0, "participant_id", self.participant_id)
        df["start_t_s"] = self._t_s(df["start_unix_ms"])
        df["end_t_s"] = self._t_s(df["end_unix_ms"])
        return df.reset_index(drop=True)

    def _answer_intervals(self, segment: str) -> pd.DataFrame:
        """区間の部分ごとに、回答と回答の間 (最初は部分の開始から、最後は部分の終わりまで) を並べる。"""
        rows = []
        items = self.task.items
        for _, p in self.task.segments[self.task.segments["segment"] == segment].iterrows():
            it = items[(items["segment"] == segment) & (items["part"] == p["part"]) & items["response"].notna()]
            # 回答の時刻は区間の経過時間から Unix 時刻に直す (部分の中で単調時刻と対応し、時計の補正の影響を受けない)
            ans = p["start_unix_ms"] + (it["answered_elapsed_ms"].astype("int64").to_numpy() - p["start_elapsed_ms"])
            bounds = np.concatenate([[p["start_unix_ms"]], np.sort(ans), [p["end_unix_ms"]]]).astype("int64")
            for k in range(len(bounds) - 1):
                kind = "start" if k == 0 else ("end" if k == len(bounds) - 2 else "answer")
                rows.append((int(p["part"]), int(bounds[k]), int(bounds[k + 1]), int(bounds[k + 1] - bounds[k]), kind))
        return pd.DataFrame(rows, columns=["part", "start_unix_ms", "end_unix_ms", "duration_ms", "kind"])

    # --- 状態のラベル ---

    def labels(self, segments: tuple[str, ...] = ("focus", "game_only", "free")) -> pd.DataFrame:
        """grid_ms ごとの状態 (設計書7章)。時刻は各刻みの中央。

        列: computing (回答が速く続いている)、slow (遅い回答)、gap (回答が gap_ms 以上止まっている)、holding、
        desk_play (机に置いたまま遊んでいる)、raw_state (切り替わりの前後をあいまいにする前)、state
        """
        p = self.params
        out = []
        for seg in segments:
            parts = self.task.segments[self.task.segments["segment"] == seg]
            ai = self._answer_intervals(seg)
            for _, part in parts.iterrows():
                n = int((part["end_unix_ms"] - part["start_unix_ms"]) // p.grid_ms)
                if n <= 0:
                    continue
                t = part["start_unix_ms"] + np.arange(n) * p.grid_ms + p.grid_ms // 2
                a = ai[ai["part"] == part["part"]]
                k = np.clip(np.searchsorted(a["start_unix_ms"].to_numpy(), t, side="right") - 1, 0, len(a) - 1)
                dur = a["duration_ms"].to_numpy()[k] if len(a) else np.full(n, 10 ** 9)
                limit = p.slow_factor * self.baseline_ms if self.baseline_ms else p.gap_ms
                computing = dur < limit
                gap = dur >= p.gap_ms
                slow = ~computing & ~gap
                holding, desk = self._game_flags(t)
                in_game = holding | desk
                raw = np.where(in_game & computing, "ambiguous",
                               np.where(in_game, "game",
                                        np.where(computing, "compute", np.where(slow, "ambiguous", "neither"))))
                state = _blur_transitions(raw, int(p.transition_margin_ms // p.grid_ms))
                out.append(pd.DataFrame({
                    "participant_id": self.participant_id, "segment": seg, "part": int(part["part"]),
                    "unix_ms": t.astype("int64"),
                    "elapsed_ms": (part["start_elapsed_ms"] + np.arange(n) * p.grid_ms + p.grid_ms // 2).astype("int64"),
                    "computing": computing, "slow": slow, "gap": gap, "holding": holding, "desk_play": desk,
                    "raw_state": raw, "state": state}))
        if not out:
            return pd.DataFrame()
        df = pd.concat(out, ignore_index=True)
        df.insert(4, "t_s", self._t_s(df["unix_ms"]))
        df["state"] = df["state"].astype(pd.CategoricalDtype(list(STATES)))
        return df

    def _game_flags(self, t: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """t (iPad の時間軸) で、iPhone を手に持っているか、机に置いたまま遊んでいるか。"""
        if self.game is None:
            z = np.zeros(len(t), dtype=bool)
            return z, z
        off = self.game_offset_ms
        holding = _intervals_mask(t, self.holding["start_unix_ms"].to_numpy(), self.holding["end_unix_ms"].to_numpy())
        r = self.game.rounds
        in_part = _intervals_mask(t, (r["start_unix_ms"] + off).to_numpy(), (r["end_unix_ms"] + off).to_numpy())
        tc = self.game.touches[self.game.touches["round_index"].notna()]
        downs = np.sort((tc["down_unix_ms"] + off).to_numpy())
        i = np.searchsorted(downs, t, side="right") - 1
        recent = np.zeros(len(t), dtype=bool)
        ok = i >= 0
        recent[ok] = t[ok] - downs[i[ok]] <= self.params.touch_window_ms
        return holding, in_part & recent & ~holding

    # --- 窓 ---

    def windows(self, labels: pd.DataFrame | None = None, window_ms: int = 5_000, stride_ms: int = 1_000) -> pd.DataFrame:
        """IMU の窓 (設計書11章: 5秒窓、1秒ストライド)。窓が1つの状態にまるごと収まるときだけ state を付け、
        境目にまたがる窓とあいまいを含む窓は state を空にする (reason に理由)。区間の部分をまたぐ窓は作らない。"""
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

    def attach_imu(self, imu: pd.DataFrame | None = None, imu_offset_ms: int = 0,
                   labels: pd.DataFrame | None = None) -> pd.DataFrame | None:
        """IMU の各サンプルに、iPad の時間軸の時刻 (task_unix_ms) と状態を付ける。

        imu を省くと、課題アプリが記録した AirPods の動き (task.headphone、センサの時刻の unix_ms 列) を使う。
        記録がなければ None。既存の IMU アプリの記録を使うときは load_imu_sqlite() の表を渡す
        (時刻は受信した時刻で、周期的な止まりがある。docs/data_spec.md 6章)。imu_offset_ms を足して iPad の時間軸にそろえる。
        """
        if imu is None:
            imu = self.task.headphone
            if imu is None:
                return None
        labels = self.labels() if labels is None else labels
        out = imu.copy()
        out["task_unix_ms"] = out["unix_ms"] + imu_offset_ms
        out["t_s"] = self._t_s(out["task_unix_ms"])
        lab = labels[["unix_ms", "segment", "state"]].sort_values("unix_ms")
        merged = pd.merge_asof(out[["task_unix_ms"]].reset_index().sort_values("task_unix_ms"), lab,
                               left_on="task_unix_ms", right_on="unix_ms", direction="nearest",
                               tolerance=self.params.grid_ms // 2 + 1).set_index("index").sort_index()
        out["segment"] = merged["segment"]
        out["state"] = merged["state"]
        return out

    # --- 時計のずれの確認 ---

    def estimate_game_offset(self, search_ms: int = 10_000, step_ms: int = 250, edge_ms: int = 1_500) -> pd.DataFrame:
        """ゲームアプリの時刻の補正値の候補ごとに、「iPhone を持っている間に、iPad で回答した数」を数える。

        両手で同時にはできないので、正しい補正値では 0 に近くなる。ただし iPhone を置き終わる前に計算に戻ることは
        ありうるので、持ち上げの始めと終わりの edge_ms は数えない (edge_ms より小さなずれは見分けられない)。
        ゲームのみ区間の開始から最初のタッチまでの遅れ (first_touch_delay_ms) も、確かめる材料として返す。
        """
        it = self.task.items[self.task.items["response"].notna()]
        answers = it["answered_unix_ms"].astype("int64").to_numpy()
        rows = []
        h = self.holding[self.holding["end_unix_ms"] - self.holding["start_unix_ms"] > 2 * edge_ms]
        for off in range(-search_ms, search_ms + 1, step_ms):
            shift = off - self.game_offset_ms
            n = int(_intervals_mask(answers, h["start_unix_ms"].to_numpy() + shift + edge_ms,
                                    h["end_unix_ms"].to_numpy() + shift - edge_ms).sum())
            rows.append((off, n))
        return pd.DataFrame(rows, columns=["game_offset_ms", "answers_while_holding"])

    def suggested_game_offset(self, search_ms: int = 10_000, step_ms: int = 250) -> int | None:
        """estimate_game_offset で最小になる補正値。いまの補正値で最小なら、いまの値をそのまま返す
        (自由区間でほとんど遊ばなかった人は材料が少なく、最小になる範囲が広いため、範囲の中から1つに決められない)。
        それ以外は、最小になる範囲 (最も広いもの) の中央。持ち上げが1回もなければ None。"""
        if self.holding.empty:
            return None
        est = self.estimate_game_offset(search_ms, step_ms)
        low = est["answers_while_holding"].min()
        best = est[est["answers_while_holding"] == low]["game_offset_ms"].to_numpy()
        if self.game_offset_ms in best:
            return self.game_offset_ms
        runs = np.split(best, np.where(np.diff(best) != step_ms)[0] + 1)
        run = max(runs, key=len)
        return int(round((run[0] + run[-1]) / 2 / step_ms) * step_ms)

    def first_touch_delay_ms(self) -> int | None:
        """ゲームのみ区間の開始 (iPad) から、その区間で最初にゲームを始めたタッチ (iPhone) までの時間。
        負なら、iPhone の時計が進んでいる (または補正値が足りない) 疑いがある。"""
        if self.game is None:
            return None
        seg = self.task.segments[self.task.segments["segment"] == "game_only"]
        if seg.empty:
            return None
        s0, s1 = int(seg["start_unix_ms"].min()), int(seg["end_unix_ms"].max())
        r = self.game.rounds
        starts = (r["start_unix_ms"] + self.game_offset_ms).to_numpy()
        near = starts[(starts > s0 - 60_000) & (starts < s1)]
        return int(near.min() - s0) if len(near) else None

    # --- 人ごとの指標 ---

    def summary(self, labels: pd.DataFrame | None = None) -> dict:
        """人ごとの指標 (設計書7章のスループット、作業率、サボり側の量、状態の割合)。"""
        labels = self.labels() if labels is None else labels
        p = self.params
        it = self.task.items
        free_items = it[(it["segment"] == "free") & it["response"].notna()]
        free_ms = int(self.task.planned_duration_ms("free"))
        n_correct = int(free_items["is_correct"].fillna(False).sum())
        raw = n_correct / (free_ms / 60_000)
        base_speed = 60_000 / self.baseline_ms if self.baseline_ms else None
        ai = self._answer_intervals("free")
        work = ai[ai["duration_ms"] < p.gap_ms]["duration_ms"].sum()
        free_lab = labels[labels["segment"] == "free"]
        frac = free_lab["state"].value_counts(normalize=True)
        out = {
            "participant_id": self.participant_id,
            "game_participant_id": self.game_participant_id,
            "baseline_interval_ms": self.baseline_ms,
            "free_n_answered": len(free_items),
            "free_n_correct": n_correct,
            "free_error_rate": 1 - n_correct / len(free_items) if len(free_items) else None,
            "raw_throughput_per_min": raw,
            "calibrated_throughput": raw / base_speed if base_speed else None,
            "work_rate": work / free_ms,
            **{f"free_frac_{s}": float(frac.get(s, 0.0)) for s in STATES},
            "game_offset_ms": self.game_offset_ms,
        }
        if self.game is not None:
            seg = self.task.segments[self.task.segments["segment"] == "free"]
            f0, f1 = int(seg["start_unix_ms"].min()), int(seg["end_unix_ms"].max())
            h = self.holding
            hold_ms = (h["end_unix_ms"].clip(f0, f1) - h["start_unix_ms"].clip(f0, f1)).clip(lower=0).sum()
            r = self.game.rounds
            rs = r["start_unix_ms"] + self.game_offset_ms
            in_free = r[(rs >= f0) & (rs < f1)]
            out.update({
                "free_holding_s": hold_ms / 1000,
                "free_game_parts": len(in_free),
                "free_game_rounds": in_free["round_index"].nunique(),
                "suggested_game_offset_ms": self.suggested_game_offset(),
                "first_touch_delay_ms": self.first_touch_delay_ms(),
            })
        return out


def _blur_transitions(raw: np.ndarray, margin: int) -> np.ndarray:
    """状態 (あいまい以外) が切り替わる所の前後 margin 刻みを、あいまいにする。"""
    state = raw.copy()
    if margin <= 0 or len(raw) < 2:
        return state
    change = np.where(raw[1:] != raw[:-1])[0] + 1
    for c in change:
        if raw[c] == "ambiguous" or raw[c - 1] == "ambiguous":
            continue
        state[max(0, c - margin):c + margin] = "ambiguous"
    return state


def build_timeline(pair: Pair, params: LabelParams | None = None, game_offset_ms: int = 0) -> Timeline:
    """1人分の時間軸を作る。game_offset_ms はゲームアプリの時刻に足す補正値 (iPhone の時計が進んでいたら負)。"""
    params = params or LabelParams()
    task = load_session(pair.task_folder)
    game = load_game_session(pair.game_folder) if pair.game_folder else None
    tl = Timeline(pair.participant_id, pair.game_participant_id, task, game, params, game_offset_ms,
                  issues=list(pair.issues))
    if game is not None:
        h = detect_holding(game.motion, params)
        tl.holding = h + game_offset_ms if not h.empty else h
    else:
        tl.holding = detect_holding(None, params)
    tl.baseline_ms, n = baseline_interval_ms(task, params)
    if tl.baseline_ms is None:
        tl.issues.append(Issue("WARN", "基準速度", "計算のみの区間の回答間隔がないので、計算中の判定に gap_ms を使います"))
    elif n < 30:
        tl.issues.append(Issue("WARN", "基準速度", f"基準速度を {n} 個の回答間隔から求めています (少ない)"))
    if game is not None:
        suggested = tl.suggested_game_offset()
        if suggested is not None and suggested != game_offset_ms:
            tl.issues.append(Issue("WARN", "時計のずれ", f"iPhone の時刻の補正値は {suggested} ms が合っていそうです "
                                   f"(いまは {game_offset_ms} ms)。持っている間に iPad で回答した数が最小になる値"))
    return tl


def label_params_dict(params: LabelParams) -> dict:
    return asdict(params)
