"""ゲームアプリの 2048 型を、アプリと同じ手順で再現する。

アプリ (Packages/ExperimentCore/Sources/GameCore/MergeGame.swift) とビット単位で同じ盤と得点を作る。
検証スクリプトで「記録したスワイプの順から、記録した得点が再現できるか」を確かめるために使う。
回の種は game_rounds.csv の round_seed、盤の大きさと 4 の出る確率は game_meta.json の config_snapshot.merge。

単独で実行すると、Swift の単体テストが読む基準ファイル (tools/fixtures/merge_golden.csv) を書き出す:

    python3 tools/exp2/merge_game.py
"""

from __future__ import annotations

import csv
from pathlib import Path

try:
    from .sequence import SplitMix64
except ImportError:  # 単独で実行したとき
    from sequence import SplitMix64  # type: ignore[no-redef]

DIRECTIONS = ("left", "right", "up", "down")


def next_unit(rng: SplitMix64) -> float:
    """[0, 1) の一様乱数 (Swift の nextUnit と同じ: 上位53ビット × 2^-53)。"""
    return (rng.next() >> 11) * 2.0 ** -53


def next_int(rng: SplitMix64, lo: int, hi: int) -> int:
    """lo〜hi の整数 (Swift の nextInt(in:) と同じ: lo + floor(nextUnit × 個数))。"""
    return lo + int(next_unit(rng) * (hi - lo + 1))


class MergeGame:
    def __init__(self, seed: int, size: int = 4, initial_tiles: int = 2, four_probability: float = 0.25) -> None:
        self.size = size
        self.four_probability = four_probability
        self.board = [0] * (size * size)
        self.score = 0
        self.moves = 0
        self.rng = SplitMix64(seed)
        for _ in range(initial_tiles):
            self._spawn()

    def _spawn(self) -> None:
        # 空いたマス (番号の小さい順) から1つ選び、2 か 4 を置く。乱数は「場所 → 値」の順に2回引く
        empties = [i for i, v in enumerate(self.board) if v == 0]
        if not empties:
            return
        index = empties[next_int(self.rng, 0, len(empties) - 1)]
        self.board[index] = 4 if next_unit(self.rng) < self.four_probability else 2

    def move(self, direction: str) -> tuple[bool, int]:
        """スワイプを1回適用する。盤が変わらなければ何も起きない (新しい数も出ない)。"""
        n = self.size
        gained = 0
        new = list(self.board)
        for line in range(n):
            if direction == "left":
                idx = [line * n + k for k in range(n)]
            elif direction == "right":
                idx = [line * n + (n - 1 - k) for k in range(n)]
            elif direction == "up":
                idx = [k * n + line for k in range(n)]
            elif direction == "down":
                idx = [(n - 1 - k) * n + line for k in range(n)]
            else:
                raise ValueError(direction)
            values = [self.board[i] for i in idx if self.board[i] != 0]
            merged: list[int] = []
            i = 0
            while i < len(values):
                if i + 1 < len(values) and values[i] == values[i + 1]:
                    merged.append(values[i] * 2)
                    gained += values[i] * 2
                    i += 2
                else:
                    merged.append(values[i])
                    i += 1
            merged += [0] * (n - len(merged))
            for k, j in enumerate(idx):
                new[j] = merged[k]
        if new == self.board:
            return False, 0
        self.board = new
        self.score += gained
        self.moves += 1
        self._spawn()
        return True, gained

    @property
    def is_over(self) -> bool:
        n = self.size
        if 0 in self.board:
            return False
        for r in range(n):
            for c in range(n):
                v = self.board[r * n + c]
                if c + 1 < n and self.board[r * n + c + 1] == v:
                    return False
                if r + 1 < n and self.board[(r + 1) * n + c] == v:
                    return False
        return True


GOLDEN = Path(__file__).resolve().parents[1] / "fixtures" / "merge_golden.csv"


def write_golden(path: Path = GOLDEN) -> None:
    """いくつかの種で、決まった順のスワイプを当てたときの盤と得点を書き出す (Swift のテストと突き合わせる)。"""
    rows = []
    for seed in (1, 20261201, 2**53 - 1):
        g = MergeGame(seed)
        rows.append({"seed": seed, "step": 0, "direction": "", "moved": 1,
                     "score": g.score, "board": " ".join(map(str, g.board))})
        order = SplitMix64(seed ^ 0x5DEECE66D)
        for step in range(1, 301):
            d = DIRECTIONS[order.next() % 4]
            moved, _ = g.move(d)
            rows.append({"seed": seed, "step": step, "direction": d, "moved": int(moved),
                         "score": g.score, "board": " ".join(map(str, g.board))})
            if g.is_over:
                break
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["seed", "step", "direction", "moved", "score", "board"], lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"書き出しました: {path} ({len(rows)} 行)")


if __name__ == "__main__":
    write_golden()
