"""Independent rational checks for adaptive zap precision; run with unittest."""
import unittest
from fractions import Fraction

from fair_lp_value_golden import Q96, get_sqrt_ratio_at_tick, zap_swap_amount_to_token0


class ZapPrecisionTest(unittest.TestCase):
    def assert_continuous(self, lower, upper, tick, price0, price1, dec0, dec1):
        a, b, p = map(get_sqrt_ratio_at_tick, (lower, upper, tick))
        v0 = Fraction(Q96 * (b - p) * price0, p * b * 10**dec0)
        v1 = Fraction((p - a) * price1, Q96 * 10**dec1)
        expected = int(10**18 * v0 / (v0 + v1))
        actual = zap_swap_amount_to_token0(10**18, lower, upper, p, price0, price1, dec0, dec1)
        self.assertEqual(actual, expected)

    def test_nonzero_amount_rounding(self):
        self.assert_continuous(700000, 700120, 700050, 10**30, 1, 0, 0)

    def test_nonzero_value_rounding(self):
        self.assert_continuous(-60, 120, 0, 1, 1, 15, 15)

    def test_max_reference_insufficient(self):
        with self.assertRaises(ArithmeticError):
            zap_swap_amount_to_token0(10**18, -1, 2, Q96, 1, 1, 34, 34)


if __name__ == "__main__":
    unittest.main()
