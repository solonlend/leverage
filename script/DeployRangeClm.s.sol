// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeployRangeClm — Robinhood Chain 部署 Solon CLM(Range Vaults)首发:
  RangeFactory + WETH/USDG fee100 一对 vault/strategy(不可升级实例)。

  流程:
    1. new RangeFactory(keeper, treasury)
    2. factory.createRangeVault(POOL, name, symbol, POSITION_WIDTH, MAX_TICK_DEVIATION)
    3. factory.setRebalancer(keeper EOA们, true)
    4. (软启动)首笔种子存款由部署者自投,建立非零份额基线(通胀攻击第一道闸;
       MINIMUM_SHARES 烧毁是第二道)
    5. 控制台输出全部地址 + 逐项 read-back

  环境变量:
    KEEPER / TREASURY(必填;treasury 建议与杠杆金库同一收款地址)
    REBALANCER2(可选,第二 keeper EOA)
    POSITION_WIDTH(默认 500 = ±5%,fee100 池 spacing=1)
    MAX_TICK_DEVIATION(默认 30 ≈ 0.3%,依据 2026-09-09 实测 120s TWAP p90=8.9 tick)
    SEED_WETH(默认 0.02e18)/ SEED_USDG(默认 50e6)——种子自投,两边都给,失衡由滑动费自净

  先 anvil fork 演练(--broadcast 打到 fork);真部署由 KousanS 拍板。
*/

import {Script, console2} from "forge-std/Script.sol";
import {RangeFactory} from "../src/range/RangeFactory.sol";
import {SolonRangeVault} from "../src/range/SolonRangeVault.sol";
import {RangeStrategyUniV3} from "../src/range/RangeStrategyUniV3.sol";
import {RangeVaultDeployer, RangeStrategyDeployer} from "../src/range/RangeDeployers.sol";

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract DeployRangeClm is Script {
    address constant POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        require(block.chainid == 4663, "RH mainnet only (fork it for rehearsal)");
        address keeper = vm.envAddress("KEEPER");
        address treasury = vm.envAddress("TREASURY");
        address rebalancer2 = vm.envOr("REBALANCER2", address(0));
        int24 width = int24(int256(vm.envOr("POSITION_WIDTH", uint256(500))));
        int56 deviation = int56(int256(vm.envOr("MAX_TICK_DEVIATION", uint256(30))));
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.02e18));
        uint256 seedUsdg = vm.envOr("SEED_USDG", uint256(50e6));

        vm.startBroadcast();

        RangeFactory factory = new RangeFactory(keeper, treasury, address(new RangeVaultDeployer()), address(new RangeStrategyDeployer()));
        (address vaultAddr, address stratAddr) =
            factory.createRangeVault(POOL, "Solon Range WETH/USDG", "srWETHUSDG", width, deviation);
        factory.setRebalancer(keeper, true);
        if (rebalancer2 != address(0)) factory.setRebalancer(rebalancer2, true);

        // 种子自投:部署者两币入金,建立首个真实份额基线
        SolonRangeVault vault = SolonRangeVault(vaultAddr);
        IERC20D(WETH).approve(vaultAddr, seedWeth);
        IERC20D(USDG).approve(vaultAddr, seedUsdg);
        (, uint256 need0, uint256 need1,,) = vault.previewDeposit(
            _c0IsWeth() ? seedWeth : seedUsdg, _c0IsWeth() ? seedUsdg : seedWeth
        );
        vault.deposit(need0, need1, 0);

        vm.stopBroadcast();

        // Read-back
        RangeStrategyUniV3 strat = RangeStrategyUniV3(stratAddr);
        console2.log("== Solon CLM deployed ==");
        console2.log("factory   :", address(factory));
        console2.log("vault     :", vaultAddr);
        console2.log("strategy  :", stratAddr);
        console2.log("pool      :", strat.pool());
        console2.log("width     :", uint256(int256(strat.positionWidth())));
        console2.log("deviation :", uint256(int256(strat.maxTickDeviation())));
        (uint256 tf, uint256 cf) = factory.getFees();
        console2.log("totalFee  :", tf);
        console2.log("callFee   :", cf);
        console2.log("keeper    :", factory.keeper());
        console2.log("treasury  :", factory.treasury());
        console2.log("seedShares:", vault.totalSupply());
        (uint256 b0, uint256 b1) = vault.balances();
        console2.log("balances0 :", b0);
        console2.log("balances1 :", b1);
        require(address(vault.strategy()) == stratAddr, "wiring: vault->strategy");
        require(strat.vault() == vaultAddr, "wiring: strategy->vault");
        require(vault.totalSupply() > 1e3, "seed deposit missing");
        require(factory.rebalancers(keeper), "rebalancer missing");
    }

    function _c0IsWeth() internal pure returns (bool) {
        return WETH < USDG;
    }
}
