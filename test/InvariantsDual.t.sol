// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {MockERC20} from "./V4VaultFlow.integration.t.sol";
import {NamedMockERC20} from "./LendingPoolIntegration.t.sol";
import {DualMockOracle, CountingSwap, MovablePM, MovableSV} from "./DualVault.t.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

/*
  Dual-Borrow 不变量 fuzz:双储备 × 全动作集(存/取两池、开/平/补/换区间/清算/时间/价格)。
  铁律:
  I1 双储备偿付能力(各自 现金+在外债务 ≥ 名义总额)
  I2 金库不滞留资金
  I3 凭证销毁 ⇒ 流动性归零
  I4 两个 eToken 汇率单调不减
  I5 各储备 totalBorrows ≤ Σ对应腿仓位债务 + 取整容忍
*/

interface IERC20d {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract DualHandler is Test {
    UniV4DualVault public vault;
    LendingPool public lending;
    NamedMockERC20 public weth; NamedMockERC20 public usdg;
    DualMockOracle public oracle; CountingSwap public swapx; MovablePM public pm; MovableSV public sv;
    address public lenderL = address(0xA11); address public lenderR = address(0xA22);
    address public trader = address(0xB33); address public keeper = address(0xC44);

    constructor(
        UniV4DualVault v, LendingPool l, NamedMockERC20 w, NamedMockERC20 u,
        DualMockOracle o, CountingSwap s, MovablePM p, MovableSV svv
    ) {
        vault = v; lending = l; weth = w; usdg = u; oracle = o; swapx = s; pm = p; sv = svv;
        usdg.mint(lenderL, 1e30); weth.mint(lenderR, 1e30);
        usdg.mint(trader, 1e30); weth.mint(trader, 1e30);
        usdg.mint(keeper, 1e30); weth.mint(keeper, 1e30);
        vm.startPrank(lenderL); usdg.approve(address(lending), type(uint256).max); vm.stopPrank();
        vm.startPrank(lenderR); weth.approve(address(lending), type(uint256).max); vm.stopPrank();
        vm.startPrank(trader);
        usdg.approve(address(vault), type(uint256).max); weth.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(keeper);
        usdg.approve(address(vault), type(uint256).max); weth.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function depositLoan(uint256 a) external { a = bound(a, 2000, 1e24); vm.prank(lenderL); lending.deposit(1, a, lenderL, 0); }
    function depositRisk(uint256 a) external { a = bound(a, 2000, 1e24); vm.prank(lenderR); lending.deposit(2, a, lenderR, 0); }
    function redeemLoan(uint256 a) external { _redeem(1, lenderL, a); }
    function redeemRisk(uint256 a) external { _redeem(2, lenderR, a); }
    function _redeem(uint256 rid, address who, uint256 a) internal {
        address e = lending.getETokenAddress(rid);
        uint256 bal = IERC20d(e).balanceOf(who);
        if (bal < 2) return;
        a = bound(a, 1, bal);
        vm.startPrank(who);
        IERC20d(e).approve(address(lending), a);
        try lending.redeem(rid, a, who, false) {} catch {}
        vm.stopPrank();
    }

    function open(uint256 iL, uint256 bR, uint256 bL) external {
        iL = bound(iL, 1e18, 1e22);
        bR = bound(bR, 0, iL * 2);
        bL = bound(bL, 0, iL);
        (, int24 cur,,) = sv.getSlot0(bytes32(0));
        vm.prank(trader);
        try vault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: iL, borrowRisk: bR, borrowLoan: bL,
            tickLower: cur - 1200, tickUpper: cur + 1200,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            deadline: block.timestamp + 1
        })) {} catch {}
    }

    function closePartial(uint256 seed, uint256 pct) external {
        uint256 id = _pick(seed); if (id == 0) return;
        uint16 percent = uint16(bound(pct, 1, 10000));
        vm.prank(trader);
        try vault.close(id, UniV4DualVault.CloseParams({
            percent: percent, topUpRisk: 0, topUpLoan: 0, maxSwapIn: type(uint256).max,
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    function addMargin(uint256 seed, uint256 aR, uint256 aL) external {
        uint256 id = _pick(seed); if (id == 0) return;
        vm.prank(trader);
        try vault.addMargin(id, bound(aR, 0, 1e21), bound(aL, 0, 1e21)) {} catch {}
    }

    function rebalance(uint256 seed, uint256 w) external {
        uint256 id = _pick(seed); if (id == 0) return;
        int24 half = int24(int256(bound(w, 300, 2000)));
        (, int24 cur,,) = sv.getSlot0(bytes32(0));
        vm.prank(trader);
        try vault.rebalance(id, UniV4DualVault.RebalanceParams({
            newTickLower: cur - half, newTickUpper: cur + half, swapAmount: 0,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    function liquidate(uint256 seed, uint256 ratio) external {
        uint256 id = _pick(seed); if (id == 0) return;
        vm.prank(keeper);
        try vault.liquidate(id, UniV4DualVault.LiquidateParams({
            ratioBps: bound(ratio, 1, 10000), minSeizeValue: 0, deadline: block.timestamp + 1
        })) {} catch {}
    }

    function warpTime(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1 hours, 60 days)); }

    /// 连贯动价:PM 池价、StateView、swap 汇率、预言机 riskPrice 同步到同一 tick,
    /// 让缺口结算(exactOutput/降级/坏账)真正参与 fuzz;valPerLiq 独立摆动制造健康度变化。
    function movePrice(int256 tickSeed, uint256 v) external {
        int24 t = int24(bound(tickSeed, -3000, 3000));
        uint160 sp = TickMath.getSqrtRatioAtTick(t);
        pm.setSqrtP(sp);
        sv.setSlot0(sp, t);
        uint256 p1e18 = FullMath.mulDiv(uint256(sp) * uint256(sp), 1e18, 1 << 192);
        if (p1e18 == 0) p1e18 = 1;
        swapx.setRate(p1e18);
        oracle.setRiskPrice(p1e18);
        oracle.setValPerLiq(bound(v, 0.5e18, 4e18));
    }

    /// 带 topUp 的平仓:按 preview 缺口补币,行使"无损赎回"主路径。
    function closeWithTopUp(uint256 seed, uint256 pct) external {
        uint256 id = _pick(seed); if (id == 0) return;
        uint16 percent = uint16(bound(pct, 1, 10000));
        (,,,, uint256 shortR, uint256 shortL) = vault.previewClose(id, percent);
        if (shortR > 0) weth.mint(trader, shortR);
        if (shortL > 0) usdg.mint(trader, shortL);
        vm.prank(trader);
        try vault.close(id, UniV4DualVault.CloseParams({
            percent: percent, topUpRisk: shortR, topUpLoan: shortL, maxSwapIn: type(uint256).max,
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    /// 带小额 delta 的 rebalance。
    function rebalanceDelta(uint256 seed, uint256 w, int256 dAmt) external {
        uint256 id = _pick(seed); if (id == 0) return;
        int24 half = int24(int256(bound(w, 300, 2000)));
        int256 amt = bound(dAmt, -int256(2e20), int256(2e20));
        (, int24 cur,,) = sv.getSlot0(bytes32(0));
        vm.prank(trader);
        try vault.rebalance(id, UniV4DualVault.RebalanceParams({
            newTickLower: cur - half, newTickUpper: cur + half, swapAmount: amt,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        uint256 next = vault.nextPositionId();
        if (next <= 1) return 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 id = (uint256(keccak256(abi.encode(seed, i))) % (next - 1)) + 1;
            if (vault.ownerOf(id) == trader) return id;
        }
        return 0;
    }
}

contract InvariantsDualTest is Test {
    NamedMockERC20 weth; NamedMockERC20 usdg;
    LendingPool lending;
    address eLoan; address eRisk;
    MovablePM pm; CountingSwap swapx; DualMockOracle oracle; MovableSV sv;
    UniV4DualVault vault;
    DualHandler handler;
    uint256 lastRateLoan; uint256 lastRateRisk;

    function setUp() public {
        NamedMockERC20 a = new NamedMockERC20("Wrapped ETH", "WETH");
        NamedMockERC20 b = new NamedMockERC20("USD Global", "USDG");
        (weth, usdg) = address(a) < address(b) ? (a, b) : (b, a);

        AddressRegistry registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        lending = new LendingPool(address(registry), address(weth));
        lending.initReserve(address(usdg)); // 1 = LOAN
        lending.initReserve(address(weth)); // 2 = RISK
        eLoan = lending.getETokenAddress(1);
        eRisk = lending.getETokenAddress(2);
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        uint160 sqrtP0 = TickMath.getSqrtRatioAtTick(0);
        pm = new MovablePM(MockERC20(address(weth)), MockERC20(address(usdg)), sqrtP0);
        swapx = new CountingSwap(MockERC20(address(weth)), MockERC20(address(usdg)));
        oracle = new DualMockOracle();
        sv = new MovableSV(sqrtP0, 0);

        vault = new UniV4DualVault(UniV4DualVault.InitParams({
            governor: makeAddr("gov"), positionManager: address(pm), stateView: address(sv),
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: address(oracle), swapExecutor: address(swapx),
            token0: address(weth), token1: address(usdg), loanIsC0: false,
            fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        lending.setCreditsOfVault(1, 2, type(uint128).max);

        handler = new DualHandler(vault, lending, weth, usdg, oracle, swapx, pm, sv);
        address keeperAddr = handler.keeper();
        vm.prank(makeAddr("gov"));
        vault.setLiquidator(keeperAddr, true);

        // 双储备种子
        address ll = handler.lenderL(); address lr = handler.lenderR();
        vm.prank(ll); lending.deposit(1, 1_000_000e18, ll, 0);
        vm.prank(lr); lending.deposit(2, 1_000_000e18, lr, 0);

        lastRateLoan = lending.exchangeRateOfReserve(1);
        lastRateRisk = lending.exchangeRateOfReserve(2);
        targetContract(address(handler));
    }

    function invariant_I1_dual_reserve_solvency() public view {
        assertGe(
            usdg.balanceOf(eLoan) + lending.totalBorrowsOfReserve(1) + 1,
            lending.totalLiquidityOfReserve(1), "loan reserve solvent"
        );
        assertGe(
            weth.balanceOf(eRisk) + lending.totalBorrowsOfReserve(2) + 1,
            lending.totalLiquidityOfReserve(2), "risk reserve solvent"
        );
    }

    function invariant_I2_vault_holds_nothing() public view {
        assertEq(weth.balanceOf(address(vault)), 0, "no WETH stranded");
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG stranded");
    }

    function invariant_I3_receipt_consistency() public view {
        uint256 next = vault.nextPositionId();
        for (uint256 id = 1; id < next; id++) {
            if (vault.ownerOf(id) == address(0)) {
                (, uint128 liq,,,,) = vault.positions(id);
                assertEq(liq, 0, "burned receipt must have zero liquidity");
            }
        }
    }

    function invariant_I4_exchange_rates_monotonic() public {
        uint256 rl = lending.exchangeRateOfReserve(1);
        uint256 rr = lending.exchangeRateOfReserve(2);
        assertGe(rl + 1, lastRateLoan, "loan eToken rate never decreases");
        assertGe(rr + 1, lastRateRisk, "risk eToken rate never decreases");
        lastRateLoan = rl; lastRateRisk = rr;
    }

    function invariant_I5_debt_accounting_per_reserve() public view {
        uint256 sumR; uint256 sumL;
        uint256 next = vault.nextPositionId();
        for (uint256 id = 1; id < next; id++) {
            (,,,, uint256 dR, uint256 dL) = vault.positions(id);
            if (dR != 0) { (uint256 d,) = lending.getCurrentDebt(dR); sumR += d; }
            if (dL != 0) { (uint256 d,) = lending.getCurrentDebt(dL); sumL += d; }
        }
        assertLe(lending.totalBorrowsOfReserve(2), sumR + next * 10 + 10, "risk totalBorrows bounded by position debts");
        assertLe(lending.totalBorrowsOfReserve(1), sumL + next * 10 + 10, "loan totalBorrows bounded by position debts");
    }
}
