// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";

contract SolonVaultRegistryTest is Test {
    SolonVaultRegistry registry;
    address oldVault = address(0x111);
    address newVault = address(0x222);

    function setUp() public {
        registry = new SolonVaultRegistry();
        registry.setVault(1, oldVault);
    }

    function _propose(uint256 id, address replacement) internal {
        (bool ok,) = address(registry).call(abi.encodeWithSignature("proposeVaultUpdate(uint256,address)", id, replacement));
        assertTrue(ok, "owner must be able to schedule correction");
    }

    function _execute(uint256 id) internal returns (bool ok) {
        (ok,) = address(registry).call(abi.encodeWithSignature("executeVaultUpdate(uint256)", id));
    }

    function test_correctionAfterTimelockDoesNotMigrateBorrowAuthority() public {
        AddressRegistry addresses = new AddressRegistry(address(0x999));
        addresses.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(registry));
        LendingPool lending = new LendingPool(address(addresses), address(0x999));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, 100);
        _propose(1, newVault);
        assertEq(registry.vaults(1), oldVault);
        assertFalse(_execute(1), "must wait two days");
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertTrue(_execute(1), "correction must execute after delay");
        assertEq(registry.vaults(1), newVault);
        assertFalse(lending.borrowingWhiteList(newVault));
        assertEq(lending.credits(1, newVault), 0);
        // Permissions remain address-keyed: operators must revoke old authority before updating.
        assertTrue(lending.borrowingWhiteList(oldVault));
        assertEq(lending.credits(1, oldVault), 100);
        assertFalse(_execute(1), "proposal consumed");
    }

    function test_cancelPreventsExecution() public {
        _propose(1, newVault);
        (bool ok,) = address(registry).call(abi.encodeWithSignature("cancelVaultUpdate(uint256)", 1));
        assertTrue(ok, "owner can cancel scheduled correction");
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertFalse(_execute(1));
        assertEq(registry.vaults(1), oldVault);
    }

    function test_ownershipRoundTripInvalidatesOldProposal() public {
        _propose(1, newVault);
        registry.transferOwnership(address(0x333));
        vm.prank(address(0x333));
        registry.acceptOwnership();
        vm.prank(address(0x333));
        registry.transferOwnership(address(this));
        registry.acceptOwnership();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertFalse(_execute(1), "previous ownership epoch cannot execute");
        _propose(1, newVault);
        assertFalse(_execute(1));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertTrue(_execute(1));
    }

    event VaultUpdateProposed(uint256 indexed vaultId, address indexed previousVault, address indexed replacement, uint256 executableAt);
    event VaultUpdated(uint256 indexed vaultId, address indexed previousVault, address indexed replacement);
    event VaultUpdateCancelled(uint256 indexed vaultId);

    function test_replacementRestartsDelayAndEmitsAuditableEvents() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultUpdateProposed(1, oldVault, newVault, block.timestamp + 2 days);
        _propose(1, newVault);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        address revised = address(0x444);
        _propose(1, revised);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertFalse(_execute(1), "replaced proposal cannot use original deadline");
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        assertFalse(_execute(1), "one second before deadline");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultUpdated(1, oldVault, revised);
        assertTrue(_execute(1));
        assertEq(registry.vaults(1), revised);
        _propose(1, newVault);
        vm.expectEmit(true, false, false, true, address(registry));
        emit VaultUpdateCancelled(1);
        registry.cancelVaultUpdate(1);
        _propose(1, newVault);
        assertFalse(_execute(1), "reschedule after cancellation needs fresh delay");
    }

    function test_onlyOwnerMayProposeExecuteOrCancel() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("NOT_OWNER");
        registry.proposeVaultUpdate(1, newVault);
        _propose(1, newVault);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(address(0xBAD));
        vm.expectRevert("NOT_OWNER");
        registry.executeVaultUpdate(1);
        vm.prank(address(0xBAD));
        vm.expectRevert("NOT_OWNER");
        registry.cancelVaultUpdate(1);
        assertTrue(_execute(1));
    }

    function test_invalidCorrectionAndLegacyRegistrationGuards() public {
        vm.expectRevert("ID_UNKNOWN");
        registry.proposeVaultUpdate(2, newVault);
        vm.expectRevert("VAULT_0");
        registry.proposeVaultUpdate(1, address(0));
        vm.expectRevert("VAULT_SAME");
        registry.proposeVaultUpdate(1, oldVault);
        vm.expectRevert("NO_UPDATE");
        registry.cancelVaultUpdate(1);
        vm.expectRevert("ID_TAKEN");
        registry.setVault(1, newVault);
        registry.setVault(2, newVault);
        assertEq(registry.vaults(2), newVault);
    }
}
