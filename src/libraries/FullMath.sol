// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FullMath — 512-bit multiply-then-divide (Uniswap v3-core, MIT).
/// @notice Computes floor(a*b/denominator) with full precision; the intermediate
///         a*b is held in 512 bits so it never overflows. This is the primitive that
///         makes our LP math bit-exact against the Python golden (which uses big ints).
library FullMath {
    /// @notice floor(a·b / denominator), reverts on denominator==0 or overflow of the result.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0; // least significant 256 bits
            uint256 prod1; // most significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow case, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2^256 (also ensures denominator != 0)
            require(denominator > prod1);

            // 512 by 256 division
            // Subtract remainder from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256 via Newton-Raphson
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // 8 bits
            inv *= 2 - denominator * inv; // 16 bits
            inv *= 2 - denominator * inv; // 32 bits
            inv *= 2 - denominator * inv; // 64 bits
            inv *= 2 - denominator * inv; // 128 bits
            inv *= 2 - denominator * inv; // 256 bits

            result = prod0 * inv;
            return result;
        }
    }

    /// @notice mulDiv rounding the result up.
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = mulDiv(a, b, denominator);
            if (mulmod(a, b, denominator) > 0) {
                require(result < type(uint256).max);
                result++;
            }
        }
    }
}
