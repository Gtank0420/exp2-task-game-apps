"""連続加算の出題系列を、アプリと同じ手順で再現する。

アプリ (Packages/ExperimentCore/Sources/ExperimentCore/ProblemGenerator.swift) と
ビット単位で同じ系列を作る。検証スクリプトで「記録された (a, b) が種から再現できるか」を
確かめるために使う。種と数字の範囲は meta.json の config_snapshot から読む。

単独で実行すると、Swift の単体テストが読む基準ファイル
(tools/fixtures/sequence_golden.csv) を書き出す:

    python3 tools/exp2/sequence.py
"""

from __future__ import annotations

import csv
from pathlib import Path

_MASK64 = (1 << 64) - 1


class SplitMix64:
    """SplitMix64 (Swift 版 SplitMix64.swift と同じ定数・同じ順序)。"""

    def __init__(self, seed: int) -> None:
        self.state = seed & _MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & _MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _MASK64
        return z ^ (z >> 31)


def generate(seed: int, count: int, digit_min: int = 2, digit_max: int = 9) -> list[tuple[int, int]]:
    """出題系列 [(a, b), ...] を作る。

    手順は Swift 版と同じ:
    1. a, b の順に min + (next() % 幅) を引く
    2. 直前と同じ (a, b) なら a と b を引き直す (直前と同じ問題を出さない)
    """
    span = digit_max - digit_min + 1
    if span < 2:
        raise ValueError("数字の範囲は2つ以上必要")
    rng = SplitMix64(seed)
    problems: list[tuple[int, int]] = []
    while len(problems) < count:
        a = digit_min + rng.next() % span
        b = digit_min + rng.next() % span
        if problems and problems[-1] == (a, b):
            continue
        problems.append((a, b))
    return problems


# Swift のテストと共有する基準。種は本番の種とは無関係なテスト用の値。
GOLDEN_SEEDS = (1, 12345, 2**53 - 1)
GOLDEN_COUNT = 300
GOLDEN_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "sequence_golden.csv"


def write_golden(path: Path = GOLDEN_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["seed", "item_index", "a", "b", "correct_answer"])
        for seed in GOLDEN_SEEDS:
            for i, (a, b) in enumerate(generate(seed, GOLDEN_COUNT)):
                writer.writerow([seed, i, a, b, (a + b) % 10])


if __name__ == "__main__":
    write_golden()
    print(f"wrote {GOLDEN_PATH}")
