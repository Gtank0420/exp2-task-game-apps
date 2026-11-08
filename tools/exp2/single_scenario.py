"""1台版の疑似データを作るための筋書き (人ごとの「ポップアップでどうしたか、いつぼんやりしたか」) を作る。

筋書きは JSON で、exp2-single-simulate --scenario-dir がこれを読み、1台版の本物の記録処理を動かして、
正解のファイル (truth/<ID>.csv) を書く (tools/make_single_sim.py がまとめて行う)。2台版の exp2/scenario.py と同じ考え方。

1台版では、ゲームはポップアップでしか出ない (設計書3章) ので、筋書きで決めるのは次の2つ:
- popup_plans: k 回目のポップアップで、何ミリ秒遊んでから閉じるか (play)、遊ばずに何ミリ秒で閉じるか (dismiss)
- idle_states: 自由区間で、計算の画面にいても答えない時間 (どちらでもない。区間の経過時間)
人ごとに、遊ぶ確率と1回に遊ぶ長さを変える (設計書8.2: Off の量は人と頻度の両方に左右される)。
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .merge_game import next_int, next_unit
from .scenario import BASE_UNIX_MS
from .sequence import SplitMix64


@dataclass
class SingleScenarioConfig:
    """筋書きの作り方の設定。人ごとのばらつきの範囲を決める。"""

    free_ms: int = 20 * 60_000
    short_free_ms: int = 60_000
    # ポップアップで遊ぶ確率の範囲 (人ごと)
    play_probability_range: tuple[float, float] = (0.2, 0.95)
    # 1回に遊ぶ長さの平均の範囲 (人ごと、ms)。1回ごとに平均の 0.4〜1.6 倍
    play_mean_ms_range: tuple[int, int] = (20_000, 120_000)
    # 開発用の短い区間 (ポップアップが 8〜15 秒ごと) では、遊ぶ長さを短くする
    short_play_ms_range: tuple[int, int] = (3_000, 8_000)
    # 遊ばないとき、出てから閉じるまで (ms)
    dismiss_ms_range: tuple[int, int] = (800, 2_500)
    # ぼんやりする間隔と長さ (ms)。区間の始めからこの間隔ごとに1回
    idle_every_ms_range: tuple[int, int] = (90_000, 300_000)
    idle_ms_range: tuple[int, int] = (6_000, 30_000)
    # 作業の速さと誤答率の範囲 (2台版と同じ)
    rt_median_ms_range: tuple[int, int] = (700, 1_300)
    error_rate_range: tuple[float, float] = (0.01, 0.05)
    # 用意するポップアップの計画の数 (20分で出るのは多くて十数回)
    n_plans: int = 60


@dataclass
class SingleScenario:
    participant_id: str
    seed: int
    handedness: str
    rt_median_ms: int
    error_rate: float
    short_durations: bool
    start_unix_ms: int
    ipad_mono_base_ms: int
    play_probability: float = 0.0
    play_mean_ms: int = 0
    idle_states: list[dict] = field(default_factory=list)
    popup_plans: list[dict] = field(default_factory=list)

    def write(self, folder: Path) -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{self.participant_id}.json"
        path.write_text(json.dumps(asdict(self), ensure_ascii=False, indent=2))
        return path


def _uniform(rng: SplitMix64, lo: float, hi: float) -> float:
    return lo + next_unit(rng) * (hi - lo)


def make_single_scenario(index: int, seed: int = 1, short: bool = False,
                         cfg: SingleScenarioConfig | None = None) -> SingleScenario:
    """index 番目 (0 始まり) の疑似参加者の筋書き。同じ seed と index なら同じ筋書きになる。"""
    cfg = cfg or SingleScenarioConfig()
    rng = SplitMix64((seed * 1_000_003 + index * 0x9E3779B9 + 0x51) & ((1 << 64) - 1))
    play_p = _uniform(rng, *cfg.play_probability_range)
    play_mean = next_int(rng, *cfg.play_mean_ms_range)
    plans = []
    for _ in range(cfg.n_plans):
        if next_unit(rng) < play_p:
            ms = next_int(rng, *cfg.short_play_ms_range) if short else int(play_mean * _uniform(rng, 0.4, 1.6))
            plans.append({"kind": "play", "ms": ms})
        else:
            plans.append({"kind": "dismiss", "ms": next_int(rng, *cfg.dismiss_ms_range)})
    free_ms = cfg.short_free_ms if short else cfg.free_ms
    idle = []
    if short:
        idle.append({"start_ms": int(free_ms * 0.5), "end_ms": int(free_ms * 0.5) + 8_000})
    else:
        t = next_int(rng, *cfg.idle_every_ms_range)
        while t < free_ms:
            length = next_int(rng, *cfg.idle_ms_range)
            idle.append({"start_ms": t, "end_ms": min(free_ms, t + length)})
            t += length + next_int(rng, *cfg.idle_every_ms_range)
    return SingleScenario(
        participant_id=f"DEV_SJOINT{index + 1:02d}",
        seed=rng.next() >> 11,
        handedness="left" if index % 10 == 9 else "right",
        rt_median_ms=next_int(rng, *cfg.rt_median_ms_range),
        error_rate=round(_uniform(rng, *cfg.error_rate_range), 4),
        short_durations=short,
        start_unix_ms=BASE_UNIX_MS + index * 3_600_000,
        ipad_mono_base_ms=50_000_000 + index * 1_000_000,
        play_probability=round(play_p, 4),
        play_mean_ms=play_mean,
        idle_states=idle,
        popup_plans=plans,
    )
