// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {TickMath} from "./TickMath.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";
import {FullMath} from "./FullMath.sol";
import {Sqrt} from "./Sqrt.sol";

/// @title FairLpMath — anti-manipulation fair valuation of a two-sided concentrated LP position.
/// @notice Bit-exact Solidity twin of reference/fair_lp_value_golden.py. The caller MUST pass a
///         manipulation-resistant sqrtPriceFair (TWAP-derived, feed-cross-checked) — NEVER spot.
///         This library only does the deterministic math; sourcing the fair price is the oracle's job.
library FairLpMath {
    error ZapRatioPrecisionInsufficient();

    /// @notice Fair token0/token1 amounts for liquidity L over [tickLower,tickUpper] at sqrtPriceFair.
    function fairAmounts(uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtPriceFair)
        internal pure returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceFair, sqrtA, sqrtB, liquidity);
    }

    /// @notice Position value in feed units: a0*price0/10^dec0 + a1*price1/10^dec1 (multiply-before-divide).
    /// @dev    price0/price1 are Chainlink answers (feedDec decimals); result carries the same feedDec.
    function fairValue(
        uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtPriceFair,
        uint256 price0, uint256 price1, uint8 dec0, uint8 dec1
    ) internal pure returns (uint256 value, uint256 amount0, uint256 amount1) {
        (amount0, amount1) = fairAmounts(liquidity, tickLower, tickUpper, sqrtPriceFair);
        uint256 v0 = (amount0 * price0) / (10 ** dec0);
        uint256 v1 = (amount1 * price1) / (10 ** dec1);
        value = v0 + v1;
    }

    /// @notice Position value in loan-token (USDG) units. value_usd * 10^loanDec / priceLoan.
    /// @dev    All three prices share the same feed decimals (they cancel). Bit-exact twin of
    ///         golden fair_value_in_loan. FullMath guards the value_usd * 10^loanDec overflow.
    function fairValueInLoan(
        uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtPriceFair,
        uint256 price0, uint256 price1, uint256 priceLoan, uint8 dec0, uint8 dec1, uint8 loanDec
    ) internal pure returns (uint256 valueInLoan, uint256 amount0, uint256 amount1) {
        uint256 valueUsd;
        (valueUsd, amount0, amount1) = fairValue(liquidity, tickLower, tickUpper, sqrtPriceFair, price0, price1, dec0, dec1);
        valueInLoan = FullMath.mulDiv(valueUsd, 10 ** loanDec, priceLoan);
    }

    /// @notice Derive a manipulation-resistant sqrtPriceX96 from two Chainlink feeds (for V4 pools,
    ///         which have no built-in observe()/TWAP). Uniswap price convention: price = token1/token0
    ///         in RAW units. price_raw = (price0/price1) * 10^(dec1-dec0). sqrtPriceX96 = sqrt(price_raw)·2^96.
    ///         Fully external (Chainlink) → cannot be flash-manipulated. Bit-exact twin of golden.
    function sqrtPriceX96FromFeeds(uint256 price0, uint256 price1, uint8 dec0, uint8 dec1)
        internal pure returns (uint160)
    {
        uint256 num = price0 * (10 ** dec1);
        uint256 den = price1 * (10 ** dec0);
        uint256 s;
        // Preserve the original bit-exact path whenever price_raw * 2^192 fits uint256.
        if (den > (num >> 64)) {
            uint256 ratioX192 = FullMath.mulDiv(num, 1 << 192, den);
            s = Sqrt.isqrt(ratioX192);
        } else {
            // For the upper half of TickMath's domain, the Q192 ratio needs up to 320 bits.
            // Its Q128 projection fits uint256 for every valid TickMath price and locates the
            // root within one 2^32-wide bucket. Recover the missing 32 bits exactly by comparing
            // each candidate square against the rational value without materializing the Q192 ratio.
            uint256 ratioX128 = FullMath.mulDiv(num, 1 << 128, den);
            uint256 remainder = mulmod(num, 1 << 128, den);
            uint256 rootX64 = Sqrt.isqrt(ratioX128);
            uint256 low = rootX64 << 32;
            uint256 high = (rootX64 + 1) << 32;
            while (high - low > 1) {
                uint256 mid = (low + high) >> 1;
                if (_squareLteRatioX192(mid, ratioX128, remainder, den)) low = mid;
                else high = mid;
            }
            s = low;
        }
        require(s >= TickMath.MIN_SQRT_RATIO && s < TickMath.MAX_SQRT_RATIO, "SQRT_RANGE"); // fail-closed
        return uint160(s);
    }

    /// @dev candidate^2 <= (num * 2^192) / den, expressed through
    ///      num * 2^128 = ratioX128 * den + remainder. candidate is below 2^160.
    function _squareLteRatioX192(
        uint256 candidate, uint256 ratioX128, uint256 remainder, uint256 den
    ) private pure returns (bool) {
        uint256 square0;
        uint256 square1;
        assembly {
            let mm := mulmod(candidate, candidate, not(0))
            square0 := mul(candidate, candidate)
            square1 := sub(sub(mm, square0), lt(mm, square0))
        }

        uint256 squareHigh = (square1 << 192) | (square0 >> 64);
        if (squareHigh != ratioX128) return squareHigh < ratioX128;

        // The integer parts are equal. Compare the remaining 64-bit fraction:
        // (square0 mod 2^64) * den <= remainder * 2^64, both as 512-bit values.
        uint256 fraction = square0 & type(uint64).max;
        uint256 left0;
        uint256 left1;
        assembly {
            let mm := mulmod(fraction, den, not(0))
            left0 := mul(fraction, den)
            left1 := sub(sub(mm, left0), lt(mm, left0))
        }
        uint256 right0 = remainder << 64;
        uint256 right1 = remainder >> 192;
        return left1 < right1 || (left1 == right1 && left0 <= right0);
    }

    uint128 internal constant ZAP_L_REF = 1e18;
    uint128 internal constant ZAP_L_MAX_REF = type(uint128).max;

    /// @notice Open-time zap split: how much of `totalLoan` (all USDG=token1) to swap into token0
    ///         so the resulting two-sided position at sqrtPriceFair over [tickLower,tickUpper] is balanced.
    ///         The rest stays as token1/USDG. Bit-exact twin of golden zap_swap_amount_to_token0.
    function zapSwapAmountToToken0(
        uint256 totalLoan, int24 tickLower, int24 tickUpper, uint160 sqrtPriceFair,
        uint256 price0, uint256 price1, uint8 dec0, uint8 dec1
    ) internal pure returns (uint256 amountToToken0) {
        (uint256 a0, uint256 a1) = fairAmounts(ZAP_L_REF, tickLower, tickUpper, sqrtPriceFair);
        uint256 v0 = (a0 * price0) / (10 ** dec0);
        uint256 v1 = (a1 * price1) / (10 ** dec1);

        // Preserve the historical path only when its rounding error is certified small.
        // Nonzero legs can still be severely rounded; zero checks alone are insufficient.
        if (!_zapValuePrecise(v0, price0, dec0) || !_zapValuePrecise(v1, price1, dec1)) {
            uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
            if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
            if (sqrtPriceFair > sqrtA && sqrtPriceFair < sqrtB) {
                (a0, a1) = fairAmounts(ZAP_L_MAX_REF, tickLower, tickUpper, sqrtPriceFair);
                v0 = (a0 * price0) / (10 ** dec0);
                v1 = (a1 * price1) / (10 ** dec1);
                if (!_zapValuePrecise(v0, price0, dec0) || !_zapValuePrecise(v1, price1, dec1)) {
                    revert ZapRatioPrecisionInsufficient();
                }
            }
        }
        uint256 denom = v0 + v1;
        if (denom == 0) revert ZapRatioPrecisionInsufficient();
        amountToToken0 = FullMath.mulDiv(totalLoan, v0, denom);
    }

    /// @dev Continuous amount A satisfies a <= A < a+1 (including amount0's double floor).
    /// Thus continuous value V satisfies v <= V < v + price/scale + 1. Certifying
    /// (ceil(price/scale)+1)/v <= 1/10000 bounds each leg's relative rounding error
    /// by 1 bp, and therefore also bounds BOTH normalized shares relative to their
    /// continuous solutions by 1 bp. This conservative certificate may escalate
    /// earlier than an exact ratio comparison, but cannot miss material distortion.
    /// Division avoids overflow in the error-bound comparison.
    function _zapValuePrecise(uint256 value, uint256 price, uint8 decimals) private pure returns (bool) {
        uint256 scale = 10 ** decimals;
        uint256 ceilUnitValue = price / scale + (price % scale == 0 ? 0 : 1);
        return value / 10000 > ceilUnitValue;
    }
}
