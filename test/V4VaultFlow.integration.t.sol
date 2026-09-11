// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {Currency, PoolKey} from "../src/v4/V4Periphery.sol";

/// V4 integration test. The mock PositionManager DECODES the action-encoded modifyLiquidities payload,
/// which also validates our V4Encode packing (mint/increase/decrease/collect/burn). Verifies the same
/// money-flow invariants as the V3 test, over the V4 DEX layer.

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _move(f, to, a); return true;
    }
    function _move(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "BAL"); balanceOf[f] -= a; balanceOf[to] += a; }
}

contract MockLendingPool {
    MockERC20 public usdg; uint256 public nextId = 1;
    mapping(uint256 => uint256) public debt;
    constructor(MockERC20 u) { usdg = u; }
    function newDebtPosition(uint256) external returns (uint256 id) { id = nextId++; }
    function borrow(address onBehalfOf, uint256 debtId, uint256 amount) external { debt[debtId] += amount; usdg.transfer(onBehalfOf, amount); }
    function repay(address, uint256 debtId, uint256 amount) external returns (uint256) {
        if (amount > debt[debtId]) amount = debt[debtId];
        usdg.transferFrom(msg.sender, address(this), amount); debt[debtId] -= amount; return amount;
    }
    function getCurrentDebt(uint256 debtId) external view returns (uint256, uint256) { return (debt[debtId], 1e18); }
    function accrueDebt(uint256 debtId, uint256 amount) external { debt[debtId] += amount; }
}

contract MockSwapExecutor {
    MockERC20 t0; MockERC20 t1; uint256 public rate; // t1 per t0, 1e18
    constructor(MockERC20 a, MockERC20 b, uint256 r) { t0 = a; t1 = b; rate = r; }
    function setRate(uint256 r) external { rate = r; }
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external returns (uint256 amountOut)
    {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = tokenIn == address(t0) ? (amountIn * rate) / 1e18 : (amountIn * 1e18) / rate;
        require(amountOut >= minOut, "MINOUT");
        MockERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

contract MockOracle {
    uint256 public valPerLiq = 2e18; // healthy default
    uint256 public riskPrice = 1e18;
    bool public fail;
    function setValPerLiq(uint256 v) external { valPerLiq = v; }
    function setRiskPrice(uint256 v) external { riskPrice = v; }
    function setFail(bool v) external { fail = v; }
    function fairValueInLoan(uint128 liquidity, int24, int24) external view returns (uint256) {
        require(!fail, "ORACLE_DOWN");
        return (uint256(liquidity) * valPerLiq) / 1e18;
    }
    function riskValueInLoan(uint256 amount) external view returns (uint256) {
        require(!fail, "ORACLE_DOWN");
        return (amount * riskPrice) / 1e18;
    }
    function zapAmountToToken0(uint256 total, int24, int24) external pure returns (uint256) { return total / 2; }
}

contract MockStateView {
    uint160 public sqrtP;
    int24 public tick;
    constructor(uint160 s, int24 t) { sqrtP = s; tick = t; }
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) { return (sqrtP, tick, 0, 0); }
}

/// Decodes the V4 action-encoded batch and simulates the position manager.
contract MockV4PositionManager {
    MockERC20 t0; MockERC20 t1; uint160 sqrtP;
    uint256 public nextTokenId = 1;
    mapping(uint256 => uint128) public liqOf;
    mapping(uint256 => uint256) public bal0;
    mapping(uint256 => uint256) public bal1;
    mapping(uint256 => int24) public tlOf;
    mapping(uint256 => int24) public tuOf;
    mapping(uint256 => uint256) public pendingFee0;
    mapping(uint256 => uint256) public pendingFee1;
    bool public zeroRiskOnWithdraw;
    uint256 owed0; uint256 owed1; uint256 credit0; uint256 credit1;

    constructor(MockERC20 a, MockERC20 b, uint160 s) { t0 = a; t1 = b; sqrtP = s; }
    function setZeroRiskOnWithdraw(bool v) external { zeroRiskOnWithdraw = v; }
    function accrueFees(uint256 tokenId, uint256 f0, uint256 f1) external {
        pendingFee0[tokenId] += f0; pendingFee1[tokenId] += f1;
        t0.mint(address(this), f0); t1.mint(address(this), f1); // fund the PM to pay the fees out
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        owed0 = 0; owed1 = 0; credit0 = 0; credit1 = 0;
        for (uint256 i = 0; i < actions.length; i++) {
            uint8 a = uint8(actions[i]);
            if (a == 0x02) _mint(params[i]);
            else if (a == 0x00) _increase(params[i]);
            else if (a == 0x01) _decrease(params[i]);
            else if (a == 0x03) _burn(params[i]);
            else if (a == 0x0d) _settlePair();
            else if (a == 0x11) _takePair(params[i]);
            else revert("BAD_ACTION");
        }
    }

    function _amounts(int24 tl, int24 tu, uint128 L) internal view returns (uint256 a0, uint256 a1) {
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), L);
    }

    function _mint(bytes memory p) internal {
        (, int24 tl, int24 tu, uint256 L, , , , ) =
            abi.decode(p, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        uint256 id = nextTokenId++;
        (uint256 a0, uint256 a1) = _amounts(tl, tu, uint128(L));
        liqOf[id] = uint128(L); tlOf[id] = tl; tuOf[id] = tu; bal0[id] += a0; bal1[id] += a1;
        owed0 += a0; owed1 += a1;
    }
    function _increase(bytes memory p) internal {
        (uint256 id, uint256 L, , ) = abi.decode(p, (uint256, uint256, uint128, uint128));
        // note: real params also carry hookData; decode the leading fields we need
        (uint256 a0, uint256 a1) = _amounts(tlOf[id], tuOf[id], uint128(L));
        liqOf[id] += uint128(L); bal0[id] += a0; bal1[id] += a1; owed0 += a0; owed1 += a1;
    }
    function _decrease(bytes memory p) internal {
        (uint256 id, uint256 L, , ) = abi.decode(p, (uint256, uint256, uint128, uint128));
        if (L > 0) {
            uint256 g0 = (bal0[id] * L) / liqOf[id];
            uint256 g1 = (bal1[id] * L) / liqOf[id];
            if (zeroRiskOnWithdraw) g0 = 0;
            liqOf[id] -= uint128(L); bal0[id] -= g0; bal1[id] -= g1; credit0 += g0; credit1 += g1;
        }
        // fees credited on any decrease (incl. liquidity=0 collect)
        credit0 += pendingFee0[id]; credit1 += pendingFee1[id];
        pendingFee0[id] = 0; pendingFee1[id] = 0;
    }
    function _burn(bytes memory p) internal {
        (uint256 id, , ) = abi.decode(p, (uint256, uint128, uint128));
        credit0 += (zeroRiskOnWithdraw ? 0 : bal0[id]) + pendingFee0[id]; credit1 += bal1[id] + pendingFee1[id];
        liqOf[id] = 0; bal0[id] = 0; bal1[id] = 0; pendingFee0[id] = 0; pendingFee1[id] = 0;
    }
    function _settlePair() internal {
        if (owed0 > 0) t0.transferFrom(msg.sender, address(this), owed0);
        if (owed1 > 0) t1.transferFrom(msg.sender, address(this), owed1);
        owed0 = 0; owed1 = 0;
    }
    function _takePair(bytes memory p) internal {
        (, , address recipient) = abi.decode(p, (Currency, Currency, address));
        if (credit0 > 0) t0.transfer(recipient, credit0);
        if (credit1 > 0) t1.transfer(recipient, credit1);
        credit0 = 0; credit1 = 0;
    }

    function getPositionLiquidity(uint256 id) external view returns (uint128) { return liqOf[id]; }
    function getPoolAndPositionInfo(uint256) external pure returns (PoolKey memory k, uint256) { return (k, 0); }
}

contract V4VaultFlowTest is Test {
    MockERC20 t0; MockERC20 usdg;
    MockLendingPool pool; MockV4PositionManager pm; MockSwapExecutor swap; MockOracle oracle; MockStateView sv;
    UniV4LeverageVault vault;
    uint160 sqrtP0;

    address user = makeAddr("user");
    address keeper = makeAddr("keeper");
    address gov = makeAddr("gov");

    function setUp() public {
        sqrtP0 = TickMath.getSqrtRatioAtTick(0); // price 1:1 at tick 0
        // order so risk(t0) < loan(usdg) → currency0=t0(risk), currency1=usdg(loan), loanIsC0=false
        MockERC20 a = new MockERC20(); MockERC20 b = new MockERC20();
        (t0, usdg) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new MockLendingPool(usdg);
        pm = new MockV4PositionManager(t0, usdg, sqrtP0);
        swap = new MockSwapExecutor(t0, usdg, 1e18); // 1:1 to match tick-0 price
        oracle = new MockOracle();
        sv = new MockStateView(sqrtP0, 0);

        vault = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), stateView: address(sv),
            lendingPool: address(pool), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));

        usdg.mint(user, 1000e18);
        usdg.mint(keeper, 1000e18);
        usdg.mint(address(pool), 1_000_000e18);
        usdg.mint(address(swap), 1_000_000e18);
        t0.mint(address(swap), 1_000_000e18);

        vm.prank(gov);
        vault.setLiquidator(keeper, true);
    }

    function _open(uint256 invest, uint256 borrow) internal returns (uint256 id) {
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        id = vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: invest, amountBorrow: borrow, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function _newVaultWithLimits(
        int24 minWidth, uint256 bonus, uint256 protocolFee, uint256 harvestFee,
        uint256 closeFactor, uint256 lltv
    ) internal returns (UniV4LeverageVault) {
        return new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), stateView: address(sv),
            lendingPool: address(pool), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false,
            fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: minWidth, liqBonusBps: bonus, protocolFeeBps: protocolFee, harvestFeeBps: harvestFee,
            borrowFeeBps: 0, closeFactorBps: closeFactor, lltv: lltv
        }));
    }

    function test_parity_constructor_rejects_dual_invalid_bounds() public {
        vm.expectRevert(bytes("BAD_LLTV")); _newVaultWithLimits(100, 800, 1000, 1000, 5000, 0);
        vm.expectRevert(bytes("BAD_LLTV")); _newVaultWithLimits(100, 800, 1000, 1000, 5000, 1e18 + 1);
        vm.expectRevert(bytes("BAD_CLOSE_FACTOR")); _newVaultWithLimits(100, 800, 1000, 1000, 0, 0.8e18);
        vm.expectRevert(bytes("BAD_CLOSE_FACTOR")); _newVaultWithLimits(100, 800, 1000, 1000, 10001, 0.8e18);
        vm.expectRevert(bytes("BAD_FEES")); _newVaultWithLimits(100, 2001, 1000, 1000, 5000, 0.8e18);
        vm.expectRevert(bytes("BAD_FEES")); _newVaultWithLimits(100, 800, 5001, 1000, 5000, 0.8e18);
        vm.expectRevert(bytes("BAD_FEES")); _newVaultWithLimits(100, 800, 1000, 3001, 5000, 0.8e18);
        vm.expectRevert(bytes("BAD_MIN_WIDTH")); _newVaultWithLimits(0, 800, 1000, 1000, 5000, 0.8e18);
    }

    function test_parity_open_swap_enforces_oracle_minOut() public {
        swap.setRate(2e18);
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("MINOUT"));
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 0, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_parity_close_swap_enforces_oracle_minOut() public {
        uint256 id = _open(100e18, 100e18);
        swap.setRate(0.94e18);
        vm.prank(user);
        vm.expectRevert(bytes("MINOUT"));
        vault.close(id, UniV4LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_parity_partial_close_rounds_repay_up() public {
        uint256 id = _open(100e18, 100e18 + 1);
        (,,,, uint256 debtId) = vault.positions(id);
        uint256 beforeDebt = pool.debt(debtId);
        uint256 expectedRepay = (beforeDebt * 5000 + 9999) / 10000;
        vm.prank(user);
        vault.close(id, UniV4LeverageVault.CloseParams({percent: 5000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
        assertEq(pool.debt(debtId), beforeDebt - expectedRepay, "partial repay must round up like Dual");
    }

    function test_parity_partial_close_reverts_if_unhealthy_after() public {
        uint256 id = _open(100e18, 100e18);
        oracle.setValPerLiq(1);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("UnhealthyAfterClose()")));
        vault.close(id, UniV4LeverageVault.CloseParams({percent: 1000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_parity_full_close_solvent_residual_reverts() public {
        uint256 id = _open(0, 100e18);
        (,,,, uint256 debtId) = vault.positions(id);
        pool.accrueDebt(debtId, 50e18);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("SolventBadDebt()")));
        vault.close(id, UniV4LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_parity_full_close_dust_residual_ignored() public {
        uint256 id = _open(0, 100e18);
        (,,,, uint256 debtId) = vault.positions(id);
        pool.accrueDebt(debtId, 500);
        vm.recordLogs();
        vm.prank(user);
        vault.close(id, UniV4LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 badDebtSig = keccak256("BadDebt(uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != badDebtSig, "dust must not emit BadDebt");
        }
        uint256 residual = pool.debt(debtId);
        assertGt(residual, 0, "rounding dust remains");
        assertLe(residual, 1000, "residual stays within GAP_EPS");
    }

    function test_parity_oracle_failure_cannot_authorize_residual() public {
        uint256 id = _open(0, 100e18);
        pm.setZeroRiskOnWithdraw(true);
        oracle.setFail(true);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("SolventBadDebt()")));
        vault.close(id, UniV4LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_open_mints_v4_position_and_records_debt() public {
        uint256 id = _open(100e18, 100e18);
        assertEq(vault.ownerOf(id), user, "Solon NFT to user");
        (uint256 v4Id, uint128 liq,,, uint256 debtId) = vault.positions(id);
        assertEq(pool.debt(debtId), 100e18, "debt recorded");
        assertGt(liq, 0, "liquidity minted");
        assertEq(pm.liqOf(v4Id), liq, "V4 position liquidity matches");
    }

    function test_close_full_repays_and_burns() public {
        uint256 id = _open(100e18, 100e18);
        (, , , , uint256 debtId) = vault.positions(id);
        uint256 userBefore = usdg.balanceOf(user);
        vm.prank(user);
        uint256 out = vault.close(id, UniV4LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        assertEq(pool.debt(debtId), 0, "debt cleared");
        assertEq(vault.ownerOf(id), address(0), "Solon NFT burned");
        assertGe(out, 99e18, "user got ~principal back (breakeven, minor rounding)");
        assertEq(usdg.balanceOf(user), userBefore + out, "user paid out");
    }

    function test_harvest_withdraw_pays_fees_to_user() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v4Id,,,,) = vault.positions(id);
        pm.accrueFees(v4Id, 5e18, 7e18); // fees accrue in the position
        uint256 u0 = t0.balanceOf(user); uint256 u1 = usdg.balanceOf(user);
        uint256 g0 = t0.balanceOf(gov); uint256 g1 = usdg.balanceOf(gov);

        vm.prank(user);
        (uint256 f0, uint256 f1) = vault.harvest(id, false, "", block.timestamp + 1);
        // 10% harvest fee to treasury, 90% to user
        assertEq(f0, 4.5e18, "user gets 90% fee0"); assertEq(f1, 6.3e18, "user gets 90% fee1");
        assertEq(t0.balanceOf(user) - u0, 4.5e18, "token0 net fees to user");
        assertEq(usdg.balanceOf(user) - u1, 6.3e18, "USDG net fees to user");
        assertEq(t0.balanceOf(gov) - g0, 0.5e18, "10% token0 fee to treasury");
        assertEq(usdg.balanceOf(gov) - g1, 0.7e18, "10% USDG fee to treasury");
    }

    function test_close_also_skims_fee_cut_on_accrued() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v4Id,,,,) = vault.positions(id);
        pm.accrueFees(v4Id, 10e18, 10e18); // fees accrued in the position
        uint256 g0 = t0.balanceOf(gov); uint256 g1 = usdg.balanceOf(gov);
        vm.prank(user);
        vault.close(id, UniV4LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        // even on a plain close (not harvest), the 10% cut on the 10e18 fees each side goes to treasury
        assertEq(t0.balanceOf(gov) - g0, 1e18, "close skims token0 fee cut (no free-ride)");
        assertEq(usdg.balanceOf(gov) - g1, 1e18, "close skims USDG fee cut");
    }

    function test_harvest_compound_grows_liquidity() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v4Id, uint128 liqBefore,,,) = vault.positions(id);
        pm.accrueFees(v4Id, 4e18, 4e18);
        vm.prank(user);
        vault.harvest(id, true, "", block.timestamp + 1);
        (, uint128 liqAfter,,,) = vault.positions(id);
        assertGt(liqAfter, liqBefore, "compound increased liquidity");
    }

    function test_increase_adds_liquidity_and_debt() public {
        uint256 id = _open(100e18, 100e18);
        (, uint128 liqBefore, , , uint256 debtId) = vault.positions(id);
        vm.startPrank(user);
        vault.increase(id, UniV4LeverageVault.IncreaseParams({
            amountInvest: 50e18, amountBorrow: 50e18, amount0Max: type(uint128).max, amount1Max: type(uint128).max,
            minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liqAfter,,,) = vault.positions(id);
        assertGt(liqAfter, liqBefore, "liquidity grew");
        assertEq(pool.debt(debtId), 150e18, "debt grew by borrow");
    }

    function test_liquidate_distributes_and_reverts_when_healthy() public {
        uint256 id = _open(100e18, 100e18);
        // healthy by default (valPerLiq 2e18) → revert
        vm.startPrank(keeper);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(UniV4LeverageVault.Healthy.selector);
        vault.liquidate(id, UniV4LeverageVault.LiquidateParams({repayAmount: 10e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1}));
        vm.stopPrank();

        // drop value → unhealthy (posVal = debt, so posVal*LLTV < debt), then liquidate
        (, uint128 liq,,, uint256 debtId) = vault.positions(id);
        oracle.setValPerLiq((100e18 * 1e18) / liq); // posVal = 100e18 == debt → unhealthy
        uint256 govBefore = usdg.balanceOf(gov);
        vm.startPrank(keeper);
        vault.liquidate(id, UniV4LeverageVault.LiquidateParams({repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1}));
        vm.stopPrank();
        // repay 上限 50;此处 oracle 低估 posVal → 扣押到的超额抵押不归 keeper,而是回冲债务(F2 修复),
        // 所以债务被压到 ≤50(甚至清零),keeper 只拿应得 bonus。
        assertLe(pool.debt(debtId), 50e18, "debt reduced at least by capped repay; excess seizure repays more");
        assertGt(usdg.balanceOf(gov), govBefore, "protocol fee to treasury");
    }

    // ── 事件契约(keeper 索引 / 前端渲染依赖,两个金库同一套)──
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event PositionOpened(uint256 indexed id, address indexed owner, uint256 invest, uint256 borrowed, uint256 debtId, uint128 liquidity, int24 tickLower, int24 tickUpper);
    event PositionIncreased(uint256 indexed id, uint256 invest, uint256 borrowed, uint128 liquidityAdded);
    event PositionClosed(uint256 indexed id, uint16 percentBps, uint256 repaid, uint256 outToUser, bool full);
    event Harvested(uint256 indexed id, uint256 netFee0, uint256 netFee1, bool compounded);
    event PositionLiquidated(uint256 indexed id, address indexed keeper, uint256 repaid, uint256 seized, uint256 protocolFee, bool fullyClosed);

    function test_events_open_emitsTransferAndOpened() public {
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), user, 1);
        vm.expectEmit(true, true, false, false);
        emit PositionOpened(1, user, 0, 0, 0, 0, 0, 0);
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_events_close_full_emitsBurnAndClosed() public {
        uint256 id = _open(100e18, 100e18);
        vm.expectEmit(true, true, true, false);
        emit Transfer(user, address(0), id);
        vm.expectEmit(true, false, false, false);
        emit PositionClosed(id, 0, 0, 0, false);
        vm.prank(user);
        vault.close(id, UniV4LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));
    }

    function test_events_increase_emits() public {
        uint256 id = _open(100e18, 100e18);
        vm.startPrank(user);
        vm.expectEmit(true, false, false, false);
        emit PositionIncreased(id, 0, 0, 0);
        vault.increase(id, UniV4LeverageVault.IncreaseParams({
            amountInvest: 50e18, amountBorrow: 50e18,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    /// 回归:invariant fuzz 抓到 harvest 复投分支漏退零头(open/increase 都有 _refundDust,compound 没有)
    function test_harvest_compound_leaves_no_dust_in_vault() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v4Id,,,,) = vault.positions(id);
        pm.accrueFees(v4Id, 5e18 + 3, 7e18 + 1); // 奇数额,制造取整零头
        vm.prank(user);
        vault.harvest(id, true, "", block.timestamp + 1);
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG dust after compound");
        assertEq(t0.balanceOf(address(vault)), 0, "no risk-token dust after compound");
    }

    function test_events_harvest_emitsNetFees() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v4Id,,,,) = vault.positions(id);
        pm.accrueFees(v4Id, 5e18, 7e18);
        vm.expectEmit(true, false, false, true);
        emit Harvested(id, 4.5e18, 6.3e18, false);
        vm.prank(user);
        vault.harvest(id, false, "", block.timestamp + 1);
    }

    function test_events_liquidate_emits() public {
        uint256 id = _open(100e18, 100e18);
        (, uint128 liq,,,) = vault.positions(id);
        oracle.setValPerLiq((100e18 * 1e18) / liq); // unhealthy
        vm.startPrank(keeper);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectEmit(true, true, false, false);
        emit PositionLiquidated(id, keeper, 0, 0, 0, false);
        vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    /// 开仓必须落在健康区,否则用户可以秒开可清算仓位,把出借人押在 <LLTV 抵押率上
    function test_open_reverts_when_unhealthy() public {
        oracle.setValPerLiq(1); // 公允价≈0 → 任何借款都超 LLTV
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("UNHEALTHY_OPEN"));
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_increase_reverts_when_unhealthy() public {
        uint256 id = _open(100e18, 100e18);
        oracle.setValPerLiq(1);
        vm.startPrank(user);
        vm.expectRevert(bytes("UNHEALTHY_INCREASE"));
        vault.increase(id, UniV4LeverageVault.IncreaseParams({
            amountInvest: 1e18, amountBorrow: 100e18,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_nextPositionId_exposedForKeeperScan() public {
        assertEq(vault.nextPositionId(), 1);
        _open(100e18, 100e18);
        assertEq(vault.nextPositionId(), 2);
    }

    function test_open_rejects_non_straddling_range() public {
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("NOT_STRADDLING"));
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: 200, tickUpper: 1000, // both above current tick 0
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    /// FIX #1 validation: USDG as currency0 (like NVDA/USDG where USDG sorts lower). The whole
    /// borrow/zap/repay/payout must still work with LOAN on the currency0 side.
    function test_ordering_loan_is_currency0() public {
        // deploy tokens ordered so loan(usdg2) < risk2 → USDG is currency0
        MockERC20 x = new MockERC20(); MockERC20 y = new MockERC20();
        (MockERC20 usdg2, MockERC20 risk2) = address(x) < address(y) ? (x, y) : (y, x);

        MockV4PositionManager pm2 = new MockV4PositionManager(usdg2, risk2, sqrtP0); // c0=usdg2, c1=risk2
        MockSwapExecutor swap2 = new MockSwapExecutor(risk2, usdg2, 1e18);            // role: t0=risk, t1=loan
        MockStateView sv2 = new MockStateView(sqrtP0, 0);
        MockOracle oracle2 = new MockOracle();
        MockLendingPool pool2 = new MockLendingPool(usdg2);

        UniV4LeverageVault v = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: gov, positionManager: address(pm2), stateView: address(sv2),
            lendingPool: address(pool2), reserveId: 1, oracle: address(oracle2), swapExecutor: address(swap2),
            token0: address(usdg2), token1: address(risk2), loanIsC0: true, // ← USDG is currency0
            fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));

        usdg2.mint(user, 1000e18); usdg2.mint(address(pool2), 1e24);
        usdg2.mint(address(swap2), 1e24); risk2.mint(address(swap2), 1e24);

        vm.startPrank(user);
        usdg2.approve(address(v), type(uint256).max);
        uint256 id = v.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        (,,,, uint256 debtId) = v.positions(id);
        assertEq(pool2.debt(debtId), 100e18, "borrowed in USDG (currency0)");

        uint256 out = v.close(id, UniV4LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertEq(pool2.debt(debtId), 0, "debt repaid in USDG(c0)");
        assertGe(out, 99e18, "user got USDG back (loan=c0 path works)");
        assertEq(v.ownerOf(id), address(0), "NFT burned");
    }

    function test_borrow_fee_to_treasury() public {
        // dedicated vault with a 1% borrow origination fee
        UniV4LeverageVault v = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), stateView: address(sv),
            lendingPool: address(pool), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 100, closeFactorBps: 5000, lltv: 0.8e18
        }));
        uint256 g1 = usdg.balanceOf(gov);
        vm.startPrank(user);
        usdg.approve(address(v), type(uint256).max);
        v.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        // 1% of the 100e18 borrow = 1e18 origination fee to treasury
        assertEq(usdg.balanceOf(gov) - g1, 1e18, "borrow fee to treasury");
    }
}
