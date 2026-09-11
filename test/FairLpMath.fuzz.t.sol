// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairLpMath} from "../src/libraries/FairLpMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// Brute-force invariants for the fair-value math. 5000 runs/property (foundry.toml [fuzz]).
/// These encode the economic铁律 the KERNEL must never violate.
contract FairLpMathFuzzTest is Test {
    int24 constant SPACING = 60;

    // Bound a raw fuzz tick into an aligned, in-band tick.
    function _tick(int256 raw, int24 lo, int24 hi) internal pure returns (int24) {
        int256 span = int256(hi) - int256(lo);
        int256 t = lo + (raw % span);
        t = t - (t % SPACING);
        if (t < lo) t += SPACING;
        if (t >= hi) t -= SPACING;
        return int24(t);
    }

    /// 铁律 1:两边跨现价(straddling)时,两条腿都必须非零。单边=伪装方向杠杆,产品层已拒,
    ///         但数学层也必须保证 straddle 一定拆出两边,否则健康度会算错。
    function testFuzz_straddle_bothLegsNonZero(uint128 L, int256 rl, int256 rw) public pure {
        L = uint128(bound(L, 1e9, 1e30));
        int24 center = _tick(rl, -100000, 100000);
        int24 halfW = int24(int256(bound(rw, 2, 500))) * SPACING; // ≥2 spacings each side
        int24 lower = center - halfW;
        int24 upper = center + halfW;
        // fair price strictly inside → two-sided
        uint160 sqrtFair = TickMath.getSqrtRatioAtTick(center);

        (uint256 a0, uint256 a1) = FairLpMath.fairAmounts(L, lower, upper, sqrtFair);
        assertGt(a0, 0, "leg0 zero on straddle");
        assertGt(a1, 0, "leg1 zero on straddle");
    }

    /// 铁律 2:数量对流动性单调不减 —— 更多 L 不可能拆出更少的 token(防负杠杆/缩水漏洞)。
    function testFuzz_monotonic_in_liquidity(uint128 L1, uint128 add, int256 rl, int256 rw) public pure {
        L1 = uint128(bound(L1, 1e9, 1e28));
        add = uint128(bound(add, 1, 1e28));
        int24 center = _tick(rl, -80000, 80000);
        int24 halfW = int24(int256(bound(rw, 2, 500))) * SPACING;
        int24 lower = center - halfW;
        int24 upper = center + halfW;
        uint160 sqrtFair = TickMath.getSqrtRatioAtTick(center);

        (uint256 a0_1, uint256 a1_1) = FairLpMath.fairAmounts(L1, lower, upper, sqrtFair);
        (uint256 a0_2, uint256 a1_2) = FairLpMath.fairAmounts(L1 + add, lower, upper, sqrtFair);
        assertGe(a0_2, a0_1, "amount0 not monotonic in L");
        assertGe(a1_2, a1_1, "amount1 not monotonic in L");
    }

    /// 铁律 3:合理区间内绝不 revert(estimate 不能因边界 panic,否则清算会卡死)。
    function testFuzz_no_revert_reasonable(uint128 L, int256 rl, int256 rw, uint256 p0, uint256 p1) public pure {
        L = uint128(bound(L, 1, 1e30));
        int24 center = _tick(rl, -200000, 200000);
        int24 halfW = int24(int256(bound(rw, 1, 2000))) * SPACING;
        int24 lower = center - halfW;
        int24 upper = center + halfW;
        uint160 sqrtFair = TickMath.getSqrtRatioAtTick(center);
        p0 = bound(p0, 1, 1e14);
        p1 = bound(p1, 1, 1e14);

        (uint256 value,,) = FairLpMath.fairValue(L, lower, upper, sqrtFair, p0, p1, 8, 8);
        assertGe(value, 0); // 只要不 revert 即通过
    }
}
