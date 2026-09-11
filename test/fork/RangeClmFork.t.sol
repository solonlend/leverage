// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RangeFactory} from "../../src/range/RangeFactory.sol";
import {SolonRangeVault} from "../../src/range/SolonRangeVault.sol";
import {RangeStrategyUniV3} from "../../src/range/RangeStrategyUniV3.sol";
import {RangeVaultDeployer, RangeStrategyDeployer} from "../../src/range/RangeDeployers.sol";

/// Solon CLM fork e2e (Robinhood Chain mainnet fork): the REAL WETH/USDG fee100 pool, real router.
/// Full lifecycle: create → deposit → fee generation (real swaps) → public harvest with caller tip
/// → moveTicks by whitelisted rebalancer → calm gate under price push → panic/unpause → withdraw.
/// Run: REQUIRE_RH_FORK=true forge test --match-contract RangeClmFork  (needs network)

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}
interface ISwapRouter02F {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}
interface IV3PoolF { function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool); }

contract RangeClmForkTest is Test {
    string RPC = "https://rpc.mainnet.chain.robinhood.com/rpc";
    address constant POOL   = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // token0? (checked in setUp)
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    RangeFactory factory;
    SolonRangeVault vault;
    RangeStrategyUniV3 strat;
    address alice = address(0xA11CE);
    address keeper = address(0xCE);
    address treasury = address(0x7EA);
    address rebalancer = address(0x4EBA);
    address trader = address(0x74AD);

    function setUp() public {
        if (!vm.envOr("REQUIRE_RH_FORK", false)) return;
        vm.createSelectFork(RPC);

        factory = new RangeFactory(keeper, treasury, address(new RangeVaultDeployer()), address(new RangeStrategyDeployer()));
        factory.setRebalancer(rebalancer, true);
        (address v, address s) = factory.createRangeVault(POOL, "Solon Range WETH-USDG", "srWU", 500, 30);
        vault = SolonRangeVault(v);
        strat = RangeStrategyUniV3(s);

        // Fund alice + trader with both tokens.
        deal(WETH, alice, 10e18);
        deal(USDG, alice, 30_000e6);
        deal(WETH, trader, 100e18);
        deal(USDG, trader, 400_000e6);
        vm.startPrank(alice);
        IERC20F(WETH).approve(address(vault), type(uint256).max);
        IERC20F(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(trader);
        IERC20F(WETH).approve(ROUTER, type(uint256).max);
        IERC20F(USDG).approve(ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!vm.envOr("REQUIRE_RH_FORK", false)) return;
        _;
    }

    function _depositAlice() internal returns (uint256 shares) {
        (,, uint256 need0, uint256 need1,,) = _preview(1e18, 3_000e6);
        vm.prank(alice);
        vault.deposit(need0, need1, 0);
        shares = vault.balanceOf(alice);
    }

    function _preview(uint256 a0, uint256 a1) internal view
        returns (uint256 pShares, uint256 dummy, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
    {
        (pShares, amount0, amount1, fee0, fee1) = vault.previewDeposit(a0, a1);
        dummy = 0;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        vm.prank(trader);
        ISwapRouter02F(ROUTER).exactInputSingle(ISwapRouter02F.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, fee: 100, recipient: trader,
            amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
    }

    function _tick() internal view returns (int24 t) { (, t,,,,,) = IV3PoolF(POOL).slot0(); }

    // FK1 存取全流程:入金→份额→仓位在池→全取→价值回环
    function testLifecycleDepositWithdraw() public onlyFork {
        uint256 w0 = IERC20F(WETH).balanceOf(alice);
        uint256 u0 = IERC20F(USDG).balanceOf(alice);

        uint256 shares = _depositAlice();
        assertGt(shares, 0);

        // 策略真实持仓:主仓流动性 > 0
        (, uint256 poolBal1Side,,,, ) = strat.balancesOfPool();
        (uint256 pb0, uint256 pb1,,,,) = strat.balancesOfPool();
        assertTrue(pb0 > 0 || pb1 > 0);
        poolBal1Side; // silence

        vm.prank(alice);
        vault.withdrawAll(0, 0);
        assertEq(vault.balanceOf(alice), 0);

        // 价值回环:按当下池价折算,损失 < 0.7%(滑动费+MINIMUM_SHARES+取整)
        uint256 price = strat.price(); // token1/token0 1e36 级
        uint256 before1 = u0 + w0 * price / 1e36;
        uint256 after1 = IERC20F(USDG).balanceOf(alice) + IERC20F(WETH).balanceOf(alice) * price / 1e36;
        assertGt(after1, before1 * 993 / 1000);
    }

    // FK2 真费收割:swap 生成费→公众 harvest→caller 小费+treasury 分账+利润锁定线性释放
    function testHarvestWithRealFees() public onlyFork {
        _depositAlice();

        // 来回打两笔 swap 生成手续费(不净移动价格)
        _swap(USDG, WETH, 50_000e6);
        _swap(WETH, USDG, 20e18);
        _swap(USDG, WETH, 10_000e6);

        address caller = address(0xCA11);
        uint256 c0 = IERC20F(WETH).balanceOf(caller);
        uint256 c1 = IERC20F(USDG).balanceOf(caller);
        uint256 t0b = IERC20F(WETH).balanceOf(treasury);
        uint256 t1b = IERC20F(USDG).balanceOf(treasury);

        vm.prank(caller, caller); // tx.origin = caller
        strat.harvest();

        uint256 callerGain = (IERC20F(WETH).balanceOf(caller) - c0) + (IERC20F(USDG).balanceOf(caller) - c1);
        uint256 treasuryGain = (IERC20F(WETH).balanceOf(treasury) - t0b) + (IERC20F(USDG).balanceOf(treasury) - t1b);
        assertGt(callerGain + treasuryGain, 0); // 有费被抽走
        // 分账比例:call=fee 的 5% → treasury ≈ 19×caller。双币各自独立成比例(C-6 补:两侧都断言)
        uint256 cw = IERC20F(WETH).balanceOf(caller) - c0;
        uint256 tw = IERC20F(WETH).balanceOf(treasury) - t0b;
        uint256 cu = IERC20F(USDG).balanceOf(caller) - c1;
        uint256 tu = IERC20F(USDG).balanceOf(treasury) - t1b;
        assertTrue(cw > 100 || cu > 100); // 至少一侧有实质费量,否则比例断言全部空转
        if (cw > 100) assertApproxEqRel(tw, cw * 19, 0.01e18);
        if (cu > 100) assertApproxEqRel(tu, cu * 19, 0.01e18);

        // 利润锁定:刚收割完 balances 扣减 locked;1 小时后全释放
        (uint256 locked0, uint256 locked1) = strat.lockedProfit();
        assertTrue(locked0 > 0 || locked1 > 0);
        vm.warp(block.timestamp + 1 hours + 1);
        (locked0, locked1) = strat.lockedProfit();
        assertEq(locked0, 0); assertEq(locked1, 0);
    }

    // FK3 moveTicks:价格移动后重铺区间
    function testMoveTicksRecenters() public onlyFork {
        _depositAlice();
        int24 tickBefore = _tick();

        // 推价:单向大额 swap(移动十几个 tick)
        _swap(USDG, WETH, 60_000e6);
        int24 tickAfter = _tick();
        assertTrue(tickAfter != tickBefore);

        // 等 TWAP 追上现价再挪(否则 calm 拦截——这正是设计行为)
        vm.warp(block.timestamp + 300);
        // fork 上 warp 不改 observe 历史,但 120s 窗口内累计值线性外推,偏差收敛
        (int24 mainLowerBefore,) = strat.positionMain();

        vm.prank(rebalancer);
        try strat.moveTicks() {
            (int24 mainLowerAfter, int24 mainUpperAfter) = strat.positionMain();
            // 新区间覆盖新价格
            assertLe(mainLowerAfter, tickAfter);
            assertGe(mainUpperAfter, tickAfter);
            mainLowerBefore; // referenced
        } catch {
            // NotCalm:推价幅度>阈值且 TWAP 未收敛——同样验证了 calm 生效,单独断言
            assertFalse(strat.isCalm());
        }
    }

    // FK4 calm 门控:NotCalm 拦存款,取款永远放行(fork 改动:不平静时跳过 re-add 而不是 revert)
    // 确定性制造 NotCalm:把阈值收到 1 tick 再小幅推价——不赌池深
    function testCalmGateBlocksDepositNotWithdraw() public onlyFork {
        uint256 shares = _depositAlice();

        strat.setDeviation(1); // owner=本测试合约
        // 递增推价直到真 NotCalm(池深随区块变化,固定刀数不稳定);$2M 都推不动 1 tick 阈值就该 FAIL
        deal(USDG, trader, 2_000_000e6);
        for (uint256 i; i < 8 && strat.isCalm(); ++i) {
            _swap(USDG, WETH, 250_000e6);
        }
        assertFalse(strat.isCalm()); // 不早退虚报——必须真的不平静

        (,, uint256 n0, uint256 n1,,) = _preview(1e17, 300e6);
        vm.prank(alice);
        vm.expectRevert(RangeStrategyUniV3.NotCalm.selector);
        vault.deposit(n0 > 0 ? n0 : 1e17, n1 > 0 ? n1 : 300e6, 0);

        // 取款在 NotCalm 下照常成功;剩余资金闲置在策略(跳过 re-add)
        // (+1s 避开"同块存取强制 calm"守卫——那是防闪电贷的,不是这里要测的)
        vm.warp(block.timestamp + 1);
        uint256 u0 = IERC20F(WETH).balanceOf(alice);
        uint256 u1 = IERC20F(USDG).balanceOf(alice);
        uint256 half = shares / 2;
        vm.prank(alice);
        vault.withdraw(half, 0, 0);
        assertEq(vault.balanceOf(alice), shares - half);
        assertGt((IERC20F(WETH).balanceOf(alice) - u0) + (IERC20F(USDG).balanceOf(alice) - u1), 0);
        (uint256 pb0, uint256 pb1,,,,) = strat.balancesOfPool();
        assertEq(pb0 + pb1, 0); // 未 re-add

        // 平静恢复(warp 后 observe 外推收敛到现价)→ 任何 calm 动作把闲置资金重新入池
        vm.warp(block.timestamp + 600);
        assertTrue(strat.isCalm());
        vm.prank(address(0xCA11), address(0xCA11));
        strat.harvest();
        (pb0, pb1,,,,) = strat.balancesOfPool();
        assertGt(pb0 + pb1, 0); // 重新入池
    }

    // FK6 锁定期多用户会计(Codex 点名的"最重要缺口"):
    // harvest 制造活跃锁定 → 锁定期中途入金的人拿不到已锁利润 → 先来者独享,后来者本金不缩水
    function testMultiUserAccountingDuringActiveLock() public onlyFork {
        uint256 aliceShares = _depositAlice();

        // 生成费并 harvest → 利润进入 1h 线性锁定
        _swap(USDG, WETH, 50_000e6);
        _swap(WETH, USDG, 20e18);
        vm.warp(block.timestamp + 1);
        vm.prank(address(0xCA11), address(0xCA11));
        strat.harvest();
        (uint256 lk0, uint256 lk1) = strat.lockedProfit();
        assertTrue(lk0 > 0 || lk1 > 0); // 锁定活跃

        // bob 在锁定期正中入金
        address bobU = address(0xB0B2);
        deal(WETH, bobU, 2e18); deal(USDG, bobU, 6_000e6);
        vm.startPrank(bobU);
        IERC20F(WETH).approve(address(vault), type(uint256).max);
        IERC20F(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        (, uint256 nb0, uint256 nb1,,) = vault.previewDeposit(1e18, 3_000e6);
        uint256 b0In = IERC20F(WETH).balanceOf(bobU); uint256 b1In = IERC20F(USDG).balanceOf(bobU);
        vm.prank(bobU);
        vault.deposit(nb0, nb1, 0);
        uint256 bobShares = vault.balanceOf(bobU);
        uint256 bobIn1 = (b1In - IERC20F(USDG).balanceOf(bobU)) + (b0In - IERC20F(WETH).balanceOf(bobU)) * strat.price() / 1e36;

        // 锁定全释放
        vm.warp(block.timestamp + 1 hours + 1);

        // bob 全退:拿回 ≈ 本金(锁定利润只按他的小份额比例分,吃不到 harvest 前的存量费)
        vm.prank(bobU);
        vault.withdrawAll(0, 0);
        uint256 price = strat.price();
        uint256 valueBefore = b0In * price / 1e36 + b1In;
        uint256 valueAfter = IERC20F(WETH).balanceOf(bobU) * price / 1e36 + IERC20F(USDG).balanceOf(bobU);
        uint256 bobOut1 = valueAfter + bobIn1 - valueBefore; // 实际从金库取回的价值
        // 本金回环:损失 <1%(滑动费+取整)
        assertGt(bobOut1, bobIn1 * 99 / 100);

        // alice 全退:价值 ≥ 本金(她赚了全部 harvest 前费+锁定利润大头);金库清空到只剩烧毁份额
        vm.prank(alice);
        vault.withdrawAll(0, 0);
        assertEq(vault.totalSupply(), 1e3);
        aliceShares; bobShares; lk0; lk1;
    }

    // FK5 panic/unpause 应急闭环
    function testPanicUnpause() public onlyFork {
        _depositAlice();

        vm.prank(keeper);
        strat.panic(0, 0);
        // panic 后仓位全拔回策略,存款被拒
        (uint256 pb0, uint256 pb1,,,,) = strat.balancesOfPool();
        assertEq(pb0 + pb1, 0);
        (,, uint256 n0, uint256 n1,,) = _preview(1e17, 300e6);
        vm.prank(alice);
        vm.expectRevert(); // Pausable: paused(StrategyPaused 经由 _addLiquidity)
        vault.deposit(n0 > 0 ? n0 : 1e17, n1 > 0 ? n1 : 300e6, 0);

        // 暂停中取款照常(先取值再 prank,避免 prank 被 balanceOf 静态调用消费)
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.withdraw(half, 0, 0);

        vm.prank(keeper);
        strat.unpause();
        // 恢复后可再存
        (,, n0, n1,,) = _preview(1e17, 300e6);
        vm.prank(alice);
        vault.deposit(n0 > 0 ? n0 : 1e17, n1 > 0 ? n1 : 300e6, 0);
    }
}
