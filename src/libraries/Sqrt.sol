// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Sqrt — integer square root (floor), matches Python math.isqrt bit-for-bit.
/// @notice Used to derive sqrtPriceX96 from a Chainlink-implied price ratio on Uniswap V4 pools
///         (which have no built-in observe()/TWAP). Babylonian method with a good initial guess.
library Sqrt {
    /// @notice floor(sqrt(x)). Deterministic and equal to Python's math.isqrt for all uint256 x.
    function isqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        // initial guess: 2^(ceil(bitlen/2))
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; r <<= 64; }
        if (xx >= 0x10000000000000000) { xx >>= 64; r <<= 32; }
        if (xx >= 0x100000000) { xx >>= 32; r <<= 16; }
        if (xx >= 0x10000) { xx >>= 16; r <<= 8; }
        if (xx >= 0x100) { xx >>= 8; r <<= 4; }
        if (xx >= 0x10) { xx >>= 4; r <<= 2; }
        if (xx >= 0x4) { r <<= 1; }
        // 7 Newton iterations converge for all uint256
        unchecked {
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            uint256 r1 = x / r;
            return r < r1 ? r : r1; // floor
        }
    }
}
