// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Split creation-bytecode holders (2026-09-09): embedding both vault and strategy creation code in
// RangeFactory pushed its runtime to ~34.6KB — deployable on Robinhood Chain (96KB limit) but
// rejected by the standard EIP-170 24KB limit (caught live on Sepolia). Same pattern as Uniswap's
// pool deployer: each deployer holds one creation code and hands ownership to its caller (the
// factory), keeping every artifact under the standard limit on any chain.

import {SolonRangeVault} from "./SolonRangeVault.sol";
import {RangeStrategyUniV3} from "./RangeStrategyUniV3.sol";

contract RangeVaultDeployer {
    function deploy(string calldata _name, string calldata _symbol) external returns (address vault) {
        SolonRangeVault v = new SolonRangeVault(_name, _symbol);
        v.transferOwnership(msg.sender);
        return address(v);
    }
}

contract RangeStrategyDeployer {
    function deploy(address _pool, int24 _positionWidth, address _vault, address _factory)
        external returns (address strategy)
    {
        RangeStrategyUniV3 s = new RangeStrategyUniV3(_pool, _positionWidth, _vault, _factory);
        s.transferOwnership(msg.sender);
        return address(s);
    }
}
