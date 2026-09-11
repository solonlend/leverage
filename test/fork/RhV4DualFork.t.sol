// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LpShareOracleV4} from "../../src/LpShareOracleV4.sol";
import {SwapExecutorV3} from "../../src/SwapExecutorV3.sol";
import {LendingPool} from "../../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../../src/lending/SolonVaultRegistry.sol";
import {UniV4DualVault} from "../../src/UniV4DualVault.sol";
import {PoolKey, Currency, IHooks, IV4PositionManager, V4Encode} from "../../src/v4/V4Periphery.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";
import {FairLpMath} from "../../src/libraries/FairLpMath.sol";

/*
  RH 主网 fork × 真 Uniswap V4:Permit2 部署闸的验收测试。
  之前 mock PM 用直接 transferFrom 掩盖了 SETTLE_PAIR 走 Permit2 的事实(异构 code-review CONFIRMED);
  本套件全程对真 PoolManager/PositionManager/Permit2:
    V4F-A 建自有池(WETH/USDG fee137/spacing3 无 hook)并按真喂价初始化;真 PM 种子 LP(测试 LP 自己走 Permit2)
    V4F-B UniV4DualVault 全 e2e:open(SETTLE_PAIR 经 Permit2 拉款——修复靶点)→addMargin→rebalance→close
  2026-09-06 链上确认:主网现存 fee100/spacing1 无 hook 的 WETH/USDG V4 池已被垃圾价格占坑
  (tick 887271、无真实流动性)；V4 金库上线时不可指向该池。
  Run: REQUIRE_RH_FORK=true forge test --match-contract RhV4DualFork(需要网络)
*/

interface IERC20f {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPoolManagerMin {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IPermit2Min {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender)
        external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// 真 PoolManager 上的最小 StateView(v4-core StateLibrary 布局:_pools 在 slot 6)。
contract MiniStateView {
    IPoolManagerMin public immutable PM;
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    constructor(address pm) { PM = IPoolManagerMin(pm); }
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        uint256 d = uint256(PM.extsload(keccak256(abi.encodePacked(poolId, POOLS_SLOT))));
        sqrtPriceX96 = uint160(d);
        tick = int24(int256(d >> 160));
        protocolFee = uint24(d >> 184);
        lpFee = uint24(d >> 208);
    }
}

contract RhV4DualForkTest is Test {
    string RPC = "https://rpc.mainnet.chain.robinhood.com/rpc";
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    uint24 constant TEST_FEE = 137;
    int24 constant TEST_TICK_SPACING = 3;
    bool forked;
    LpShareOracleV4 oracle;
    MiniStateView sv;
    bytes32 poolId;
    uint160 initialSqrtPrice;
    uint256 seedTokenId;

    function setUp() public {
        try vm.createSelectFork(RPC) { forked = true; } catch {
            if (vm.envOr("REQUIRE_RH_FORK", false)) revert("required RH fork unavailable");
            forked = false;
        }
        if (!forked) return;
        oracle = new LpShareOracleV4(ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6, 26 hours, 26 hours, 100);
        sv = new MiniStateView(POOL_MANAGER);
        poolId = keccak256(abi.encode(_poolKey()));
        initialSqrtPrice = _initializeCleanPool();
        _seedLp(makeAddr("seedLp"));
    }

    function _poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(WETH), currency1: Currency.wrap(USDG),
            fee: TEST_FEE, tickSpacing: TEST_TICK_SPACING, hooks: IHooks(address(0))
        });
    }

    /// Never reuse public pool state: a key collision must fail explicitly, not inherit its price.
    function _initializeCleanPool() internal returns (uint160 sqrtP) {
        (uint160 existing,,,) = sv.getSlot0(poolId);
        assertEq(existing, 0, "fixture pool key occupied: choose another fee/spacing");
        uint256 ethPx = oracle.riskValueInLoan(1e18); // USDG 6dp per ETH
        sqrtP = FairLpMath.sqrtPriceX96FromFeeds(ethPx * 100, 1e8, 18, 6);
        IPoolManagerMin(POOL_MANAGER).initialize(_poolKey(), sqrtP);
        (uint160 actual,,,) = sv.getSlot0(poolId);
        assertEq(actual, sqrtP, "pool must initialize at feed-derived price");
    }

    /// Clamp before narrowing; Solidity division aligns toward zero, keeping both bounds inside limits.
    function _tickRange(int24 tick, int24 radius) internal pure returns (int24 lower, int24 upper) {
        int256 spacing = TEST_TICK_SPACING;
        int256 minTick = int256(TickMath.MIN_TICK) + spacing;
        int256 maxTick = int256(TickMath.MAX_TICK) - spacing;
        int256 lo = int256(tick) - radius;
        int256 hi = int256(tick) + radius;
        lo = lo < minTick ? minTick : (lo > maxTick ? maxTick : lo);
        hi = hi < minTick ? minTick : (hi > maxTick ? maxTick : hi);
        lower = int24((lo / spacing) * spacing);
        upper = int24((hi / spacing) * spacing);
        require(lower < upper, "empty fixture tick range");
    }

    /// 种子 LP:走与散户相同的 Permit2 链路(token→Permit2→POSM)
    function _seedLp(address lp) internal {
        deal(WETH, lp, 100e18);
        deal(USDG, lp, 300_000e6);
        vm.startPrank(lp);
        IERC20f(WETH).approve(PERMIT2, type(uint256).max);
        IERC20f(USDG).approve(PERMIT2, type(uint256).max);
        IPermit2Min(PERMIT2).approve(WETH, POSM, type(uint160).max, type(uint48).max);
        IPermit2Min(PERMIT2).approve(USDG, POSM, type(uint160).max, type(uint48).max);
        (, int24 tick,,) = sv.getSlot0(poolId);
        (int24 lower, int24 upper) = _tickRange(tick, 5000);
        seedTokenId = IV4PositionManager(POSM).nextTokenId();
        IV4PositionManager(POSM).modifyLiquidities(
            V4Encode.mint(_poolKey(), lower, upper, 2e15, type(uint128).max, type(uint128).max, lp),
            block.timestamp + 600
        );
        vm.stopPrank();
        assertEq(IV4PositionManager(POSM).getPositionLiquidity(seedTokenId), 2e15, "seed LP minted");
    }

    function test_V4FA_own_pool_init_and_seed_via_real_posm() public {
        vm.skip(!forked, "RH fork unavailable");
        (uint160 sp, int24 tick,,) = sv.getSlot0(poolId);
        assertGt(sp, 0, "pool initialized (MiniStateView reads real slot0)");
        emit log_named_int("init tick", tick);
        assertEq(sp, initialSqrtPrice, "seed mint preserves feed-derived price");
        assertEq(IV4PositionManager(POSM).getPositionLiquidity(seedTokenId), 2e15, "real seed liquidity");
        emit log("real POSM mint via Permit2 ok");
    }

    function test_V4FB_dual_vault_full_e2e_real_v4() public {
        vm.skip(!forked, "RH fork unavailable");

        // 借贷侧(与 V3 fork e2e 同构)
        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        LendingPool lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG); // 1
        lending.initReserve(WETH); // 2
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));
        SwapExecutorV3 exec = new SwapExecutorV3(V3_ROUTER, 100);

        UniV4DualVault vault = new UniV4DualVault(UniV4DualVault.InitParams({
            governor: makeAddr("gov"), positionManager: POSM, stateView: address(sv),
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: address(oracle), swapExecutor: address(exec),
            token0: WETH, token1: USDG, loanIsC0: false, fee: TEST_FEE, tickSpacing: TEST_TICK_SPACING, hooks: address(0),
            minWidthTicks: 10, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        lending.setCreditsOfVault(1, 2, type(uint128).max);

        // 双边出借人
        address lu = makeAddr("lu"); address lw = makeAddr("lw");
        deal(USDG, lu, 500_000e6); deal(WETH, lw, 200e18);
        vm.startPrank(lu); IERC20f(USDG).approve(address(lending), type(uint256).max);
        lending.deposit(1, 500_000e6, lu, 0); vm.stopPrank();
        vm.startPrank(lw); IERC20f(WETH).approve(address(lending), type(uint256).max);
        lending.deposit(2, 200e18, lw, 0); vm.stopPrank();

        // 开仓:SETTLE_PAIR 经 Permit2 —— 修复前这里对真 PM 必 revert
        address user = makeAddr("v4User");
        deal(USDG, user, 3_000e6);
        (, int24 cur,,) = sv.getSlot0(poolId);
        (int24 lower, int24 upper) = _tickRange(cur, 2000);
        uint256 ethPx = oracle.riskValueInLoan(1e18);
        uint256 borrowWeth = (2_000e6 * 1e18) / ethPx;
        vm.startPrank(user);
        IERC20f(USDG).approve(address(vault), type(uint256).max);
        IERC20f(WETH).approve(address(vault), type(uint256).max);
        uint256 id = vault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: 2_000e6, borrowRisk: borrowWeth, borrowLoan: 500e6,
            tickLower: lower, tickUpper: upper,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0, deadline: block.timestamp + 600
        }));
        vm.stopPrank();
        (, uint128 liq,,, uint256 dW, uint256 dU) = vault.positions(id);
        assertGt(liq, 0, "REAL v4 PM mint via Permit2 SETTLE_PAIR");
        (uint256 wDebt,) = lending.getCurrentDebt(dW);
        (uint256 uDebt,) = lending.getCurrentDebt(dU);
        assertApproxEqAbs(wDebt, borrowWeth, 1e6, "WETH debt");
        assertLe(uDebt, 500e6, "USDG debt <= borrowed (E-2)");
        emit log_named_uint("opened liq", liq);
        // 审计 F4:显式断言金库的 Permit2 额度已上膛(而非撞对了别的路径)
        (uint160 aW,,) = IPermit2Min(PERMIT2).allowance(address(vault), WETH, POSM);
        (uint160 aU,,) = IPermit2Min(PERMIT2).allowance(address(vault), USDG, POSM);
        assertEq(aW, type(uint160).max, "vault WETH Permit2 allowance armed");
        assertEq(aU, type(uint160).max, "vault USDG Permit2 allowance armed");

        // 补保证金
        deal(USDG, user, 200e6);
        vm.prank(user);
        vault.addMargin(id, 0, 200e6);

        // 原地换区间(再次经 Permit2 mint)
        (lower, upper) = _tickRange(cur, 1000);
        vm.prank(user);
        vault.rebalance(id, UniV4DualVault.RebalanceParams({
            newTickLower: lower, newTickUpper: upper, swapAmount: 0,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 600
        }));
        (, uint128 liq2,,,,) = vault.positions(id);
        assertGt(liq2, 0, "re-ranged on real v4");

        // increase:真 v4 PM 上加仓(INCREASE_LIQUIDITY+SETTLE_PAIR 经 Permit2,v1.2 新功能)
        deal(USDG, user, 500e6);
        vm.startPrank(user);
        (, uint128 liqBeforeInc,,,,) = vault.positions(id);
        vault.increase(id, UniV4DualVault.IncreaseParams({
            investRisk: 0, investLoan: 500e6,
            borrowRisk: (250e6 * 1e18) / ethPx, borrowLoan: 250e6,
            minLiquidity: 1, deadline: block.timestamp + 600
        }));
        vm.stopPrank();
        (, uint128 liqAfterInc,,,,) = vault.positions(id);
        assertGt(liqAfterInc, liqBeforeInc, "increase grew liquidity on REAL v4 PM via Permit2");

        // harvest 双模式(真 v4 PM:claim 直转;compound 走 INCREASE_LIQUIDITY+SETTLE_PAIR 经 Permit2)
        vm.startPrank(user);
        vault.harvest(id, false, block.timestamp + 600);
        vault.harvest(id, true, block.timestamp + 600);
        vm.stopPrank();
        (, uint128 liqH,,,,) = vault.positions(id);
        assertGt(liqH, 0, "position intact after harvest (real v4 increase path)");

        // 全平(缺口结算走真 V3 router)
        vm.startPrank(user);
        vault.close(id, UniV4DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 600
        }));
        vm.stopPrank();
        (uint256 wDebtF,) = lending.getCurrentDebt(dW);
        (uint256 uDebtF,) = lending.getCurrentDebt(dU);
        // 粉尘口径已改为"价值"(v1.3):18 位小数的 RISK 腿残债必须按预言机折算后再比阈值,
        // 直接比原始 wei 正是被修掉的那个量纲缺陷。GAP_EPS=1e3 → 0.001 USDG。
        assertLe(oracle.riskValueInLoan(wDebtF), 1e3, "risk residual is dust in VALUE terms");
        assertLe(uDebtF, 1e3, "loan residual is dust");
        emit log("V4 full e2e on REAL PM+Permit2: open/margin/rebalance/close all clean");
    }

    /// 反证:抹掉 Permit2 代码后,SETTLE_PAIR 不可能靠直接 ERC20 授权兜底 —— open 必失败。
    function test_V4FC_settle_requires_permit2_negative_control() public {
        vm.skip(!forked, "RH fork unavailable");

        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        LendingPool lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG);
        lending.initReserve(WETH);
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));
        SwapExecutorV3 exec = new SwapExecutorV3(V3_ROUTER, 100);
        UniV4DualVault vault = new UniV4DualVault(UniV4DualVault.InitParams({
            governor: makeAddr("gov"), positionManager: POSM, stateView: address(sv),
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: address(oracle), swapExecutor: address(exec),
            token0: WETH, token1: USDG, loanIsC0: false, fee: TEST_FEE, tickSpacing: TEST_TICK_SPACING, hooks: address(0),
            minWidthTicks: 10, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        lending.setCreditsOfVault(1, 2, type(uint128).max);
        address lu = makeAddr("lu2");
        deal(USDG, lu, 100_000e6); deal(WETH, lu, 50e18);
        vm.startPrank(lu);
        IERC20f(USDG).approve(address(lending), type(uint256).max);
        IERC20f(WETH).approve(address(lending), type(uint256).max);
        lending.deposit(1, 100_000e6, lu, 0);
        lending.deposit(2, 50e18, lu, 0);
        vm.stopPrank();

        vm.etch(PERMIT2, ""); // Permit2 消失 → _armPermit2 跳过 → 真 PM settle 无款可拉
        address user = makeAddr("negUser");
        deal(USDG, user, 3_000e6);
        (, int24 cur,,) = sv.getSlot0(poolId);
        (int24 lower, int24 upper) = _tickRange(cur, 2000);
        vm.startPrank(user);
        IERC20f(USDG).approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: 2_000e6, borrowRisk: 0.5e18, borrowLoan: 500e6,
            tickLower: lower, tickUpper: upper,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            deadline: block.timestamp + 600
        }));
        vm.stopPrank();
        emit log("negative control: without Permit2 the real PM settle path reverts (no ERC20 fallback)");
    }
}
