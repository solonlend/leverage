// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeployRhDual — Robinhood Chain 部署 Dual-Borrow 全套(UniV3DualVault,WETH/USDG fee100 首发)。

  与单币版 DeployRhV3 的差异:
    · 双储备:initReserve(USDG)=1 + initReserve(WETH)=2,金库两储备各 enableVaultToBorrow+setCredits;
    · **两个储备都必须种子存款**(捐赠压零汇率 DoS 对每个储备独立成立,红队 A1a/A1b);
    · 金库 = UniV3DualVault(双债/双币 in-kind/缺口 exactOutput/rebalance);
    · keeper 走 keeper 包的 start:dual(双币垫款)。

  必填风控/利率环境变量见 DeploymentParameters.s.sol 与 DEPLOY-CHECKLIST.md。
  环境变量:RISK_MAX_STALENESS_SECONDS / STABLE_MAX_STALENESS_SECONDS /
    STABLE_DEPEG_BPS(均必填);GOVERNOR / KEEPER(默认=部署者);
  SEED_USDG(默认 1000e6);SEED_WETH(默认 0.5e18)。
  先 anvil fork 演练;真部署由 KousanS 拍板(DEPLOY-CHECKLIST.md 逐项过完才允许)。
*/

import {console2} from "forge-std/Script.sol";
import {DualDeploymentLimits} from "./DualDeploymentLimits.s.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
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

contract DeployRhDual is DualDeploymentLimits {
    address constant NFPM   = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant POOL   = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_FEED  = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    function run() external {
        address deployer = msg.sender;
        Parameters memory parameters = _readParameters();
        Limits memory limits = _readSeedLimits();
        address governor = vm.envOr("GOVERNOR", deployer);
        address keeper = vm.envOr("KEEPER", deployer);
        uint256 riskMaxStaleness = vm.envUint("RISK_MAX_STALENESS_SECONDS");
        uint256 stableMaxStaleness = vm.envUint("STABLE_MAX_STALENESS_SECONDS");
        uint256 stableDepegBps = vm.envUint("STABLE_DEPEG_BPS");
        require(riskMaxStaleness != 0, "RISK_MAX_STALENESS_SECONDS must be non-zero");
        require(stableMaxStaleness != 0, "STABLE_MAX_STALENESS_SECONDS must be non-zero");
        require(stableDepegBps != 0, "STABLE_DEPEG_BPS must be non-zero");
        require(IERC20(USDG).balanceOf(deployer) >= limits.seedLoan, "insufficient USDG for mandatory seed");
        require(IERC20(WETH).balanceOf(deployer) >= limits.seedRisk, "insufficient WETH for mandatory seed");

        vm.startBroadcast();

        // 1. 预言机(含 riskValueInLoan;三个风控参数按清单 1.10 显式设置)
        LpShareOracleV4 oracle = new LpShareOracleV4(
            ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6,
            riskMaxStaleness, stableMaxStaleness, stableDepegBps
        );

        // 2. swap 执行器(exactInput + exactOutput)
        SwapExecutorV3 swapExecutor = new SwapExecutorV3(ROUTER, 100);

        // 3. 借贷侧:双储备
        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, governor);
        LendingPool lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG);
        _configureRate(lending, 1, parameters); // reserveId 1 = LOAN
        lending.initReserve(WETH);
        _configureRate(lending, 2, parameters); // reserveId 2 = RISK
        _configureCapacities(lending, limits); // Apply before either seed deposit.
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        // 4. Dual 金库
        UniV3DualVault vault = new UniV3DualVault(UniV3DualVault.InitParams({
            governor: governor, positionManager: NFPM, pool: POOL,
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: address(oracle), swapExecutor: address(swapExecutor),
            token0: WETH, token1: USDG, loanIsC0: false, fee: 100,
            minWidthTicks: 10, liqBonusBps: parameters.liqBonusBps, protocolFeeBps: parameters.protocolFeeBps, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: parameters.lltv
        }));

        // 5. 双储备种子存款(硬前置,缺一不可；先 seed 再开放借款接线)
        IERC20(USDG).approve(address(lending), limits.seedLoan);
        lending.deposit(1, limits.seedLoan, governor, 0);
        IERC20(WETH).approve(address(lending), limits.seedRisk);
        lending.deposit(2, limits.seedRisk, governor, 0);

        // 6. 接线:白名单 + 双授信
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        _configureCredits(lending, 1, limits);

        // 7. keeper + 权限交接。VaultRegistry 是两步 ownership，governor 仍须 acceptOwnership。
        if (governor == deployer) {
            vault.setLiquidator(keeper, true);
        } else {
            console2.log("MANUAL STEP: governor must call vault.setLiquidator(keeper, true)");
            IOwnable(lending.getStakingAddress(1)).transferOwnership(governor);
            IOwnable(lending.getStakingAddress(2)).transferOwnership(governor);
            registry.transferOwnership(governor);
            vaultReg.transferOwnership(governor);
            lending.transferOwnership(governor); // 最后转，前序失败时部署者仍可修复接线
        }

        vm.stopBroadcast();

        if (governor != deployer) {
            console2.log("MANUAL STEP: governor must call vaultReg.acceptOwnership()");
        }

        console2.log("=== Solon RH Dual-Borrow deployment ===");
        console2.log("oracle        ", address(oracle));
        console2.log("swapExecutor  ", address(swapExecutor));
        console2.log("registry      ", address(registry));
        console2.log("lendingPool   ", address(lending));
        console2.log("eToken USDG(1)", lending.getETokenAddress(1));
        console2.log("eToken WETH(2)", lending.getETokenAddress(2));
        console2.log("vaultRegistry ", address(vaultReg));
        console2.log("dualVault     ", address(vault));
        console2.log("governor      ", governor);
        console2.log("keeper        ", keeper);
    }
}
