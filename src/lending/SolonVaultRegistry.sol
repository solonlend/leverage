// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/IVaultFactory.sol";

/*
  SolonVaultRegistry — 实现 Extra LendingPool 依赖的 IVaultFactory.vaults(vaultId)。

  Extra 原版由 VaultFactory 按 pair 建仓;我们的杠杆金库(UniV3/V4LeverageVault)是独立部署的,
  所以用这张 owner 手工登记表代替:每个金库领一个 vaultId,LendingPool 的
  enableVaultToBorrow / setCreditsOfVault 通过它把白名单和授信落到金库地址上。
  已登记 id 可由 owner 经两天时间锁纠正;授信/白名单仍绑定地址,不会随 id 迁移。
  更新前应通过 LendingPool 撤销旧地址权限;本表不管理已有债务或地址权限。
*/
contract SolonVaultRegistry is IVaultFactory {
    address public owner;
    mapping(uint256 => address) public override vaults;

    uint256 public constant VAULT_UPDATE_DELAY = 2 days;
    struct VaultUpdate {
        address previousVault;
        address replacement;
        uint256 executableAt;
        uint256 ownershipEpoch;
    }
    uint256 public ownershipEpoch;
    mapping(uint256 => VaultUpdate) public pendingVaultUpdates;
    event VaultUpdateProposed(uint256 indexed vaultId, address indexed previousVault, address indexed replacement, uint256 executableAt);
    event VaultUpdateCancelled(uint256 indexed vaultId);
    event VaultUpdated(uint256 indexed vaultId, address indexed previousVault, address indexed replacement);

    function proposeVaultUpdate(uint256 vaultId, address replacement) external {
        require(msg.sender == owner, "NOT_OWNER");
        address previousVault = vaults[vaultId];
        require(previousVault != address(0), "ID_UNKNOWN");
        require(replacement != address(0), "VAULT_0");
        require(replacement != previousVault, "VAULT_SAME");
        uint256 executableAt = block.timestamp + VAULT_UPDATE_DELAY;
        pendingVaultUpdates[vaultId] = VaultUpdate(previousVault, replacement, executableAt, ownershipEpoch);
        emit VaultUpdateProposed(vaultId, previousVault, replacement, executableAt);
    }

    function cancelVaultUpdate(uint256 vaultId) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(pendingVaultUpdates[vaultId].executableAt != 0, "NO_UPDATE");
        delete pendingVaultUpdates[vaultId];
        emit VaultUpdateCancelled(vaultId);
    }

    function executeVaultUpdate(uint256 vaultId) external {
        require(msg.sender == owner, "NOT_OWNER");
        VaultUpdate memory update = pendingVaultUpdates[vaultId];
        require(update.executableAt != 0, "NO_UPDATE");
        require(update.ownershipEpoch == ownershipEpoch, "UPDATE_STALE");
        require(block.timestamp >= update.executableAt, "UPDATE_TIMELOCK");
        require(vaults[vaultId] == update.previousVault, "UPDATE_STALE");
        delete pendingVaultUpdates[vaultId];
        vaults[vaultId] = update.replacement;
        emit VaultUpdated(vaultId, update.previousVault, update.replacement);
    }

    event VaultSet(uint256 indexed vaultId, address indexed vault);

    constructor() { owner = msg.sender; }

    function setVault(uint256 vaultId, address vault) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(vault != address(0), "VAULT_0");
        require(vaults[vaultId] == address(0), "ID_TAKEN");
        vaults[vaultId] = vault;
        emit VaultSet(vaultId, vault);
    }

    event OwnershipTransferStarted(address indexed current, address indexed pending);
    event OwnershipTransferred(address indexed previous, address indexed current);
    address public pendingOwner;

    /// 两步转移:打错地址不再等于永久失控(安全审计 L9)。
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(newOwner != address(0), "OWNER_0");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING");
        emit OwnershipTransferred(owner, pendingOwner);
        ++ownershipEpoch; // Invalidate all proposals, including transfer-away-and-back cases.
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
