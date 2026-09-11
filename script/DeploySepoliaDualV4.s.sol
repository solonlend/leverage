// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeploySepoliaDualV4 — Sepolia 部署 UniV4DualVault(真 Uniswap v4 官方 PoolManager/PositionManager/Permit2)。

  复用 V3 战役的既有设施(省 gas + 测多金库共享借贷池):
    · mock WETH/USDG、可控喂价、LendingPool/AddressRegistry/SolonVaultRegistry、oracle、SwapExecutorV3
    · V4 金库注册为 vaultId=2,双储备授信
  新做:
    · 真 v4 PoolManager.initialize(mockWETH/mockUSDG, fee100, spacing1, no hook)按当前喂价
    · 部署者经 Permit2 走真 PositionManager 灌种子流动性(和散户同链路)
    · UniV4DualVault(Permit2 结算已上膛) + 官方 StateView

  环境变量(.testnet/anvil.env):WETH_M/USDG_M/ETH_FEED/USDG_FEED/LENDING/ORACLE/VREG。
  ██测试网专用██
*/

import {Script, console2} from "forge-std/Script.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";
import {SwapExecutorV3} from "../src/SwapExecutorV3.sol";
import {PoolKey, Currency, IHooks, IV4PositionManager, V4Encode} from "../src/v4/V4Periphery.sol";
import {FairLpMath} from "../src/libraries/FairLpMath.sol";
import {MockERC20, MockFeedOwned} from "./testnet/TestnetMocks.sol";

interface IPoolManagerMin {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

interface IStateViewMin {
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IPermit2Min {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract DeploySepoliaDualV4 is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E; // 缺口结算走 V3(与 RH 生产一致)
    uint24 constant FEE = 100;
    int24 constant SPACING = 1;

    function run() external {
        address deployer = msg.sender;
        MockERC20 weth = MockERC20(vm.envAddress("WETH_M"));
        MockERC20 usdg = MockERC20(vm.envAddress("USDG_M"));
        MockFeedOwned ethFeed = MockFeedOwned(vm.envAddress("ETH_FEED"));
        LendingPool lending = LendingPool(payable(vm.envAddress("LENDING")));
        SolonVaultRegistry vaultReg = SolonVaultRegistry(vm.envAddress("VREG"));
        address oracle = vm.envAddress("ORACLE");

        (address t0, address t1) = address(weth) < address(usdg)
            ? (address(weth), address(usdg)) : (address(usdg), address(weth));
        bool loanIsC0 = t0 == address(usdg);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0), currency1: Currency.wrap(t1),
            fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        bytes32 poolId = keccak256(abi.encode(key));

        vm.startBroadcast();

        // 1. 初始化 V4 池到当前喂价
        uint256 px8 = uint256(ethFeed.answer());
        (uint160 sp,,,) = IStateViewMin(STATE_VIEW).getSlot0(poolId);
        if (sp == 0) {
            sp = loanIsC0
                ? FairLpMath.sqrtPriceX96FromFeeds(1e8, px8, 6, 18)
                : FairLpMath.sqrtPriceX96FromFeeds(px8, 1e8, 18, 6);
            IPoolManagerMin(POOL_MANAGER).initialize(key, sp);
        }

        // 2. 种子流动性:走 Permit2(与散户同链路,真 SETTLE_PAIR)
        weth.mint(deployer, 300e18);
        usdg.mint(deployer, 1_000_000e6);
        weth.approve(PERMIT2, type(uint256).max);
        usdg.approve(PERMIT2, type(uint256).max);
        IPermit2Min(PERMIT2).approve(address(weth), POSM, type(uint160).max, type(uint48).max);
        IPermit2Min(PERMIT2).approve(address(usdg), POSM, type(uint160).max, type(uint48).max);
        (, int24 tick,,) = IStateViewMin(STATE_VIEW).getSlot0(poolId);
        IV4PositionManager(POSM).modifyLiquidities(
            V4Encode.mint(key, tick - 10000, tick + 10000, 3e15, type(uint128).max, type(uint128).max, deployer),
            block.timestamp + 1800
        );

        // 3. V4 金库(Permit2 结算已内置) + 接线为 vaultId 2
        SwapExecutorV3 exec = new SwapExecutorV3(V3_ROUTER, FEE);
        UniV4DualVault vault = new UniV4DualVault(UniV4DualVault.InitParams({
            governor: deployer, positionManager: POSM, stateView: STATE_VIEW,
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: oracle, swapExecutor: address(exec),
            token0: t0, token1: t1, loanIsC0: loanIsC0, fee: FEE, tickSpacing: SPACING, hooks: address(0),
            minWidthTicks: 10, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(2, address(vault));
        lending.enableVaultToBorrow(2);
        lending.setCreditsOfVault(2, 1, type(uint128).max);
        lending.setCreditsOfVault(2, 2, type(uint128).max);
        vault.setLiquidator(deployer, true);

        vm.stopBroadcast();

        console2.log("=== Solon Sepolia Dual-Borrow V4 (TESTNET) ===");
        console2.log("v4 poolId");
        console2.logBytes32(poolId);
        console2.log("loanIsC0      ", loanIsC0);
        console2.log("swapExecutor  ", address(exec));
        console2.log("dualVaultV4   ", address(vault));
        console2.log("posm nextId   ", IV4PositionManager(POSM).nextTokenId());
    }
}
