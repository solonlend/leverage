// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairLpMath} from "../src/libraries/FairLpMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// Differential test: FairLpMath.sqrtPriceX96FromFeeds (the V4 oracle's fair-price source) MUST match
/// the Python golden bit-for-bit across controlled in-range vectors. Funds-critical (feeds → valuation).
contract FeedSqrtDiffTest is Test {
    function test_sqrtFromFeeds_vs_golden() public {
        string memory json = vm.readFile("test/vectors/feed_sqrt.json");
        uint256[] memory p0 = vm.parseJsonUintArray(json, ".fp0");
        uint256[] memory p1 = vm.parseJsonUintArray(json, ".fp1");
        uint256[] memory d0 = vm.parseJsonUintArray(json, ".fd0");
        uint256[] memory d1 = vm.parseJsonUintArray(json, ".fd1");
        uint256[] memory exp = vm.parseJsonUintArray(json, ".fexp");
        uint256 n = vm.parseJsonUint(json, ".n");
        assertGt(n, 0);
        for (uint256 i = 0; i < n; i++) {
            uint160 got = FairLpMath.sqrtPriceX96FromFeeds(p0[i], p1[i], uint8(d0[i]), uint8(d1[i]));
            assertEq(uint256(got), exp[i], string.concat("sqrtFromFeeds mismatch @", vm.toString(i)));
        }
    }

    function test_sqrtFromFeeds_nearMaxTick() public pure {
        uint256 price0 = 340250000000000000000000000000000000000;
        uint160 expected = 1461432128244523755890542281841634381669140154398;

        uint160 got = FairLpMath.sqrtPriceX96FromFeeds(price0, 1, 0, 0);

        assertEq(got, expected);
        assertGe(got, TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1));
        assertLt(got, TickMath.MAX_SQRT_RATIO);
    }

    function test_sqrtFromFeeds_nearMinTick() public pure {
        uint160 expected = 4295171574;

        uint160 got = FairLpMath.sqrtPriceX96FromFeeds(
            1, 340250000000000000000000000000000000000, 0, 0
        );

        assertEq(got, expected);
        assertGt(got, TickMath.MIN_SQRT_RATIO);
        assertLe(got, TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK + 1));
    }

    function test_sqrtFromFeeds_currentWethUsdg_bitExact() public pure {
        uint160 got = FairLpMath.sqrtPriceX96FromFeeds(4500e8, 1e8, 18, 6);

        assertEq(got, 5314786713428871308883051);
    }

    /// Executable floor-sqrt squeeze for equal token decimals:
    /// s^2 * p1 <= p0 * 2^192 < (s + 1)^2 * p1.
    function testFuzz_sqrtFromFeeds_isFloorSqrtOfFeedRatio(uint256 rp0, uint256 rp1) public pure {
        uint256 p0 = bound(rp0, 1e6, 1e12);
        uint256 p1 = bound(rp1, 1e6, 1e12);
        // Equal decimals cancel. These bounds keep every product below uint256 max.
        uint160 s = FairLpMath.sqrtPriceX96FromFeeds(p0, p1, 18, 18);
        uint256 root = uint256(s);
        uint256 scaledNumerator = p0 << 192;

        assertLe(root * root * p1, scaledNumerator, "lower floor-sqrt bound");
        assertLt(scaledNumerator, (root + 1) * (root + 1) * p1, "upper floor-sqrt bound");
    }
}
