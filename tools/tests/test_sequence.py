"""出題系列の再現 (tools/exp2/sequence.py) のテスト。

    python3 -m unittest discover -s tools/tests
"""

import csv
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from exp2.sequence import GOLDEN_PATH, SplitMix64, generate  # noqa: E402


class SplitMix64Test(unittest.TestCase):
    def test_reference_values_seed0(self):
        # Vigna の参照実装 (splitmix64.c) で種0のときの最初の3つの値
        rng = SplitMix64(0)
        self.assertEqual(
            [rng.next() for _ in range(3)],
            [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F],
        )


class GenerateTest(unittest.TestCase):
    def test_range_and_no_consecutive_duplicates(self):
        problems = generate(20261104, 5000)
        self.assertEqual(len(problems), 5000)
        for a, b in problems:
            self.assertTrue(2 <= a <= 9 and 2 <= b <= 9)
        for prev, cur in zip(problems, problems[1:]):
            self.assertNotEqual(prev, cur)

    def test_deterministic(self):
        self.assertEqual(generate(42, 100), generate(42, 100))
        self.assertNotEqual(generate(42, 100), generate(43, 100))

    def test_golden_file_is_up_to_date(self):
        with GOLDEN_PATH.open() as f:
            rows = list(csv.DictReader(f))
        by_seed: dict[int, list[tuple[int, int]]] = {}
        for r in rows:
            by_seed.setdefault(int(r["seed"]), []).append((int(r["a"]), int(r["b"])))
        for seed, problems in by_seed.items():
            self.assertEqual(problems, generate(seed, len(problems)))


if __name__ == "__main__":
    unittest.main()
