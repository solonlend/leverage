// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FullMath} from "./FullMath.sol";

/// @title LiquidityAmounts — token amounts for a given liquidity & range (Uniswap periphery, GPL-2.0).
/// @notice Mirrors reference/fair_lp_value_golden.py::get_amounts_for_liquidity bit-for-bit:
///         amount0 = mulDiv(L<<96, sqrtB-sqrtA, sqrtB) / sqrtA   (double-floor)
///         amount1 = mulDiv(L, sqrtB-sqrtA, Q96)
///         The double-floor via FullMath is exactly Python's `... // sqrtB // sqrtA`.
library LiquidityAmounts {
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96
    uint8 internal constant RESOLUTION = 96;

    function getAmount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal pure returns (uint256 amount0)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(uint256(liquidity) << RESOLUTION, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    function getAmount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal pure returns (uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(liquidity, sqrtB - sqrtA, Q96);
    }

    /// @notice Inverse: max liquidity obtainable from (amount0, amount1) at price sqrtP over [A,B].
    ///         Needed for V4 mint/increase, which take a target `liquidity` (not desired amounts).
    function getLiquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0)
        internal pure returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        return _toU128(FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    function getLiquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1)
        internal pure returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _toU128(FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA));
    }

    function getLiquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal pure returns (uint128 liquidity)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            liquidity = getLiquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint128 l0 = getLiquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 l1 = getLiquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }

    /// @notice Split liquidity into (amount0, amount1) at price sqrtP. Straddling range → both non-zero.
    function getAmountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal pure returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            amount0 = getAmount0ForLiquidity(sqrtA, sqrtB, liquidity);
        } else if (sqrtP < sqrtB) {
            amount0 = getAmount0ForLiquidity(sqrtP, sqrtB, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtA, sqrtP, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtA, sqrtB, liquidity);
        }
    }

    /// 审计 L1:恢复上游的 safe cast(静默截断在其他币对/宽度下会咬人)。SAFE_CAST
    function _toU128(uint256 x) private pure returns (uint128) {
        require(x <= type(uint128).max, "LIQ_OVERFLOW");
        return uint128(x);
    }
}
