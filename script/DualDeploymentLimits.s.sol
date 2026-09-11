// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {DeploymentParameters} from "./DeploymentParameters.s.sol";

/// Dual-only required inputs, in underlying token units. No narrowing casts.
abstract contract DualDeploymentLimits is DeploymentParameters {
    struct Limits {
        uint256 riskCapacity;
        uint256 loanCapacity;
        uint256 riskCredit;
        uint256 loanCredit;
        uint256 seedLoan;
        uint256 seedRisk;
    }

    function _readLimits() internal view returns (Limits memory limits) {
        limits.riskCapacity = vm.envUint("RISK_RESERVE_CAPACITY");
        limits.loanCapacity = vm.envUint("LOAN_RESERVE_CAPACITY");
        limits.riskCredit = vm.envUint("RISK_CREDIT");
        limits.loanCredit = vm.envUint("LOAN_CREDIT");
    }

    function _readSeedLimits() internal view returns (Limits memory limits) {
        limits = _readLimits();
        limits.seedLoan = vm.envOr("SEED_USDG", uint256(1000e6));
        limits.seedRisk = vm.envOr("SEED_WETH", uint256(0.5e18));
        _validateSeeds(limits, limits.seedLoan, limits.seedRisk);
    }

    // Anti-donation floor: the seed only needs to dwarf MINIMUM_ETOKEN_AMOUNT (1000 raw units)
    // so the first-depositor inflation/donation attack is uneconomic. 200 USDG = 2e8 raw (2e5x the
    // floor) and 0.05 WETH = 5e16 raw (5e13x the floor) both keep an enormous margin; the earlier
    // 1000e6 / 0.5e18 was a soft-launch sizing choice, not a security threshold. Lowered 2026-09-07
    // for a smaller first wave; do not go below these without re-checking the MINIMUM_ETOKEN margin.
    function _validateSeeds(Limits memory limits, uint256 seedLoan, uint256 seedRisk) internal pure {
        require(seedLoan >= 200e6, "SEED_USDG below deployment minimum");
        require(seedRisk >= 0.05e18, "SEED_WETH below deployment minimum");
        // Capacity must cover the mandatory seed, or the first deposits would revert.
        require(limits.loanCapacity >= seedLoan, "LOAN_RESERVE_CAPACITY below seed");
        require(limits.riskCapacity >= seedRisk, "RISK_RESERVE_CAPACITY below seed");
    }

    function _configureCapacities(LendingPool lending, Limits memory limits) internal {
        lending.setReserveCapacity(1, limits.loanCapacity);
        lending.setReserveCapacity(2, limits.riskCapacity);
    }

    function _configureCredits(LendingPool lending, uint256 vaultId, Limits memory limits) internal {
        lending.setCreditsOfVault(vaultId, 1, limits.loanCredit);
        lending.setCreditsOfVault(vaultId, 2, limits.riskCredit);
    }
}
