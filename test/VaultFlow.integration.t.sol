// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniV3LeverageVault} from "../src/UniV3LeverageVault.sol";

/// V3 vault integration test — same money-flow invariants as the V4 test, over the V3 DEX layer
/// (direct NonfungiblePositionManager calls). Proves the V3 vault reached feature parity for ETH/USDG.

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _m(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _m(f, to, a); return true;
    }
    function _m(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "BAL"); balanceOf[f] -= a; balanceOf[to] += a; }
}

contract MockLendingPool {
    MockERC20 public usdg; uint256 public nextId = 1;
    mapping(uint256 => uint256) public debt;
    constructor(MockERC20 u) { usdg = u; }
    function newDebtPosition(uint256) external returns (uint256 id) { id = nextId++; }
    function borrow(address o, uint256 d, uint256 a) external { debt[d] += a; usdg.transfer(o, a); }
    function repay(address, uint256 d, uint256 a) external returns (uint256) {
        if (a > debt[d]) a = debt[d]; usdg.transferFrom(msg.sender, address(this), a); debt[d] -= a; return a;
    }
    function getCurrentDebt(uint256 d) external view returns (uint256, uint256) { return (debt[d], 1e18); }
    function accrueDebt(uint256 d, uint256 a) external { debt[d] += a; }
}

contract MockSwap {
    MockERC20 t0; MockERC20 t1; uint256 public rate;
    constructor(MockERC20 a, MockERC20 b, uint256 r) { t0 = a; t1 = b; rate = r; }
    function setRate(uint256 r) external { rate = r; }
    function swapExactInput(address ti, address to, uint256 ain, uint256 mo, bytes calldata) external returns (uint256 ao) {
        MockERC20(ti).transferFrom(msg.sender, address(this), ain);
        ao = ti == address(t0) ? (ain * rate) / 1e18 : (ain * 1e18) / rate;
        require(ao >= mo, "MINOUT"); MockERC20(to).transfer(msg.sender, ao);
    }
}

contract MockOracle {
    uint256 public valPerLiq = 2e18;
    uint256 public riskPrice = 1e18;
    bool public fail;
    function setValPerLiq(uint256 v) external { valPerLiq = v; }
    function setFail(bool v) external { fail = v; }
    function fairValueInLoan(uint128 l, int24, int24) external view returns (uint256) {
        require(!fail, "ORACLE_DOWN");
        return (uint256(l) * valPerLiq) / 1e18;
    }
    function riskValueInLoan(uint256 amount) external view returns (uint256) {
        require(!fail, "ORACLE_DOWN");
        return (amount * riskPrice) / 1e18;
    }
    function zapAmountToToken0(uint256 t, int24, int24) external pure returns (uint256) { return t / 2; }
}

contract MockPool {
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, 0, 0, 0, false); // tick 0 (straddled by any [-x, x])
    }
}

/// V3 NonfungiblePositionManager mock: amount-based mint, proportional withdrawal, fee accrual.
contract MockV3PM {
    MockERC20 t0; MockERC20 t1;
    uint256 public nextId = 1;
    mapping(uint256 => uint128) public liqOf;
    mapping(uint256 => uint256) public bal0; mapping(uint256 => uint256) public bal1;
    mapping(uint256 => uint256) public fee0; mapping(uint256 => uint256) public fee1;
    bool public zeroRiskOnWithdraw;
    constructor(MockERC20 a, MockERC20 b) { t0 = a; t1 = b; }
    function setZeroRiskOnWithdraw(bool v) external { zeroRiskOnWithdraw = v; }
    function accrueFees(uint256 id, uint256 f0, uint256 f1) external { fee0[id] += f0; fee1[id] += f1; t0.mint(address(this), f0); t1.mint(address(this), f1); }

    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }
    function mint(MintParams calldata p) external returns (uint256 id, uint128 liq, uint256 a0, uint256 a1) {
        t0.transferFrom(msg.sender, address(this), p.amount0Desired);
        t1.transferFrom(msg.sender, address(this), p.amount1Desired);
        id = nextId++; liq = uint128(p.amount0Desired + p.amount1Desired);
        liqOf[id] = liq; bal0[id] = p.amount0Desired; bal1[id] = p.amount1Desired;
        return (id, liq, p.amount0Desired, p.amount1Desired);
    }
    struct IncreaseParamsV3 { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function increaseLiquidity(IncreaseParamsV3 calldata p) external returns (uint128 liq, uint256 a0, uint256 a1) {
        t0.transferFrom(msg.sender, address(this), p.amount0Desired);
        t1.transferFrom(msg.sender, address(this), p.amount1Desired);
        liq = uint128(p.amount0Desired + p.amount1Desired);
        liqOf[p.tokenId] += liq; bal0[p.tokenId] += p.amount0Desired; bal1[p.tokenId] += p.amount1Desired;
        return (liq, p.amount0Desired, p.amount1Desired);
    }
    uint256 st0; uint256 st1;
    struct DecP { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function decreaseLiquidity(DecP calldata p) external returns (uint256, uint256) {
        uint128 L = liqOf[p.tokenId]; uint256 g0 = (bal0[p.tokenId] * p.liquidity) / L; uint256 g1 = (bal1[p.tokenId] * p.liquidity) / L;
        if (zeroRiskOnWithdraw) g0 = 0;
        liqOf[p.tokenId] = L - p.liquidity; bal0[p.tokenId] -= g0; bal1[p.tokenId] -= g1; st0 = g0; st1 = g1; return (g0, g1);
    }
    struct ColP { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(ColP calldata p) external returns (uint256 a0, uint256 a1) {
        uint256 id = p.tokenId;
        a0 = st0 + fee0[id]; a1 = st1 + fee1[id]; st0 = 0; st1 = 0; fee0[id] = 0; fee1[id] = 0;
        if (a0 > 0) t0.transfer(p.recipient, a0); if (a1 > 0) t1.transfer(p.recipient, a1);
    }
    function burn(uint256) external {}
}

contract V3VaultFlowTest is Test {
    MockERC20 t0; MockERC20 usdg;
    MockLendingPool pool; MockV3PM pm; MockSwap swap; MockOracle oracle; MockPool poolState;
    UniV3LeverageVault vault;
    address user = makeAddr("user"); address keeper = makeAddr("keeper"); address gov = makeAddr("gov");

    function setUp() public {
        MockERC20 a = new MockERC20(); MockERC20 b = new MockERC20();
        (t0, usdg) = address(a) < address(b) ? (a, b) : (b, a); // risk(t0) < loan(usdg) → loanIsC0=false
        pool = new MockLendingPool(usdg);
        pm = new MockV3PM(t0, usdg);
        swap = new MockSwap(t0, usdg, 1e18);
        oracle = new MockOracle();
        poolState = new MockPool();
        vault = new UniV3LeverageVault(UniV3LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), pool: address(poolState),
            lendingPool: address(pool), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000,
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));
        usdg.mint(user, 1000e18); usdg.mint(keeper, 1000e18);
        usdg.mint(address(pool), 1e24); usdg.mint(address(swap), 1e24); t0.mint(address(swap), 1e24);
        vm.prank(gov); vault.setLiquidator(keeper, true);
    }

    function _open(uint256 inv, uint256 bor) internal returns (uint256 id) {
        vm.startPrank(user); usdg.approve(address(vault), type(uint256).max);
        id = vault.open(UniV3LeverageVault.OpenParams({
            amountInvest: inv, amountBorrow: bor, tickLower: -1000, tickUpper: 1000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function _newVaultWithLimits(
        int24 minWidth, uint256 bonus, uint256 protocolFee, uint256 harvestFee,
        uint256 closeFactor, uint256 lltv
    ) internal returns (UniV3LeverageVault) {
        return new UniV3LeverageVault(UniV3LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), pool: address(poolState),
            lendingPool: address(pool), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000,
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
        vault.open(UniV3LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 0, tickLower: -1000, tickUpper: 1000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_parity_close_swap_enforces_oracle_minOut() public {
        uint256 id = _open(100e18, 100e18);
        swap.setRate(0.94e18);
        vm.prank(user);
        vm.expectRevert(bytes("MINOUT"));
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_parity_partial_close_rounds_repay_up() public {
        uint256 id = _open(100e18, 100e18 + 1);
        (,,,, uint256 debtId) = vault.positions(id);
        uint256 beforeDebt = pool.debt(debtId);
        uint256 expectedRepay = (beforeDebt * 5000 + 9999) / 10000;
        vm.prank(user);
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 5000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
        assertEq(pool.debt(debtId), beforeDebt - expectedRepay, "partial repay must round up like Dual");
    }

    function test_parity_partial_close_reverts_if_unhealthy_after() public {
        uint256 id = _open(100e18, 100e18);
        oracle.setValPerLiq(1);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("UnhealthyAfterClose()")));
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 1000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_parity_full_close_solvent_residual_reverts() public {
        uint256 id = _open(0, 100e18);
        (,,,, uint256 debtId) = vault.positions(id);
        pool.accrueDebt(debtId, 50e18);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("SolventBadDebt()")));
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_parity_full_close_dust_residual_ignored() public {
        uint256 id = _open(0, 100e18);
        (,,,, uint256 debtId) = vault.positions(id);
        pool.accrueDebt(debtId, 500);
        vm.recordLogs();
        vm.prank(user);
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 badDebtSig = keccak256("BadDebt(uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != badDebtSig, "dust must not emit BadDebt");
        }
        assertEq(pool.debt(debtId), 500, "dust residual remains below GAP_EPS");
    }

    function test_parity_oracle_failure_cannot_authorize_residual() public {
        uint256 id = _open(0, 100e18);
        pm.setZeroRiskOnWithdraw(true);
        oracle.setFail(true);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("SolventBadDebt()")));
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
    }

    function test_open_records() public {
        uint256 id = _open(100e18, 100e18);
        assertEq(vault.ownerOf(id), user);
        (, uint128 liq,,, uint256 debtId) = vault.positions(id);
        assertEq(pool.debt(debtId), 100e18); assertGt(liq, 0);
    }

    function test_close_full_repays_and_burns() public {
        uint256 id = _open(100e18, 100e18);
        (,,,, uint256 debtId) = vault.positions(id);
        vm.prank(user);
        uint256 out = vault.close(id, UniV3LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
        assertEq(pool.debt(debtId), 0); assertEq(vault.ownerOf(id), address(0)); assertGe(out, 99e18);
    }

    function test_harvest_withdraw_skims_fee() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v3Id,,,,) = vault.positions(id);
        pm.accrueFees(v3Id, 10e18, 10e18);
        uint256 g0 = t0.balanceOf(gov); uint256 g1 = usdg.balanceOf(gov);
        vm.prank(user);
        (uint256 f0, uint256 f1) = vault.harvest(id, false, "", block.timestamp + 1);
        assertEq(f0, 9e18); assertEq(f1, 9e18); // 90% to user
        assertEq(t0.balanceOf(gov) - g0, 1e18); assertEq(usdg.balanceOf(gov) - g1, 1e18); // 10% to treasury
    }

    function test_increase_grows() public {
        uint256 id = _open(100e18, 100e18);
        (, uint128 lb,,, uint256 debtId) = vault.positions(id);
        vm.prank(user);
        vault.increase(id, UniV3LeverageVault.IncreaseParams({amountInvest: 50e18, amountBorrow: 50e18, amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1}));
        (, uint128 la,,,) = vault.positions(id);
        assertGt(la, lb); assertEq(pool.debt(debtId), 150e18);
    }

    function test_liquidate_and_healthy_guard() public {
        uint256 id = _open(100e18, 100e18);
        vm.startPrank(keeper); usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(UniV3LeverageVault.Healthy.selector);
        vault.liquidate(id, UniV3LeverageVault.LiquidateParams({repayAmount: 10e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1}));
        vm.stopPrank();
        (, uint128 liq,,, uint256 debtId) = vault.positions(id);
        oracle.setValPerLiq((100e18 * 1e18) / liq); // unhealthy
        uint256 gb = usdg.balanceOf(gov);
        vm.prank(keeper);
        vault.liquidate(id, UniV3LeverageVault.LiquidateParams({repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1}));
        assertLe(pool.debt(debtId), 50e18); assertGt(usdg.balanceOf(gov), gb); // 超额扣押回冲债务(F2 修复)→ ≤50
    }

    // ── 事件契约(与 V4 金库同一套)──
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event PositionOpened(uint256 indexed id, address indexed owner, uint256 invest, uint256 borrowed, uint256 debtId, uint128 liquidity, int24 tickLower, int24 tickUpper);
    event PositionIncreased(uint256 indexed id, uint256 invest, uint256 borrowed, uint128 liquidityAdded);
    event PositionClosed(uint256 indexed id, uint16 percentBps, uint256 repaid, uint256 outToUser, bool full);
    event Harvested(uint256 indexed id, uint256 netFee0, uint256 netFee1, bool compounded);
    event PositionLiquidated(uint256 indexed id, address indexed keeper, uint256 repaid, uint256 seized, uint256 protocolFee, bool fullyClosed);

    function test_events_open_close_liquidate() public {
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), user, 1);
        vm.expectEmit(true, true, false, false);
        emit PositionOpened(1, user, 0, 0, 0, 0, 0, 0);
        uint256 id = vault.open(UniV3LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectEmit(true, false, false, false);
        emit PositionIncreased(id, 0, 0, 0);
        vault.increase(id, UniV3LeverageVault.IncreaseParams({amountInvest: 50e18, amountBorrow: 50e18, amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1}));
        vm.stopPrank();

        (, uint128 liq,,,) = vault.positions(id);
        oracle.setValPerLiq((150e18 * 1e18) / liq); // unhealthy
        vm.startPrank(keeper);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectEmit(true, true, false, false);
        emit PositionLiquidated(id, keeper, 0, 0, 0, false);
        vault.liquidate(id, UniV3LeverageVault.LiquidateParams({repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1}));
        vm.stopPrank();

        vm.expectEmit(true, true, true, false);
        emit Transfer(user, address(0), id);
        vm.expectEmit(true, false, false, false);
        emit PositionClosed(id, 0, 0, 0, false);
        vm.prank(user);
        vault.close(id, UniV3LeverageVault.CloseParams({percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1}));
        assertEq(vault.nextPositionId(), 2);
    }

    function test_events_harvest_emitsNetFees() public {
        uint256 id = _open(100e18, 100e18);
        (uint256 v3Id,,,,) = vault.positions(id);
        pm.accrueFees(v3Id, 10e18, 10e18);
        vm.expectEmit(true, false, false, true);
        emit Harvested(id, 9e18, 9e18, false);
        vm.prank(user);
        vault.harvest(id, false, "", block.timestamp + 1);
    }

    /// 开仓/加仓必须落在健康区(与 V4 同一条红线)
    function test_open_increase_revert_when_unhealthy() public {
        uint256 id = _open(100e18, 100e18); // 先正常开一个,给 increase 用
        oracle.setValPerLiq(1);
        vm.startPrank(user);
        vm.expectRevert(bytes("UNHEALTHY_OPEN"));
        vault.open(UniV3LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.expectRevert(bytes("UNHEALTHY_INCREASE"));
        vault.increase(id, UniV3LeverageVault.IncreaseParams({
            amountInvest: 1e18, amountBorrow: 100e18, amount0Min: 0, amount1Min: 0, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_rejects_non_straddling() public {
        vm.startPrank(user); usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("NOT_STRADDLING"));
        vault.open(UniV3LeverageVault.OpenParams({amountInvest: 100e18, amountBorrow: 100e18, tickLower: 200, tickUpper: 1000, amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1}));
        vm.stopPrank();
    }
}
