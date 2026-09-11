// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  E2ESepoliaSmoke — 部署后的链上冒烟:mint 保证金 → 开仓(双借) → 补保证金 → 原地换区间 → 全平。
  地址从环境变量读(VAULT/LENDING/WETH_M/USDG_M/ORACLE/POOL_M),anvil 演练与真 Sepolia 通用。
  真正的暴打测试是独立 harness;这里只验部署接线全通。
*/

import {Script, console2} from "forge-std/Script.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
import {LpShareOracleV4} from "../src/LpShareOracleV4.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {MockERC20} from "./testnet/TestnetMocks.sol";

interface IV3PoolLike {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

contract E2ESepoliaSmoke is Script {
    function run() external {
        UniV3DualVault vault = UniV3DualVault(vm.envAddress("VAULT"));
        LendingPool lending = LendingPool(payable(vm.envAddress("LENDING")));
        LpShareOracleV4 oracle = LpShareOracleV4(vm.envAddress("ORACLE"));
        MockERC20 weth = MockERC20(vm.envAddress("WETH_M"));
        MockERC20 usdg = MockERC20(vm.envAddress("USDG_M"));
        address pool = vm.envAddress("POOL_M");
        address me = msg.sender;

        vm.startBroadcast();
        weth.mint(me, 100e18);
        usdg.mint(me, 100_000e6);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);

        (, int24 cur,,,,,) = IV3PoolLike(pool).slot0();
        uint256 ethPx = oracle.riskValueInLoan(1e18);
        console2.log("current tick", cur);
        console2.log("oracle ETH px (USDG 6dp)", ethPx);

        // 开仓:自带 2000 USDG,借 2000 价值 WETH + 500 USDG
        uint256 borrowWeth = (2_000e6 * 1e18) / ethPx;
        uint256 id = vault.open(UniV3DualVault.OpenParams({
            investRisk: 0, investLoan: 2_000e6, borrowRisk: borrowWeth, borrowLoan: 500e6,
            tickLower: cur - 2000, tickUpper: cur + 2000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, deadline: block.timestamp + 1800
        }));
        (, uint128 liq,,, uint256 dW, uint256 dU) = vault.positions(id);
        (uint256 wDebt,) = lending.getCurrentDebt(dW);
        (uint256 uDebt,) = lending.getCurrentDebt(dU);
        console2.log("opened id", id);
        console2.log("liquidity", liq);
        console2.log("WETH debt", wDebt);
        console2.log("USDG debt", uDebt);
        require(liq > 0, "SMOKE: no liquidity");

        // 补保证金(单侧 USDG 200)
        vault.addMargin(id, 0, 200e6);
        (uint256 uDebt2,) = lending.getCurrentDebt(dU);
        console2.log("USDG debt after margin", uDebt2);

        // 原地收窄区间
        vault.rebalance(id, UniV3DualVault.RebalanceParams({
            newTickLower: cur - 1000, newTickUpper: cur + 1000, swapAmount: 0,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1800
        }));
        (, uint128 liq2,,,,) = vault.positions(id);
        console2.log("liquidity after rebalance", liq2);
        require(liq2 > 0, "SMOKE: rebalance lost liquidity");

        // 全平(带 topUp 缓冲 + 允许缺口 swap)
        usdg.approve(address(vault), type(uint256).max);
        uint256 wBefore = weth.balanceOf(me);
        uint256 uBefore = usdg.balanceOf(me);
        vault.close(id, UniV3DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 1800
        }));
        console2.log("WETH back", weth.balanceOf(me) - wBefore);
        console2.log("USDG back", usdg.balanceOf(me) - uBefore);
        (uint256 wDebtF,) = lending.getCurrentDebt(dW);
        (uint256 uDebtF,) = lending.getCurrentDebt(dU);
        console2.log("residual WETH debt (wei)", wDebtF);
        console2.log("residual USDG debt", uDebtF);
        // v1.3:两腿都按 LOAN(USDG 6dp)价值口径比较 GAP_EPS=1e3。
        require(oracle.riskValueInLoan(wDebtF) <= 1e3 && uDebtF <= 1e3, "SMOKE: residual debt beyond dust");
        console2.log("SMOKE OK: open/addMargin/rebalance/close all clean");
        vm.stopBroadcast();
    }
}
