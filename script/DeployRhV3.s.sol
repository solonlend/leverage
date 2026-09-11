// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeployRhV3 — Robinhood Chain 上部署 Solon 杠杆 LP v1 全套(V3 WETH/USDG fee100 首发)。

  部署顺序 = 依赖顺序:
    1. LpShareOracleV4(真 Chainlink feeds)
    2. SwapExecutorV3(真 swapRouter02, 默认 fee100)
    3. AddressRegistry → LendingPool → initReserve(USDG) → SolonVaultRegistry
    4. UniV3LeverageVault
    5. 强制 seed → vaultId=1 登记 → 白名单+授信 → keeper / 权限交接

  必填风控/利率环境变量见 DeploymentParameters.s.sol 与 DEPLOY-CHECKLIST.md。
  环境变量:
    RISK_MAX_STALENESS_SECONDS    风险资产腿最大陈旧时间(秒,必填)
    STABLE_MAX_STALENESS_SECONDS  稳定币腿最大陈旧时间(秒,必填)
    STABLE_DEPEG_BPS              稳定币相对 1 USD 的最大偏离(bps,必填)
    GOVERNOR   国库/治理地址(默认 = 部署者)
    KEEPER     清算 keeper EOA(默认 = 部署者)
  运行(先 anvil fork 演练,真部署由用户拍板):
    forge script script/DeployRhV3.s.sol --rpc-url $RPC --broadcast --private-key $PK
*/

import {console2} from "forge-std/Script.sol";
import {DeploymentParameters} from "./DeploymentParameters.s.sol";
import {UniV3LeverageVault} from "../src/UniV3LeverageVault.sol";
import {LpShareOracleV4} from "../src/LpShareOracleV4.sol";
import {SwapExecutorV3} from "../src/SwapExecutorV3.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IOwnable {
    function transferOwnership(address newOwner) external;
}

contract DeployRhV3 is DeploymentParameters {
    // Robinhood Chain (4663) 实测地址 — 与 test/fork/RhV3Fork.t.sol 同源
    address constant NFPM   = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant POOL   = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100(最深)
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_FEED  = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    function run() external {
        address deployer = msg.sender;
        Parameters memory parameters = _readParameters();
        address governor = vm.envOr("GOVERNOR", deployer);
        address keeper = vm.envOr("KEEPER", deployer);
        uint256 riskMaxStaleness = vm.envUint("RISK_MAX_STALENESS_SECONDS");
        uint256 stableMaxStaleness = vm.envUint("STABLE_MAX_STALENESS_SECONDS");
        uint256 stableDepegBps = vm.envUint("STABLE_DEPEG_BPS");
        require(riskMaxStaleness != 0, "RISK_MAX_STALENESS_SECONDS must be non-zero");
        require(stableMaxStaleness != 0, "STABLE_MAX_STALENESS_SECONDS must be non-zero");
        require(stableDepegBps != 0, "STABLE_DEPEG_BPS must be non-zero");

        uint256 seedU = vm.envOr("SEED_USDG", uint256(1000e6));
        require(seedU >= 1000e6, "SEED_USDG below deployment minimum");
        require(IERC20(USDG).balanceOf(deployer) >= seedU, "insufficient USDG for mandatory seed");

        vm.startBroadcast();

        // 1. 预言机(WETH 18 位 / USDG 6 位,三个风控参数按清单 1.10 显式设置)
        LpShareOracleV4 oracle = new LpShareOracleV4(
            ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6,
            riskMaxStaleness, stableMaxStaleness, stableDepegBps
        );

        // 2. zap 换币执行器
        SwapExecutorV3 swapExecutor = new SwapExecutorV3(ROUTER, 100);

        // 3. 借贷侧
        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, governor);
        LendingPool lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG);
        _configureRate(lending, 1, parameters); // reserveId = 1
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        // 4. 金库(LLTV / 清算奖励 / 协议留存由必填环境变量指定)
        UniV3LeverageVault vault = new UniV3LeverageVault(UniV3LeverageVault.InitParams({
            governor: governor, positionManager: NFPM, pool: POOL,
            lendingPool: address(lending), reserveId: 1, oracle: address(oracle), swapExecutor: address(swapExecutor),
            token0: WETH, token1: USDG, loanIsC0: false, fee: 100,
            minWidthTicks: 10, liqBonusBps: parameters.liqBonusBps, protocolFeeBps: parameters.protocolFeeBps, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: parameters.lltv
        }));

        // 5. Mandatory seed before registration / whitelist / credit.
        IERC20(USDG).approve(address(lending), seedU);
        lending.deposit(1, seedU, governor, 0);

        // 6. 接线
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);

        // 7. Keeper and ownership handoff; VaultRegistry requires governor acceptance.
        if (governor == deployer) {
            vault.setLiquidator(keeper, true);
        } else {
            console2.log("MANUAL STEP: governor must call vault.setLiquidator(keeper, true)");
            IOwnable(lending.getStakingAddress(1)).transferOwnership(governor);
            registry.transferOwnership(governor);
            vaultReg.transferOwnership(governor);
            lending.transferOwnership(governor); // Last, preserving repair access until wiring succeeds.
        }
        vm.stopBroadcast();
        if (governor != deployer) {
            console2.log("MANUAL STEP: governor must call vaultReg.acceptOwnership()");
        }

        console2.log("=== Solon RH V3 deployment ===");
        console2.log("oracle       ", address(oracle));
        console2.log("swapExecutor ", address(swapExecutor));
        console2.log("registry     ", address(registry));
        console2.log("lendingPool  ", address(lending));
        console2.log("eToken(USDG) ", lending.getETokenAddress(1));
        console2.log("vaultRegistry", address(vaultReg));
        console2.log("vault        ", address(vault));
        console2.log("governor     ", governor);
        console2.log("keeper       ", keeper);
    }
}
