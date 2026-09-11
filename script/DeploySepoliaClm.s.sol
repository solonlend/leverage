// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeploySepoliaClm — Sepolia 实链 CLM 全套(实战演练,先于 RH 主网):
  RangeFactory + 既有 WETH/USDG mock fee100 池(2026-09-06 dual 部署的同一池)。
  前置:池 observationCardinality 已扩容且有 ≥120s 观测覆盖(否则 isCalm revert)。
  种子:1 WETH + 2500 USDG(mock 可自 mint)。
*/

import {Script, console2} from "forge-std/Script.sol";
import {RangeFactory} from "../src/range/RangeFactory.sol";
import {SolonRangeVault} from "../src/range/SolonRangeVault.sol";
import {RangeStrategyUniV3} from "../src/range/RangeStrategyUniV3.sol";
import {RangeVaultDeployer, RangeStrategyDeployer} from "../src/range/RangeDeployers.sol";

interface IMockMint {
    function mint(address, uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract DeploySepoliaClm is Script {
    address constant POOL = 0x81ffB0C7127e90212f85cc825e9ecA8056A28A02; // WETH/USDG mock fee100
    address constant WETH = 0x5Fb4b5AA8f408389cA96E7e5B9cFF014A8176563; // token0
    address constant USDG = 0xB89b8f4d12bDFf564FF475832DE683dAF0911cDb; // token1

    function run() external {
        require(block.chainid == 11155111, "Sepolia only");
        address deployer = msg.sender;

        vm.startBroadcast();

        RangeFactory factory = new RangeFactory(deployer, deployer,
            address(new RangeVaultDeployer()), address(new RangeStrategyDeployer())); // keeper=treasury=deployer(测试)
        (address vaultAddr, address stratAddr) =
            factory.createRangeVault(POOL, "Solon Range WETH/USDG (Sepolia)", "srWU-sep", 500, 30);
        factory.setRebalancer(deployer, true);

        // 种子
        IMockMint(WETH).mint(deployer, 1e18);
        IMockMint(USDG).mint(deployer, 2500e6);
        IMockMint(WETH).approve(vaultAddr, type(uint256).max);
        IMockMint(USDG).approve(vaultAddr, type(uint256).max);
        SolonRangeVault vault = SolonRangeVault(vaultAddr);
        (, uint256 need0, uint256 need1,,) = vault.previewDeposit(1e18, 2500e6);
        vault.deposit(need0, need1, 0);

        vm.stopBroadcast();

        RangeStrategyUniV3 strat = RangeStrategyUniV3(stratAddr);
        console2.log("factory   :", address(factory));
        console2.log("vault     :", vaultAddr);
        console2.log("strategy  :", stratAddr);
        console2.log("shares    :", vault.totalSupply());
        (uint256 b0, uint256 b1) = vault.balances();
        console2.log("bal0(WETH):", b0);
        console2.log("bal1(USDG):", b1);
        require(address(vault.strategy()) == stratAddr && strat.vault() == vaultAddr, "wiring");
        require(vault.totalSupply() > 1e3, "seed missing");
    }
}
