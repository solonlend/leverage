// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DualDeploymentLimits} from "../script/DualDeploymentLimits.s.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";
import {MockERC20} from "../script/testnet/TestnetMocks.sol";

contract DualLimitsHarness is DualDeploymentLimits {
    function configure(LendingPool lending) external {
        Limits memory limits = _readLimits();
        _configureCapacities(lending, limits);
        _configureCredits(lending, 1, limits);
    }
}

contract DualDeploymentLimitsTest is Test {
    function testConfiguredLimitsReachCorrectReservesAndEnforceDepositCap() public {
        vm.setEnv("LOAN_RESERVE_CAPACITY", "1000000000");
        vm.setEnv("RISK_RESERVE_CAPACITY", "500000000000000000");
        vm.setEnv("LOAN_CREDIT", "800000000");
        vm.setEnv("RISK_CREDIT", "400000000000000000");
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MockERC20 usdg = new MockERC20("USDG", "USDG", 6);
        AddressRegistry registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, address(this));
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));
        vaultReg.setVault(1, address(this));
        LendingPool lending = new LendingPool(address(registry), address(weth));
        lending.initReserve(address(usdg));
        lending.initReserve(address(weth));
        DualLimitsHarness harness = new DualLimitsHarness();
        lending.transferOwnership(address(harness));
        harness.configure(lending);
        (,,,,,, uint256 loanCapacity,,,,,) = lending.reserves(1);
        (,,,,,, uint256 riskCapacity,,,,,) = lending.reserves(2);
        assertEq(loanCapacity, 1e9);
        assertEq(riskCapacity, 5e17);
        assertEq(lending.credits(1, address(this)), 8e8);
        assertEq(lending.credits(2, address(this)), 4e17);
        usdg.mint(address(this), 1e9 + 1);
        weth.mint(address(this), 5e17 + 1);
        usdg.approve(address(lending), 1e9 + 1);
        weth.approve(address(lending), 5e17 + 1);
        lending.deposit(1, 1e9, address(this), 0);
        lending.deposit(2, 5e17, address(this), 0);
        vm.expectRevert(); lending.deposit(1, 1, address(this), 0);
        vm.expectRevert(); lending.deposit(2, 1, address(this), 0);
        // Both pool APIs accept uint256: configured values must never be narrowed to uint128.
        uint256 wideCredit = uint256(type(uint128).max) + 1;
        vm.setEnv("LOAN_CREDIT", vm.toString(wideCredit));
        harness.configure(lending);
        assertEq(lending.credits(1, address(this)), wideCredit);
    }
}
