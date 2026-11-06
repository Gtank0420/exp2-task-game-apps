"""2つのアプリの疑似データを作るための筋書き (人ごとの「いつ何をしていたか」) を作る。

筋書きは JSON で、exp2-simulate --app joint がこれを読み、課題アプリとゲームアプリの本物の記録処理を
同じ時間の流れで動かす (tools/make_joint_sim.py がまとめて行う)。筋書きは正解として残るので、
ラベル作成のコード (timeline.py) が状態を正しく復元できるかを確かめられる。

自由区間の状態は設計書7章の3つ:
- compute: 計算している (課題アプリに回答し続ける)
- game: ゲーム用の iPhone を持ち上げて遊ぶ
- idle: どちらもしていない (ぼんやりする、周りを見るなど。回答が止まり、iPhone も置いたまま)
計算のみの区間は計算、ゲームのみ区間はゲームで固定 (exp2-simulate 側で決める)。
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .merge_game import next_int, next_unit
from .sequence import SplitMix64

# 疑似データの記録の時刻の起点 (2026-11-16 10:00 日本時間)。1人ずつ1時間ずらす
BASE_UNIX_MS = 1_794_790_800_000


@dataclass
class ScenarioConfig:
    """筋書きの作り方の設定。人ごとのばらつきの範囲を決める。"""

    # 自由区間の長さ (本番 20分、--short のときは開発用の 60秒)
    free_ms: int = 20 * 60_000
    short_free_ms: int = 60_000
    # 自由区間の最初は計算から始める (設計書6章の順番の理由: 作業から始まり、飽きてゲームに手が伸びる)
    first_compute_min_ms: int = 30_000
    # 自由区間のうちサボる (game + idle) 時間の割合の範囲。人ごとにこの範囲から決める
    offtask_fraction_range: tuple[float, float] = (0.05, 0.6)
    # サボるとき、ゲームをする確率 (残りはぼんやり)
    game_probability: float = 0.7
    # 1回の長さの範囲 (ms)
    game_bout_ms_range: tuple[int, int] = (40_000, 180_000)
    idle_bout_ms_range: tuple[int, int] = (6_000, 40_000)
    min_compute_bout_ms: int = 20_000
    # 作業の速さと誤答率の範囲 (課題アプリの SimulatedPopulationConfig と同じ)
    rt_median_ms_range: tuple[int, int] = (700, 1_300)
    error_rate_range: tuple[float, float] = (0.01, 0.05)
    # ゲームアプリの記録を始めてから課題アプリを始めるまで (参加者を迎えて装着するまで。設計書6章 手順0〜2)、
    # 課題アプリが終わってからゲームアプリの記録を終えるまで。
    # 2026-11-04 から説明は課題アプリの記録開始のあとに画面で行う (app_decisions #61) ので、実際の pre は数分になるが、
    # 疑似データの値は変えていない (区間の外の時間なので、分析の対象には影響しない)
    pre_task_ms: int = 7 * 60_000
    post_task_ms: int = 60_000


@dataclass
class Scenario:
    participant_id: str
    game_participant_id: str
    seed: int
    handedness: str
    rt_median_ms: int
    error_rate: float
    short_durations: bool
    pre_task_ms: int
    post_task_ms: int
    iphone_unix_offset_ms: int
    ipad_mono_base_ms: int
    iphone_mono_base_ms: int
    start_unix_ms: int
    # AirPods の IMU の時計のずれ (Unix 時刻)。Python で IMU を合成するときだけ使う
    imu_unix_offset_ms: int = 0
    offtask_fraction: float = 0.0
    free_states: list[dict] = field(default_factory=list)

    def write(self, folder: Path) -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{self.participant_id}.json"
        path.write_text(json.dumps(asdict(self), ensure_ascii=False, indent=2))
        return path


def _uniform(rng: SplitMix64, lo: float, hi: float) -> float:
    return lo + next_unit(rng) * (hi - lo)


def make_free_states(rng: SplitMix64, free_ms: int, offtask_fraction: float, cfg: ScenarioConfig) -> list[dict]:
    """自由区間を compute / game / idle の区間に分ける (0 から free_ms まで抜けなく)。"""
    mean_game = sum(cfg.game_bout_ms_range) / 2
    mean_idle = sum(cfg.idle_bout_ms_range) / 2
    mean_off = cfg.game_probability * mean_game + (1 - cfg.game_probability) * mean_idle
    # 計算の区間の平均の長さを、サボりの割合が目標に近づくように決める
    mean_compute = max(cfg.min_compute_bout_ms, mean_off * (1 - offtask_fraction) / max(offtask_fraction, 0.01))
    states = []
    t = 0
    first = True
    while t < free_ms:
        lo = cfg.first_compute_min_ms if first else cfg.min_compute_bout_ms
        compute = int(max(lo, _uniform(rng, 0.4, 1.6) * mean_compute))
        states.append({"state": "compute", "start_ms": t, "end_ms": min(free_ms, t + compute)})
        t += compute
        first = False
        if t >= free_ms:
            break
        if next_unit(rng) < cfg.game_probability:
            state, (lo, hi) = "game", cfg.game_bout_ms_range
        else:
            state, (lo, hi) = "idle", cfg.idle_bout_ms_range
        length = next_int(rng, lo, hi)
        states.append({"state": state, "start_ms": t, "end_ms": min(free_ms, t + length)})
        t += length
    return states


def make_short_free_states(free_ms: int) -> list[dict]:
    """開発用の短い自由区間 (60秒) では、3つの状態を決まった順に入れる。"""
    cut = [0, int(free_ms * 0.35), int(free_ms * 0.65), int(free_ms * 0.8), free_ms]
    names = ["compute", "game", "idle", "compute"]
    return [{"state": n, "start_ms": a, "end_ms": b} for n, a, b in zip(names, cut[:-1], cut[1:])]


def make_scenario(index: int, seed: int = 1, short: bool = False, cfg: ScenarioConfig | None = None,
                  iphone_unix_offset_ms: int = 0, imu_unix_offset_ms: int = 0,
                  game_participant_id: str | None = None) -> Scenario:
    """index 番目 (0 始まり) の疑似参加者の筋書き。同じ seed と index なら同じ筋書きになる。"""
    cfg = cfg or ScenarioConfig()
    rng = SplitMix64((seed * 1_000_003 + index * 0x9E3779B9) & ((1 << 64) - 1))
    pid = f"DEV_JOINT{index + 1:02d}"
    offtask = _uniform(rng, *cfg.offtask_fraction_range)
    free_ms = cfg.short_free_ms if short else cfg.free_ms
    states = make_short_free_states(free_ms) if short else make_free_states(rng, free_ms, offtask, cfg)
    return Scenario(
        participant_id=pid,
        game_participant_id=game_participant_id or pid,
        seed=rng.next() >> 11,
        handedness="left" if index % 10 == 9 else "right",
        rt_median_ms=next_int(rng, *cfg.rt_median_ms_range),
        error_rate=round(_uniform(rng, *cfg.error_rate_range), 4),
        short_durations=short,
        pre_task_ms=cfg.pre_task_ms if not short else 20_000,
        post_task_ms=cfg.post_task_ms if not short else 10_000,
        iphone_unix_offset_ms=iphone_unix_offset_ms,
        ipad_mono_base_ms=50_000_000 + index * 1_000_000,
        iphone_mono_base_ms=80_000_000 + index * 1_000_000,
        start_unix_ms=BASE_UNIX_MS + index * 3_600_000,
        imu_unix_offset_ms=imu_unix_offset_ms,
        offtask_fraction=round(offtask, 4),
        free_states=states,
    )


def load_scenario(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))
