// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockERC20} from "./V4VaultFlow.integration.t.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {PoolKey, Currency} from "../src/v4/V4Periphery.sol";
import {NamedMockERC20} from "./LendingPoolIntegration.t.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

/*
  Dual-Borrow 金库 tracer(TDD 第一环):
  双储备(WETH id1? 按部署顺序:USDG=1, WETH=2)→ 两批出借人 → 双授信 →
  open 双币借款零 swap 铸仓 → 两笔债各自上账 → 健康度双债合并计价。
  设计依据 docs/DESIGN-dual-borrow-v1.md §1–§2。
*/

/// dual 版 mock 预言机:LP 公允价 per-liquidity + RISK 折 LOAN 价,均可调。
contract DualMockOracle {
    uint256 public valPerLiq = 2e18;
    uint256 public riskPrice = 1e18; // 1 RISK = 1 LOAN(测试基准)
    function setValPerLiq(uint256 v) external { valPerLiq = v; }
    function setRiskPrice(uint256 p) external { riskPrice = p; }
    function fairValueInLoan(uint128 liquidity, int24, int24) external view returns (uint256) {
        return (uint256(liquidity) * valPerLiq) / 1e18;
    }
    function riskValueInLoan(uint256 riskAmount) external view returns (uint256) {
        return (riskAmount * riskPrice) / 1e18;
    }
}

/// 双模式 swap 执行器:exactInput + exactOutput,rate = LOAN per RISK(1e18),计调用次数。
contract CountingSwap {
    uint256 public calls;
    bool public lastWasExactOutput;
    MockERC20 risk; MockERC20 loan; uint256 public rate = 1e18;
    constructor(MockERC20 a, MockERC20 b) { risk = a; loan = b; }
    function setRate(uint256 r) external { rate = r; }
    function _quoteOut(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        return tokenIn == address(risk) ? (amountIn * rate) / 1e18 : (amountIn * 1e18) / rate;
    }
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external returns (uint256 amountOut)
    {
        calls++; lastWasExactOutput = false;
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = _quoteOut(tokenIn, amountIn);
        require(amountOut >= minOut, "MINOUT");
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
    function swapExactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, bytes calldata)
        external returns (uint256 amountIn)
    {
        calls++; lastWasExactOutput = true;
        amountIn = tokenIn == address(risk) ? (amountOut * 1e18 + rate - 1) / rate : (amountOut * rate + 1e18 - 1) / 1e18;
        require(amountIn <= maxIn, "MAXIN");
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}

interface IERC20View2 { function balanceOf(address) external view returns (uint256); }

/// 可动 StateView:配合 MovablePM 让 sqrtP/tick 一起动。
contract MovableSV {
    uint160 public sqrtP; int24 public tick;
    constructor(uint160 s, int24 t) { sqrtP = s; tick = t; }
    function setSlot0(uint160 s, int24 t) external { sqrtP = s; tick = t; }
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) { return (sqrtP, tick, 0, 0); }
}

/// 可动价 PM:decrease/burn 按"当前价"重算返还比例,模拟 LP 成分随价格漂移。
/// 实现:记录每仓 (liquidity, tl, tu);撤出时按 setPrice 后的 sqrtP 用 LiquidityAmounts 算两腿。
contract MovablePM {
    MockERC20 t0; MockERC20 t1; uint160 public sqrtP;
    uint256 public nextTokenId = 1;
    mapping(uint256 => uint128) public liqOf;
    mapping(uint256 => int24) public tlOf;
    mapping(uint256 => int24) public tuOf;
    uint256 owed0; uint256 owed1; uint256 credit0; uint256 credit1;
    constructor(MockERC20 a, MockERC20 b, uint160 s) { t0 = a; t1 = b; sqrtP = s; }
    function setSqrtP(uint160 s) external { sqrtP = s; }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        owed0 = 0; owed1 = 0; credit0 = 0; credit1 = 0;
        for (uint256 i = 0; i < actions.length; i++) {
            uint8 a = uint8(actions[i]);
            if (a == 0x02) _mintPos(params[i]);
            else if (a == 0x00) _increase(params[i]);
            else if (a == 0x01) _decrease(params[i]);
            else if (a == 0x03) _burnPos(params[i]);
            else if (a == 0x0d) _settlePair();
            else if (a == 0x11) _takePair(params[i]);
            else revert("BAD_ACTION");
        }
    }
    function _amt(int24 tl, int24 tu, uint128 L) internal view returns (uint256 a0, uint256 a1) {
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), L);
    }
    function _mintPos(bytes memory p) internal {
        (, int24 tl, int24 tu, uint256 L,,,,) = abi.decode(p, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        uint256 id = nextTokenId++;
        (uint256 a0, uint256 a1) = _amt(tl, tu, uint128(L));
        liqOf[id] = uint128(L); tlOf[id] = tl; tuOf[id] = tu;
        owed0 += a0; owed1 += a1;
    }
    function _increase(bytes memory p) internal {
        (uint256 id, uint256 L,,) = abi.decode(p, (uint256, uint256, uint128, uint128));
        (uint256 a0, uint256 a1) = _amt(tlOf[id], tuOf[id], uint128(L));
        liqOf[id] += uint128(L); owed0 += a0; owed1 += a1;
    }
    function _decrease(bytes memory p) internal {
        (uint256 id, uint256 L,,) = abi.decode(p, (uint256, uint256, uint128, uint128));
        if (L > 0) {
            (uint256 g0, uint256 g1) = _amt(tlOf[id], tuOf[id], uint128(L));
            liqOf[id] -= uint128(L); credit0 += g0; credit1 += g1;
            t0.mint(address(this), g0); t1.mint(address(this), g1); // 供兑付(mock 简化)
        }
    }
    function _burnPos(bytes memory p) internal {
        (uint256 id,,) = abi.decode(p, (uint256, uint128, uint128));
        if (liqOf[id] > 0) {
            (uint256 g0, uint256 g1) = _amt(tlOf[id], tuOf[id], liqOf[id]);
            credit0 += g0; credit1 += g1;
            t0.mint(address(this), g0); t1.mint(address(this), g1);
            liqOf[id] = 0;
        }
    }
    function _settlePair() internal {
        if (owed0 > 0) t0.transferFrom(msg.sender, address(this), owed0);
        if (owed1 > 0) t1.transferFrom(msg.sender, address(this), owed1);
        owed0 = 0; owed1 = 0;
    }
    function _takePair(bytes memory p) internal {
        (,, address recipient) = abi.decode(p, (Currency, Currency, address));
        if (credit0 > 0) t0.transfer(recipient, credit0);
        if (credit1 > 0) t1.transfer(recipient, credit1);
        credit0 = 0; credit1 = 0;
    }
    function getPositionLiquidity(uint256 id) external view returns (uint128) { return liqOf[id]; }
}

contract DualVaultTest is Test {
    NamedMockERC20 weth; NamedMockERC20 usdg; // weth=token0(risk) < usdg=token1(loan)
    LendingPool lending;
    address eTokenLoan; address eTokenRisk;
    uint256 constant RESERVE_LOAN = 1; // USDG 先 init
    uint256 constant RESERVE_RISK = 2; // WETH 后 init
    MovablePM pm; CountingSwap swap; DualMockOracle oracle; MovableSV sv;
    SolonVaultRegistry vaultReg;
    UniV4DualVault vault;
    address user = makeAddr("user");
    address gov = makeAddr("gov");

    function setUp() public {
        NamedMockERC20 a = new NamedMockERC20("Wrapped ETH", "WETH");
        NamedMockERC20 b = new NamedMockERC20("USD Global", "USDG");
        (weth, usdg) = address(a) < address(b) ? (a, b) : (b, a);

        AddressRegistry registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        lending = new LendingPool(address(registry), address(weth));
        lending.initReserve(address(usdg)); // id 1 = LOAN
        lending.initReserve(address(weth)); // id 2 = RISK
        eTokenLoan = lending.getETokenAddress(RESERVE_LOAN);
        eTokenRisk = lending.getETokenAddress(RESERVE_RISK);
        vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        uint160 sqrtP0 = TickMath.getSqrtRatioAtTick(0);
        pm = new MovablePM(MockERC20(address(weth)), MockERC20(address(usdg)), sqrtP0);
        swap = new CountingSwap(MockERC20(address(weth)), MockERC20(address(usdg)));
        oracle = new DualMockOracle();
        sv = new MovableSV(sqrtP0, 0);

        vault = new UniV4DualVault(UniV4DualVault.InitParams({
            governor: gov, positionManager: address(pm), stateView: address(sv),
            lendingPool: address(lending), reserveRisk: RESERVE_RISK, reserveLoan: RESERVE_LOAN,
            oracle: address(oracle), swapExecutor: address(swap),
            token0: address(weth), token1: address(usdg), loanIsC0: false,
            fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, RESERVE_LOAN, type(uint128).max);
        lending.setCreditsOfVault(1, RESERVE_RISK, type(uint128).max);

        // 两批出借人:USDG 100 万、WETH 100 万
        _deposit(makeAddr("usdgLender"), usdg, RESERVE_LOAN, 1_000_000e18);
        _deposit(makeAddr("wethLender"), weth, RESERVE_RISK, 1_000_000e18);
    }

    function _deposit(address who, NamedMockERC20 tok, uint256 rid, uint256 amt) internal {
        tok.mint(who, amt);
        vm.startPrank(who);
        tok.approve(address(lending), type(uint256).max);
        lending.deposit(rid, amt, who, 0);
        vm.stopPrank();
    }

    function _open(uint256 iRisk, uint256 iLoan, uint256 bRisk, uint256 bLoan) internal returns (uint256 id) {
        if (iRisk > 0) weth.mint(user, iRisk);
        if (iLoan > 0) usdg.mint(user, iLoan);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        id = vault.open(UniV4DualVault.OpenParams({
            investRisk: iRisk, investLoan: iLoan, borrowRisk: bRisk, borrowLoan: bLoan,
            tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    /// tracer:双币借款开仓,零 swap,两笔债各自上账,LP 铸出。
    function test_open_dualBorrow_zeroSwap_twoDebts() public {
        uint256 riskCashBefore = IERC20View2(address(weth)).balanceOf(eTokenRisk);
        uint256 loanCashBefore = IERC20View2(address(usdg)).balanceOf(eTokenLoan);

        // 用户自带 1000 USDG,借 2000 WETH + 1000 USDG → 两腿各 2000,抵押 4000,债 3000 ≤ 3200 健康
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);

        (, uint128 liq,,, uint256 dRisk, uint256 dLoan) = vault.positions(id);
        assertGt(liq, 0, "LP minted");
        (uint256 riskDebt,) = lending.getCurrentDebt(dRisk);
        (uint256 loanDebt,) = lending.getCurrentDebt(dLoan);
        assertApproxEqAbs(riskDebt, 2_000e18, 1e3, "WETH debt recorded (open dust auto-repays wei)");
        assertApproxEqAbs(loanDebt, 1_000e18, 1e3, "USDG debt recorded");
        // 借款离开各自 eToken 金库
        assertApproxEqAbs(riskCashBefore - IERC20View2(address(weth)).balanceOf(eTokenRisk), 2_000e18, 1e3, "WETH lent out");
        assertApproxEqAbs(loanCashBefore - IERC20View2(address(usdg)).balanceOf(eTokenLoan), 1_000e18, 1e3, "USDG lent out");
        // 零 swap
        assertEq(swap.calls(), 0, "open must not swap");
        // 金库不滞留
        assertEq(IERC20View2(address(weth)).balanceOf(address(vault)), 0, "no WETH stranded");
        assertEq(IERC20View2(address(usdg)).balanceOf(address(vault)), 0, "no USDG stranded");
        assertEq(vault.ownerOf(id), user, "receipt to user");
    }

    /// 健康度按双债合并计价:借太多必须 UNHEALTHY_OPEN。
    function test_open_unhealthy_dual_reverts() public {
        // 探针:同规模(两腿各2000)开一次拿到实际 liq,回滚后把 posVal 校准成 4000
        uint256 snap = vm.snapshotState();
        uint256 probe = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liq,,,,) = vault.positions(probe);
        vm.revertToState(snap);
        oracle.setValPerLiq((4_000e18 * 1e18) / liq); // 抵押=4000

        // 债 2000(WETH)+1600(USDG)=3600 > 4000×0.8=3200 → 不健康
        usdg.mint(user, 400e18);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(UniV4DualVault.UnhealthyOpen.selector);
        vault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: 400e18, borrowRisk: 2_000e18, borrowLoan: 1_600e18,
            tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    /// RISK 价格波动改变健康度(riskValueInLoan 参与合并计价)。
    function test_health_tracks_risk_price() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18); // 债 3000
        (, uint128 liq,,,,) = vault.positions(id);
        oracle.setValPerLiq((4_000e18 * 1e18) / liq); // 抵押校准为 4000 → 健康线 3200
        assertTrue(vault.isHealthy(id), "healthy at 1:1 (debt 3000 <= 3200)");
        // WETH 涨到 1.4:WETH 债折 USDG = 2800,总债 3800 > 3200 → 不健康
        oracle.setRiskPrice(1.4e18);
        assertFalse(vault.isHealthy(id), "unhealthy after risk price up");
    }

    // ─────────── close(缺口结算)───────────
    function _close(uint256 id, uint16 pct, uint256 maxIn) internal returns (uint256 oR, uint256 oL) {
        vm.prank(user);
        (oR, oL) = vault.close(id, UniV4DualVault.CloseParams({
            percent: pct, topUpRisk: 0, topUpLoan: 0, maxSwapIn: maxIn,
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        }));
    }

    /// 价没动:匹配还债即清零,零 swap,用户拿回本金级 USDG。
    function test_close_flat_matchedRepay_zeroSwap() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);
        uint256 uUsdgBefore = usdg.balanceOf(user);

        (uint256 oR, uint256 oL) = _close(id, 10000, 0);

        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertLe(rDebt, 1_000, "WETH debt cleared (dust-level residual ok)");
        assertLe(lDebt, 1_000, "USDG debt cleared (dust-level residual ok)");
        assertEq(swap.calls(), 0, "flat close needs no swap");
        assertApproxEqAbs(usdg.balanceOf(user) - uUsdgBefore, 1_000e18, 5, "user got ~invest back");
        assertEq(vault.ownerOf(id), address(0), "receipt burned");
        assertEq(weth.balanceOf(address(vault)), 0, "no WETH stranded");
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG stranded");
        emit log_named_uint("outRisk", oR); emit log_named_uint("outLoan", oL);
    }

    /// 价涨:LP 漂成 USDG 多 WETH 少 → WETH 腿短缺,用 USDG 盈余 exactOutput 买缺口。
    function test_close_priceUp_buysGap() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);

        pm.setSqrtP(TickMath.getSqrtRatioAtTick(500));  // 价格 +5.1%
        swap.setRate(1.0513e18);
        oracle.setRiskPrice(1.0513e18);

        _close(id, 10000, type(uint256).max);

        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertEq(rDebt, 0, "WETH debt cleared via gap buy");
        assertEq(lDebt, 0, "USDG debt cleared");
        assertEq(swap.calls(), 1, "exactly one gap swap");
        assertTrue(swap.lastWasExactOutput(), "gap must use exactOutput primary path, not degrade");
        assertEq(vault.ownerOf(id), address(0), "receipt burned");
    }

    /// 深水下:盈余不够补缺口 → 降级 exactInput 全换,部分覆盖,残债记坏账,不 revert。
    function test_close_deepUnderwater_degrades_badDebt() public {
        uint256 id = _open(0, 800e18, 2_000e18, 1_200e18); // 债 3200 = 上限
        (,,,, , uint256 dL) = vault.positions(id);

        pm.setSqrtP(TickMath.getSqrtRatioAtTick(-8000)); // 崩 55%:LP 全变 WETH
        swap.setRate(0.4493e18);
        oracle.setRiskPrice(0.4493e18);
        (, uint128 liqD,,,,) = vault.positions(id);
        oracle.setValPerLiq((1_500e18 * 1e18) / liqD); // 预言机作证:posVal 1500 < 债务~2100 → 真资不抵债

        vm.expectEmit(true, true, false, false);
        emit UniV4DualVault.BadDebt(id, dL, 0);
        _close(id, 10000, type(uint256).max);

        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertGt(lDebt, 0, "USDG residual bad debt remains");
        (,,,, uint256 dR,) = vault.positions(id);
        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        assertEq(rDebt, 0, "WETH debt fully repaid from WETH-heavy LP");
        assertEq(vault.ownerOf(id), address(0), "receipt burned even under water");
    }

    /// 部分平仓:健康时按比例减两债;不健康时被末尾健康闸拦下。
    function test_close_partial_healthGate() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liq0,,, uint256 dR, uint256 dL) = vault.positions(id);

        _close(id, 5000, type(uint256).max); // 健康,50% 平掉
        (, uint128 liq1,,,,) = vault.positions(id);
        assertApproxEqAbs(liq1, liq0 / 2, 1, "half liquidity removed");
        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertApproxEqAbs(rDebt, 1_000e18, 5, "half WETH debt");
        assertApproxEqAbs(lDebt, 500e18, 5, "half USDG debt");
        assertEq(vault.ownerOf(id), user, "receipt intact");

        // 弄不健康 → 部分平仓被健康闸拦
        oracle.setValPerLiq(1); // 公允价≈0
        vm.prank(user);
        vm.expectRevert(UniV4DualVault.UnhealthyAfterClose.selector);
        vault.close(id, UniV4DualVault.CloseParams({
            percent: 1000, topUpRisk: 0, topUpLoan: 0, maxSwapIn: type(uint256).max,
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        }));
    }


    // ─────────── addMargin(补保证金)───────────
    /// 单侧 WETH:只还 WETH 腿,封顶债务,超出不拉款。
    function test_addMargin_singleRisk_capped() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR,) = vault.positions(id);
        address payer = makeAddr("payer"); // 第三方代还
        weth.mint(payer, 5_000e18);
        vm.startPrank(payer);
        weth.approve(address(vault), type(uint256).max);
        vault.addMargin(id, 5_000e18, 0); // 超过债务 2000
        vm.stopPrank();
        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        assertEq(rDebt, 0, "WETH debt fully repaid");
        assertApproxEqAbs(weth.balanceOf(payer), 3_000e18, 1e3, "excess never pulled (wei drift from open dust-repay)");
    }

    /// 双侧:各还各腿;不健康仓可补且补后转健康。
    function test_addMargin_dual_cures_unhealthy() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liq,,, uint256 dR, uint256 dL) = vault.positions(id);
        oracle.setValPerLiq((3_500e18 * 1e18) / liq); // 抵押 3500,债 3000 > 2800 → 不健康
        assertFalse(vault.isHealthy(id), "unhealthy before margin");

        weth.mint(user, 500e18); usdg.mint(user, 300e18);
        vm.startPrank(user);
        vault.addMargin(id, 500e18, 300e18); // 债 → 1500W + 700U = 2200 < 2800
        vm.stopPrank();
        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertApproxEqAbs(rDebt, 1_500e18, 1e3); assertApproxEqAbs(lDebt, 700e18, 1e3);
        assertTrue(vault.isHealthy(id), "cured by margin");
    }

    function test_pause_allows_addMargin() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR,) = vault.positions(id);
        lending.emergencyPauseAll();

        weth.mint(user, 500e18);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        vault.addMargin(id, 500e18, 0);
        vm.stopPrank();

        (uint256 riskDebt,) = lending.getCurrentDebt(dR);
        assertApproxEqAbs(riskDebt, 1_500e18, 1e3, "paused margin reduced debt");
    }

    // ─────────── rebalance(换区间,债务不动)───────────
    function _rebalance(uint256 id, int24 tl, int24 tu, int256 amt) internal {
        vm.prank(user);
        vault.rebalance(id, UniV4DualVault.RebalanceParams({
            newTickLower: tl, newTickUpper: tu, swapAmount: amt,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
    }

    /// 平价缩窄区间:swapAmount=0,债务两腿恒等,ticks/liquidity 更新。
    function test_rebalance_narrower_zeroDelta_debtsUnchanged() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);
        (uint256 rBefore,) = lending.getCurrentDebt(dR);
        (uint256 lBefore,) = lending.getCurrentDebt(dL);

        _rebalance(id, -500, 500, 0);

        (, uint128 liq, int24 tl, int24 tu,,) = vault.positions(id);
        assertEq(tl, -500); assertEq(tu, 500);
        assertGt(liq, 0, "re-minted in new range");
        (uint256 rAfter,) = lending.getCurrentDebt(dR);
        (uint256 lAfter,) = lending.getCurrentDebt(dL);
        assertEq(rAfter, rBefore, "risk debt untouched");
        assertEq(lAfter, lBefore, "loan debt untouched");
        assertEq(swap.calls(), 0, "zero delta = no swap");
        assertEq(vault.ownerOf(id), user, "receipt intact");
    }

    /// 带 delta 的再平衡:价格移动后重居中,只换一笔净额,债务仍不动。
    function test_rebalance_withDelta_afterPriceMove() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);
        (uint256 rBefore,) = lending.getCurrentDebt(dR);

        pm.setSqrtP(TickMath.getSqrtRatioAtTick(500));
        swap.setRate(1.0513e18); oracle.setRiskPrice(1.0513e18);
        sv.setSlot0(TickMath.getSqrtRatioAtTick(500), 500);

        // 重居中到 ±1000 around 500;撤出偏 USDG,卖 300 USDG 换回 WETH 大致平衡(剩余零头退还)
        _rebalance(id, -500, 1500, -300e18);

        (, uint128 liq, int24 tl, int24 tu,,) = vault.positions(id);
        assertEq(tl, -500); assertEq(tu, 1500);
        assertGt(liq, 0);
        (uint256 rAfter,) = lending.getCurrentDebt(dR);
        assertEq(rAfter, rBefore, "debt unchanged through delta rebalance");
        assertEq(swap.calls(), 1, "exactly one delta swap");
    }

    /// 不健康仓不许换区间(防绕清算)。
    function test_rebalance_unhealthy_reverts() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liq,,,,) = vault.positions(id);
        liq; // silence
        oracle.setValPerLiq(1); // 公允价≈0 → 无论换到哪个区间都不健康
        vm.prank(user);
        vm.expectRevert(UniV4DualVault.UnhealthyAfterRebalance.selector);
        vault.rebalance(id, UniV4DualVault.RebalanceParams({
            newTickLower: -500, newTickUpper: 500, swapAmount: 0,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
    }

    /// 非持有人不得 rebalance。
    function test_rebalance_nonHolder_reverts() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(UniV4DualVault.NotHolder.selector);
        vault.rebalance(id, UniV4DualVault.RebalanceParams({
            newTickLower: -500, newTickUpper: 500, swapAmount: 0,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
    }


    /// 用户自带缺口币平仓:previewClose 告知缺口,topUp 补齐 → 完全跳过 swap(KousanS 方案)。
    function test_close_withTopUp_skipsSwap() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);

        pm.setSqrtP(TickMath.getSqrtRatioAtTick(500)); // 价涨 → WETH 腿将短缺
        sv.setSlot0(TickMath.getSqrtRatioAtTick(500), 500);
        swap.setRate(1.0513e18); oracle.setRiskPrice(1.0513e18);

        (,, uint256 dueR,, uint256 shortR, uint256 shortL) = vault.previewClose(id, 10000);
        assertGt(shortR, 0, "preview shows WETH shortfall");
        assertEq(shortL, 0, "no USDG shortfall");
        assertLe(dueR, 2_000e18 + 1, "due sanity");

        weth.mint(user, shortR); // 用户按预估带上缺口 WETH
        vm.startPrank(user);
        vault.close(id, UniV4DualVault.CloseParams({
            percent: 10000, topUpRisk: shortR, topUpLoan: 0, maxSwapIn: 0, // maxSwapIn=0:明确拒绝 swap
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertLe(rDebt, 1_000, "WETH debt cleared via top-up");
        assertLe(lDebt, 1_000, "USDG debt cleared");
        assertEq(swap.calls(), 0, "top-up close = zero swap");
    }

    /// topUp 超过缺口:只拉需要的部分。
    function test_close_topUp_excess_notPulled() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        pm.setSqrtP(TickMath.getSqrtRatioAtTick(500));
        sv.setSlot0(TickMath.getSqrtRatioAtTick(500), 500);
        swap.setRate(1.0513e18); oracle.setRiskPrice(1.0513e18);
        (,,,, uint256 shortR,) = _preview5(id);

        weth.mint(user, shortR + 100e18);
        uint256 balBefore = weth.balanceOf(user);
        vm.startPrank(user);
        vault.close(id, UniV4DualVault.CloseParams({
            percent: 10000, topUpRisk: shortR + 100e18, topUpLoan: 0, maxSwapIn: 0,
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        // 只被拉走 ~shortR(容忍取整尘埃),多余 100 WETH 留在钱包
        assertApproxEqAbs(balBefore - weth.balanceOf(user), shortR, 1_000, "only shortfall pulled");
        assertEq(swap.calls(), 0, "no swap");
    }
    function _preview5(uint256 id) internal view returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 shortR, uint256 shortL) {
        (a, b, c, d, shortR, shortL) = vault.previewClose(id, 10000);
    }


    // ─────────── liquidate(双资产清算)───────────
    function _mkUnhealthy() internal returns (uint256 id) {
        id = _open(0, 1_000e18, 2_000e18, 1_000e18); // 债 2000W+1000U
        (, uint128 liq,,,,) = vault.positions(id);
        oracle.setValPerLiq((3_500e18 * 1e18) / liq); // 抵押 3500,债 3000 > 2800 → 不健康
    }
    function _liq(address kp, uint256 id, uint256 ratio) internal returns (bool fc) {
        vm.startPrank(kp);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        fc = vault.liquidate(id, UniV4DualVault.LiquidateParams({
            ratioBps: ratio, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    /// 基础:按比例同时还两腿,keeper 垫两币、拿两币 in-kind,协议费两腿按比例进金库。
    function test_liquidate_dual_proportional() public {
        uint256 id = _mkUnhealthy();
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);
        address kp = makeAddr("kp");
        vm.prank(gov); vault.setLiquidator(kp, true);
        weth.mint(kp, 10_000e18); usdg.mint(kp, 10_000e18);
        uint256 kW = weth.balanceOf(kp); uint256 kU = usdg.balanceOf(kp);
        uint256 gW = weth.balanceOf(gov); uint256 gU = usdg.balanceOf(gov);

        _liq(kp, id, 5000); // k=closeFactor 50%

        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        // 至少还掉 k 比例(超额回冲可能还得更多)
        assertLe(rDebt, 1_000e18, "risk debt at most half");
        assertLe(lDebt, 500e18, "loan debt at most half");
        // keeper 净值(WETH@1:1)不得超过应得 bonus:repayValue=2000×50%×1+1000×50%=1500;
        // bonus=1500×8%=120;协议抽 10% → 应得净赚 ≤108(+尘)
        int256 kNet = int256(weth.balanceOf(kp)) - int256(kW) + int256(usdg.balanceOf(kp)) - int256(kU);
        assertLe(kNet, int256(108e18) + 1e15, "keeper net capped at entitled bonus");
        assertGt(kNet, 0, "keeper profitable (healthy-margin scenario)");
        // 协议费到账(两腿合计>0)
        assertGt(weth.balanceOf(gov) - gW + usdg.balanceOf(gov) - gU, 0, "protocol fee paid");
        assertEq(weth.balanceOf(address(vault)), 0, "no WETH stranded");
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG stranded");
    }

    function test_pause_allows_liquidation() public {
        uint256 id = _mkUnhealthy();
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);
        address kp = makeAddr("pausedKeeper");
        vm.prank(gov); vault.setLiquidator(kp, true);
        weth.mint(kp, 10_000e18); usdg.mint(kp, 10_000e18);
        lending.emergencyPauseAll();

        _liq(kp, id, 5000);

        (uint256 riskDebt,) = lending.getCurrentDebt(dR);
        (uint256 loanDebt,) = lending.getCurrentDebt(dL);
        assertLt(riskDebt, 2_000e18, "paused liquidation reduced risk debt");
        assertLt(loanDebt, 1_000e18, "paused liquidation reduced loan debt");
    }

    /// F2 双资产版:预言机低估 posVal → 超额扣押被封顶,超出部分回冲债务。
    function test_liquidate_dual_F2_cap() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liq,,, uint256 dR, uint256 dL) = vault.positions(id);
        oracle.setValPerLiq((3_000e18 * 1e18) / liq); // 低估:实际两腿可撤~4000,报 3000 → 不健康且低估
        address kp = makeAddr("kp2");
        vm.prank(gov); vault.setLiquidator(kp, true);
        weth.mint(kp, 10_000e18); usdg.mint(kp, 10_000e18);
        uint256 kW = weth.balanceOf(kp); uint256 kU = usdg.balanceOf(kp);

        _liq(kp, id, 5000);

        int256 kNet = int256(weth.balanceOf(kp)) - int256(kW) + int256(usdg.balanceOf(kp)) - int256(kU);
        // 应得:repayValue 1500 → bonus 120 → 净 108;低估导致实际扣得多,但封顶后 keeper 只拿应得
        assertLe(kNet, int256(108e18) + 1e15, "F2 cap holds under oracle understatement");
        // 超额回冲:债务减得比 50% 更多
        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertLt(rDebt + lDebt, 1_500e18, "excess seizure repaid extra debt");
    }

    /// 守卫:非白名单/健康仓不可清算。
    function test_liquidate_dual_guards() public {
        uint256 id = _open(0, 1_000e18, 2_000e18, 1_000e18); // 默认 oracle 值巨大 → 健康
        address kp = makeAddr("kp3");
        vm.prank(kp);
        vm.expectRevert(UniV4DualVault.NotLiquidator.selector);
        vault.liquidate(id, UniV4DualVault.LiquidateParams({ratioBps: 5000, minSeizeValue: 0, deadline: block.timestamp + 1}));
        vm.prank(gov); vault.setLiquidator(kp, true);
        vm.prank(kp);
        vm.expectRevert(UniV4DualVault.Healthy.selector);
        vault.liquidate(id, UniV4DualVault.LiquidateParams({ratioBps: 5000, minSeizeValue: 0, deadline: block.timestamp + 1}));
    }

    /// 单腿零债:addMargin 清掉 WETH 腿后清算,keeper 只需垫 USDG。
    function test_liquidate_dual_zeroRiskLeg() public {
        uint256 id = _mkUnhealthy();
        (,,,, uint256 dR, uint256 dL) = vault.positions(id);
        // 第三方先把 WETH 腿还清(仍不健康?债 1000,抵押 3500×0.8=2800 → 健康了!需重新压)
        address helper = makeAddr("helper");
        weth.mint(helper, 2_000e18);
        vm.startPrank(helper); weth.approve(address(vault), type(uint256).max);
        vault.addMargin(id, 2_000e18, 0);
        vm.stopPrank();
        (, uint128 liq,,,,) = vault.positions(id);
        oracle.setValPerLiq((1_100e18 * 1e18) / liq); // 压到 1100:债 1000 > 880 → 不健康
        address kp = makeAddr("kp4");
        vm.prank(gov); vault.setLiquidator(kp, true);
        usdg.mint(kp, 5_000e18);
        uint256 kW = weth.balanceOf(kp);

        _liq(kp, id, 5000);

        (uint256 rDebt,) = lending.getCurrentDebt(dR);
        assertEq(rDebt, 0, "risk leg stays zero");
        (uint256 lDebt,) = lending.getCurrentDebt(dL);
        assertLe(lDebt, 500e18, "loan leg halved");
        // keeper 没被拉 WETH(垫付纯 USDG;拿到的 seize 可以含 WETH)
        assertGe(weth.balanceOf(kp), kW, "keeper paid no WETH");
    }

}
