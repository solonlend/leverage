// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeploySepoliaDual — Sepolia 公共测试网部署 Dual-Borrow 全套,供链上暴打测试。

  与 DeployRhDual 的差异:
    · WETH/USDG 均为 MockERC20(自由 mint,真 ETH 只当 gas);
    · 喂价 = MockFeedOwned(owner 可控,暴打脚本人为制造暴跌/脱锚/停摆);
    · Uniswap V3 用 Sepolia 官方部署(Factory/NFPM/SwapRouter02),fee 100 档已开;
    · 池子由本脚本 createAndInitializePoolIfNecessary + NFPM.mint 灌流动性。

  LLTV / 清算奖励 / 协议留存 / 五个利率端点输入均必填，见 DeploymentParameters.s.sol。

  ██测试网专用██:mock 代币开放 mint、喂价可人为拧,任何生产部署禁止引用本脚本。
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
import {FairLpMath} from "../src/libraries/FairLpMath.sol";
import {MockERC20, MockFeedOwned} from "./testnet/TestnetMocks.sol";

interface INfpm {
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external payable returns (address pool);
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IPoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

contract DeploySepoliaDual is DualDeploymentLimits {
    // Sepolia 官方 Uniswap V3(链上已验码)
    address constant NFPM   = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E; // SwapRouter02
    uint24 constant FEE = 100;

    int256 constant ETH_PRICE = 2500e8; // 初始 1 ETH = 2500 USDG

    function run() external {
        address deployer = msg.sender;
        Parameters memory parameters = _readParameters();
        Limits memory limits = _readSeedLimits();
        vm.startBroadcast();

        // 1. Mock 代币 + 可控喂价
        MockERC20 weth = new MockERC20("Wrapped Ether (Solon test)", "WETH", 18);
        MockERC20 usdg = new MockERC20("USDG (Solon test)", "USDG", 6);
        MockFeedOwned ethFeed = new MockFeedOwned(ETH_PRICE);
        MockFeedOwned usdgFeed = new MockFeedOwned(1e8);

        // 2. 排序适配(mock 地址随机,两种排序都要能跑)
        (address t0, address t1) = address(weth) < address(usdg)
            ? (address(weth), address(usdg)) : (address(usdg), address(weth));
        bool loanIsC0 = t0 == address(usdg);
        (address feed0, address feed1, uint8 dec0, uint8 dec1) = loanIsC0
            ? (address(usdgFeed), address(ethFeed), uint8(6), uint8(18))
            : (address(ethFeed), address(usdgFeed), uint8(18), uint8(6));

        // 3. 建池 + 初始化到喂价价格
        uint160 sqrtPrice = FairLpMath.sqrtPriceX96FromFeeds(
            loanIsC0 ? uint256(1e8) : uint256(uint256(ETH_PRICE)),
            loanIsC0 ? uint256(uint256(ETH_PRICE)) : uint256(1e8),
            dec0, dec1
        );
        address pool = INfpm(NFPM).createAndInitializePoolIfNecessary(t0, t1, FEE, sqrtPrice);

        // 4. 灌池流动性:50 WETH + 125k USDG,±5000 tick 宽带
        weth.mint(deployer, 1_000_000e18);
        usdg.mint(deployer, 2_000_000_000e6);
        weth.approve(NFPM, type(uint256).max);
        usdg.approve(NFPM, type(uint256).max);
        (, int24 tick,,,,,) = IPoolSlot0(pool).slot0();
        INfpm(NFPM).mint(INfpm.MintParams({
            token0: t0, token1: t1, fee: FEE,
            tickLower: tick - 5000, tickUpper: tick + 5000,
            amount0Desired: loanIsC0 ? 125_000e6 : uint256(50e18),
            amount1Desired: loanIsC0 ? uint256(50e18) : 125_000e6,
            amount0Min: 0, amount1Min: 0,
            recipient: deployer, deadline: block.timestamp + 1800
        }));

        // 5. 预言机 + swap 执行器
        LpShareOracleV4 oracle =
            new LpShareOracleV4(feed0, feed1, address(usdgFeed), dec0, dec1, 6, 3 hours, 26 hours, 100);
        SwapExecutorV3 swapExecutor = new SwapExecutorV3(ROUTER, FEE);

        // 6. 借贷侧:双储备(1=USDG LOAN, 2=WETH RISK)
        AddressRegistry registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, deployer);
        LendingPool lending = new LendingPool(address(registry), address(weth));
        lending.initReserve(address(usdg));
        _configureRate(lending, 1, parameters);
        lending.initReserve(address(weth));
        _configureRate(lending, 2, parameters);
        _configureCapacities(lending, limits); // Apply before either seed deposit.
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        // 7. Dual 金库
        UniV3DualVault vault = new UniV3DualVault(UniV3DualVault.InitParams({
            governor: deployer, positionManager: NFPM, pool: pool,
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: address(oracle), swapExecutor: address(swapExecutor),
            token0: t0, token1: t1, loanIsC0: loanIsC0, fee: FEE,
            minWidthTicks: 10, liqBonusBps: parameters.liqBonusBps, protocolFeeBps: parameters.protocolFeeBps, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: parameters.lltv
        }));

        // 8. 双储备先 seed，再开放借款接线；容量已显式配置。
        usdg.approve(address(lending), limits.seedLoan);
        weth.approve(address(lending), limits.seedRisk);
        lending.deposit(1, limits.seedLoan, deployer, 0);
        lending.deposit(2, limits.seedRisk, deployer, 0);
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        _configureCredits(lending, 1, limits);

        vault.setLiquidator(deployer, true);
        vm.stopBroadcast();

        console2.log("=== Solon Sepolia Dual-Borrow (TESTNET) ===");
        console2.log("WETH mock     ", address(weth));
        console2.log("USDG mock     ", address(usdg));
        console2.log("ethFeed       ", address(ethFeed));
        console2.log("usdgFeed      ", address(usdgFeed));
        console2.log("pool          ", pool);
        console2.log("loanIsC0      ", loanIsC0);
        console2.log("oracle        ", address(oracle));
        console2.log("swapExecutor  ", address(swapExecutor));
        console2.log("registry      ", address(registry));
        console2.log("lendingPool   ", address(lending));
        console2.log("eToken USDG(1)", lending.getETokenAddress(1));
        console2.log("eToken WETH(2)", lending.getETokenAddress(2));
        console2.log("vaultRegistry ", address(vaultReg));
        console2.log("dualVault     ", address(vault));
    }
}
