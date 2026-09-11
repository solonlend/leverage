// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title V4Periphery — Uniswap V4 types, PositionManager interface, and action-encoding helpers.
/// @notice Source-verified against Uniswap/v4-periphery @1.0.x (audited commit df47aa9) and v4-core.
///         Deployed Action byte values 0x00–0x18 are stable. We integrate at the periphery
///         PositionManager (the ERC-721 wrapper) — never the low-level PoolManager unlock/callback.
///         All liquidity ops funnel through `modifyLiquidities(bytes unlockData, uint256 deadline)`,
///         unlockData = abi.encode(bytes actions, bytes[] params).

type Currency is address;

interface IHooks {}

struct PoolKey {
    Currency currency0; // sorted currency0 < currency1; native ETH = Currency.wrap(address(0))
    Currency currency1;
    uint24 fee;         // hundredths of a bip; 0x800000 flag = dynamic fee
    int24 tickSpacing;
    IHooks hooks;       // IHooks(address(0)) = no hook
}

/// v4-periphery PositionManager surface we use (mint/increase/decrease/collect/burn + reads).
interface IV4PositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    /// returns the PoolKey and the packed PositionInfo (decode ticks via PositionInfoLib).
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);
}

/// Deployed Actions enum values (v4-periphery Actions.sol). Packed one byte each via abi.encodePacked.
library V4Actions {
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION      = 0x02;
    uint8 internal constant BURN_POSITION      = 0x03;
    uint8 internal constant SETTLE_PAIR        = 0x0d;
    uint8 internal constant TAKE_PAIR          = 0x11;
}

/// Decode ticks from the packed PositionInfo (v4-periphery PositionInfoLibrary layout):
/// [ 200 bits poolId | 24 bits tickUpper | 24 bits tickLower | 8 bits flags ].
library PositionInfoLib {
    function tickLower(uint256 info) internal pure returns (int24) {
        return int24(int256(info >> 8));
    }
    function tickUpper(uint256 info) internal pure returns (int24) {
        return int24(int256(info >> 32));
    }
}

/// Builds the `unlockData` payloads for each liquidity op. Keeps the byte-encoding in one audited place.
library V4Encode {
    /// MINT_POSITION + SETTLE_PAIR (vault pays both currencies). Read PM.nextTokenId() BEFORE calling.
    function mint(
        PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity,
        uint128 amount0Max, uint128 amount1Max, address owner
    ) external pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(V4Actions.MINT_POSITION, V4Actions.SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        return abi.encode(actions, params);
    }

    /// INCREASE_LIQUIDITY + SETTLE_PAIR (vault pays owed tokens).
    function increase(
        PoolKey memory key, uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max
    ) external pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(V4Actions.INCREASE_LIQUIDITY, V4Actions.SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        return abi.encode(actions, params);
    }

    /// DECREASE_LIQUIDITY + TAKE_PAIR (vault receives withdrawn tokens). liquidity=0 → collect fees only.
    function decrease(
        PoolKey memory key, uint256 tokenId, uint256 liquidity,
        uint128 amount0Min, uint128 amount1Min, address recipient
    ) external pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(V4Actions.DECREASE_LIQUIDITY, V4Actions.TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        return abi.encode(actions, params);
    }

    /// BURN_POSITION + TAKE_PAIR (burns NFT, withdraws all remaining liquidity + fees).
    function burn(
        PoolKey memory key, uint256 tokenId, uint128 amount0Min, uint128 amount1Min, address recipient
    ) external pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(V4Actions.BURN_POSITION, V4Actions.TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        return abi.encode(actions, params);
    }
}
