// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  UpgradeSepoliaVaultHarvest — Sepolia 测试环境金库换代:部署带 harvest(claim/复投) 的
  UniV3DualVault 新实例(合约 immutable 无升级,换代=新实例注册新 vaultId,老金库照常运行——
  正是给用户讲过的"焊死参数要改就发新金库"流程的实操)。复用既有 mock 币/喂价/借贷池/池子。
  ██测试网专用██
*/

import {Script, console2} from "forge-std/Script.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

contract UpgradeSepoliaVaultHarvest is Script {
    function run() external {
        address deployer = msg.sender;
        address weth = vm.envAddress("WETH_M");
        address usdg = vm.envAddress("USDG_M");
        LendingPool lending = LendingPool(payable(vm.envAddress("LENDING")));
        SolonVaultRegistry vaultReg = SolonVaultRegistry(vm.envAddress("VREG"));

        (address t0, address t1) = weth < usdg ? (weth, usdg) : (usdg, weth);

        vm.startBroadcast();
        UniV3DualVault vault = new UniV3DualVault(UniV3DualVault.InitParams({
            governor: deployer, positionManager: 0x1238536071E1c677A632429e3655c799b22cDA52,
            pool: vm.envAddress("POOL_M"),
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: vm.envAddress("ORACLE"), swapExecutor: 0x769c6A3E2C0b749c133a9428bA6ACF184158e5EB,
            token0: t0, token1: t1, loanIsC0: t0 == usdg, fee: 100,
            minWidthTicks: 10, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(3, address(vault));
        lending.enableVaultToBorrow(3);
        lending.setCreditsOfVault(3, 1, type(uint128).max);
        lending.setCreditsOfVault(3, 2, type(uint128).max);
        vault.setLiquidator(deployer, true);
        vm.stopBroadcast();

        console2.log("dualVault v1.1 (harvest)", address(vault));
    }
}
