// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Fork of Beefy's StratFeeManagerInitializable (beefyfinance/beefy-zk, MIT), de-proxied and
// de-swapped: non-upgradeable OZ bases, constructor wiring, fees held on the factory as two
// plain numbers (no external FeeConfigurator), no unirouter/strategist/native. Locked-profit
// streaming and pause semantics are verbatim upstream.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IRangeFactory} from "./interfaces/IRangeFactory.sol";

contract RangeStratManager is Ownable, Pausable {
    /// @notice The address of the vault
    address public vault;

    /// @notice The factory: central ops registry (keeper, treasury, fees, rebalancers, global pause)
    IRangeFactory public factory;

    /// @notice The total amount of token0 locked in the vault
    uint256 public totalLocked0;

    /// @notice The total amount of token1 locked in the vault
    uint256 public totalLocked1;

    /// @notice The last time the strat harvested
    uint256 public lastHarvest;

    /// @notice The last time we adjusted the position
    uint256 public lastPositionAdjustment;

    /// @notice The duration of the locked rewards
    uint256 constant DURATION = 1 hours;

    /// @notice The divisor used to calculate the fee
    uint256 constant DIVISOR = 1 ether;

    // Errors
    error NotManager();
    error StrategyPaused();

    constructor(address _vault, address _factory) {
        vault = _vault;
        factory = IRangeFactory(_factory);
    }

    /**
     * @notice function that throws if the strategy is paused
     */
    function _whenStrategyNotPaused() internal view {
        if (paused() || factory.globalPause()) revert StrategyPaused();
    }

    /**
     * @notice function that returns true if the strategy is paused
     */
    function _isPaused() internal view returns (bool) {
        return paused() || factory.globalPause();
    }

    /**
     * @notice Modifier that throws if called by any account other than the manager or the owner
    */
    modifier onlyManager() {
        if (msg.sender != owner() && msg.sender != keeper()) revert NotManager();
        _;
    }

    /// @notice The address of the keeper, set on the factory.
    function keeper() public view returns (address) {
        return factory.keeper();
    }

    /// @notice The address of the fee treasury, set on the factory.
    function treasury() public view returns (address) {
        return factory.treasury();
    }

    /**
     * @notice get the fee breakdown from the factory
     * @return total total performance fee as a fraction of DIVISOR (e.g. 0.1e18 = 10% of earnings)
     * @return call caller tip as a fraction of the total fee (e.g. 0.05e18 = 5% of the fee)
     */
    function getFees() internal view returns (uint256 total, uint256 call) {
        return factory.getFees();
    }

    /**
     * @notice The locked profit is the amount of token0 and token1 that is locked in the vault, this can be overriden by the strategy contract.
     * @return locked0 The amount of token0 locked
     * @return locked1 The amount of token1 locked
     */
    function lockedProfit() public virtual view returns (uint256 locked0, uint256 locked1) {
        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < DURATION ? DURATION - elapsed : 0;
        return (totalLocked0 * remaining / DURATION, totalLocked1 * remaining / DURATION);
    }
}
