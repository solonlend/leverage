// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {UniV3LeverageVault} from "../src/UniV3LeverageVault.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {
    MockERC20 as V4Token,
    MockOracle as V4Oracle,
    MockStateView,
    MockV4PositionManager,
    MockSwapExecutor
} from "./V4VaultFlow.integration.t.sol";
import {
    MockERC20 as V3Token,
    MockOracle as V3Oracle,
    MockPool as V3Pool,
    MockV3PM,
    MockSwap as V3Swap
} from "./VaultFlow.integration.t.sol";

interface ITestToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// Test seam for the production LendingPool behavior where repay may settle less than requested.
contract CappedRepayLendingPool {
    uint256 public nextId = 1;
    mapping(uint256 => address) public reserveToken;
    mapping(uint256 => uint256) public reserveOfDebt;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => uint256) public repayCap;
    mapping(uint256 => bool) public capEnabled;

    function setReserve(uint256 reserveId, address token) external { reserveToken[reserveId] = token; }
    function setRepayCap(uint256 debtId, uint256 cap) external { repayCap[debtId] = cap; capEnabled[debtId] = true; }
    function getUnderlyingTokenAddress(uint256 reserveId) external view returns (address) { return reserveToken[reserveId]; }
    function newDebtPosition(uint256 reserveId) external returns (uint256 id) {
        id = nextId++;
        reserveOfDebt[id] = reserveId;
    }
    function borrow(address onBehalfOf, uint256 debtId, uint256 amount) external {
        debt[debtId] += amount;
        ITestToken(reserveToken[reserveOfDebt[debtId]]).transfer(onBehalfOf, amount);
    }
    function repay(address, uint256 debtId, uint256 amount) external returns (uint256 actual) {
        actual = amount > debt[debtId] ? debt[debtId] : amount;
        if (capEnabled[debtId] && actual > repayCap[debtId]) actual = repayCap[debtId];
        if (actual > 0) {
            ITestToken(reserveToken[reserveOfDebt[debtId]]).transferFrom(msg.sender, address(this), actual);
            debt[debtId] -= actual;
        }
    }
    function getCurrentDebt(uint256 debtId) external view returns (uint256, uint256) { return (debt[debtId], 1e18); }
}

abstract contract ActualRepayAssertions is Test {
    bytes32 internal constant SINGLE_LIQUIDATED =
        keccak256("PositionLiquidated(uint256,address,uint256,uint256,uint256,bool)");
    bytes32 internal constant DUAL_LIQUIDATED =
        keccak256("PositionLiquidated(uint256,address,uint256,uint256,uint256,uint256,bool)");

    function _settlement(uint256 actualValue)
        internal pure returns (uint256 seizeValue, uint256 keeperValue, uint256 feeValue)
    {
        seizeValue = (actualValue * 10_800) / 10_000;
        feeValue = ((seizeValue - actualValue) * 1_000) / 10_000;
        keeperValue = seizeValue - feeValue;
    }

    function _assertSingleEvent(address emitter, uint256 actual, uint256 keeperCap, uint256 feeCap) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == SINGLE_LIQUIDATED) {
                (uint256 repaid, uint256 seized, uint256 fee,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                assertEq(repaid, actual, "event must report actual repay");
                assertLe(seized, keeperCap, "keeper reward must use actual repay");
                assertLe(fee, feeCap, "protocol fee must use actual repay");
                return;
            }
        }
        fail("missing PositionLiquidated event");
    }

    function _assertDualEvent(
        address emitter, uint256 actualRisk, uint256 actualLoan, uint256 keeperCap, uint256 feeCap
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == DUAL_LIQUIDATED) {
                (uint256 repaidRisk, uint256 repaidLoan, uint256 seized, uint256 fee,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bool));
                assertEq(repaidRisk, actualRisk, "event risk repay must be actual");
                assertEq(repaidLoan, actualLoan, "event loan repay must be actual");
                assertLe(seized, keeperCap, "keeper reward must use actual repay value");
                assertLe(fee, feeCap, "protocol fee must use actual repay value");
                return;
            }
        }
        fail("missing PositionLiquidated event");
    }
}

contract UniV4ActualRepayTest is ActualRepayAssertions {
    V4Token risk;
    V4Token loan;
    V4Oracle oracle;
    MockV4PositionManager pm;
    MockSwapExecutor swap;
    MockStateView stateView;
    CappedRepayLendingPool lending;
    UniV4LeverageVault vault;
    address keeper = makeAddr("v4-single-keeper");
    address governor = makeAddr("v4-single-governor");

    function setUp() public {
        V4Token a = new V4Token();
        V4Token b = new V4Token();
        (risk, loan) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        oracle = new V4Oracle();
        pm = new MockV4PositionManager(risk, loan, sqrtP);
        swap = new MockSwapExecutor(risk, loan, 1e18);
        stateView = new MockStateView(sqrtP, 0);
        lending = new CappedRepayLendingPool();
        lending.setReserve(1, address(loan));
        loan.mint(address(lending), 1_000e18);
        risk.mint(address(swap), 1_000e18);
        loan.mint(address(swap), 1_000e18);
        loan.mint(keeper, 1_000e18);
        vault = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: governor, positionManager: address(pm), stateView: address(stateView),
            lendingPool: address(lending), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(risk), token1: address(loan), loanIsC0: false,
            fee: 3_000, tickSpacing: 60, hooks: address(0), minWidthTicks: 100,
            liqBonusBps: 800, protocolFeeBps: 1_000, harvestFeeBps: 1_000,
            borrowFeeBps: 0, closeFactorBps: 5_000, lltv: 0.8e18
        }));
        vm.prank(governor);
        vault.setLiquidator(keeper, true);
    }

    function _openUnhealthy() internal returns (uint256 id, uint128 liquidity, uint256 debtId) {
        id = vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 0, amountBorrow: 100e18, tickLower: -1_000, tickUpper: 1_000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        (, liquidity,,, debtId) = vault.positions(id);
        oracle.setValPerLiq((lending.debt(debtId) * 1e18) / liquidity);
    }

    function test_partialRepay_sizes_seizure_and_reward_from_actual() public {
        (uint256 id, uint128 liquidity, uint256 debtId) = _openUnhealthy();
        uint256 actual = 20e18;
        lending.setRepayCap(debtId, actual);
        uint256 posValue = vault.positionValue(id);
        (uint256 seizeValue, uint256 keeperCap, uint256 feeCap) = _settlement(actual);
        uint128 expectedSeized = uint128((uint256(liquidity) * seizeValue) / posValue);

        vm.recordLogs();
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        (, uint128 liquidityAfter,,,) = vault.positions(id);
        assertEq(liquidity - liquidityAfter, expectedSeized, "LP seizure must use actual repay");
        _assertSingleEvent(address(vault), actual, keeperCap, feeCap);
        assertEq(loan.balanceOf(address(vault)), 0, "declared-minus-actual must be refunded");
    }

    function test_zeroActualRepay_cannot_seize_collateral() public {
        (uint256 id, uint128 liquidity, uint256 debtId) = _openUnhealthy();
        lending.setRepayCap(debtId, 0);
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("ZERO_REPAY"));
        vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liquidityAfter,,,) = vault.positions(id);
        assertEq(liquidityAfter, liquidity);
    }
}

contract UniV3ActualRepayTest is ActualRepayAssertions {
    V3Token risk;
    V3Token loan;
    V3Oracle oracle;
    MockV3PM pm;
    V3Swap swap;
    V3Pool poolState;
    CappedRepayLendingPool lending;
    UniV3LeverageVault vault;
    address keeper = makeAddr("v3-single-keeper");
    address governor = makeAddr("v3-single-governor");

    function setUp() public {
        V3Token a = new V3Token();
        V3Token b = new V3Token();
        (risk, loan) = address(a) < address(b) ? (a, b) : (b, a);
        oracle = new V3Oracle();
        pm = new MockV3PM(risk, loan);
        swap = new V3Swap(risk, loan, 1e18);
        poolState = new V3Pool();
        lending = new CappedRepayLendingPool();
        lending.setReserve(1, address(loan));
        loan.mint(address(lending), 1_000e18);
        risk.mint(address(swap), 1_000e18);
        loan.mint(address(swap), 1_000e18);
        loan.mint(keeper, 1_000e18);
        vault = new UniV3LeverageVault(UniV3LeverageVault.InitParams({
            governor: governor, positionManager: address(pm), pool: address(poolState),
            lendingPool: address(lending), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(risk), token1: address(loan), loanIsC0: false, fee: 3_000,
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1_000, harvestFeeBps: 1_000,
            borrowFeeBps: 0, closeFactorBps: 5_000, lltv: 0.8e18
        }));
        vm.prank(governor);
        vault.setLiquidator(keeper, true);
    }

    function _openUnhealthy() internal returns (uint256 id, uint128 liquidity, uint256 debtId) {
        id = vault.open(UniV3LeverageVault.OpenParams({
            amountInvest: 0, amountBorrow: 100e18, tickLower: -1_000, tickUpper: 1_000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        (, liquidity,,, debtId) = vault.positions(id);
        oracle.setValPerLiq((lending.debt(debtId) * 1e18) / liquidity);
    }

    function test_partialRepay_sizes_seizure_and_reward_from_actual() public {
        (uint256 id, uint128 liquidity, uint256 debtId) = _openUnhealthy();
        uint256 actual = 20e18;
        lending.setRepayCap(debtId, actual);
        uint256 posValue = vault.positionValue(id);
        (uint256 seizeValue, uint256 keeperCap, uint256 feeCap) = _settlement(actual);
        uint128 expectedSeized = uint128((uint256(liquidity) * seizeValue) / posValue);

        vm.recordLogs();
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        vault.liquidate(id, UniV3LeverageVault.LiquidateParams({
            repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        (, uint128 liquidityAfter,,,) = vault.positions(id);
        assertEq(liquidity - liquidityAfter, expectedSeized, "LP seizure must use actual repay");
        _assertSingleEvent(address(vault), actual, keeperCap, feeCap);
        assertEq(loan.balanceOf(address(vault)), 0, "declared-minus-actual must be refunded");
    }

    function test_zeroActualRepay_cannot_seize_collateral() public {
        (uint256 id, uint128 liquidity, uint256 debtId) = _openUnhealthy();
        lending.setRepayCap(debtId, 0);
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("ZERO_REPAY"));
        vault.liquidate(id, UniV3LeverageVault.LiquidateParams({
            repayAmount: 60e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liquidityAfter,,,) = vault.positions(id);
        assertEq(liquidityAfter, liquidity);
    }
}

contract UniV4DualActualRepayTest is ActualRepayAssertions {
    V4Token risk;
    V4Token loan;
    V4Oracle oracle;
    MockV4PositionManager pm;
    MockSwapExecutor swap;
    MockStateView stateView;
    CappedRepayLendingPool lending;
    UniV4DualVault vault;
    address keeper = makeAddr("v4-dual-keeper");
    address governor = makeAddr("v4-dual-governor");

    function setUp() public {
        V4Token a = new V4Token();
        V4Token b = new V4Token();
        (risk, loan) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        oracle = new V4Oracle();
        pm = new MockV4PositionManager(risk, loan, sqrtP);
        swap = new MockSwapExecutor(risk, loan, 1e18);
        stateView = new MockStateView(sqrtP, 0);
        lending = new CappedRepayLendingPool();
        lending.setReserve(1, address(risk));
        lending.setReserve(2, address(loan));
        risk.mint(address(lending), 1_000e18);
        loan.mint(address(lending), 1_000e18);
        risk.mint(keeper, 1_000e18);
        loan.mint(keeper, 1_000e18);
        vault = new UniV4DualVault(UniV4DualVault.InitParams({
            governor: governor, positionManager: address(pm), stateView: address(stateView),
            lendingPool: address(lending), reserveRisk: 1, reserveLoan: 2,
            oracle: address(oracle), swapExecutor: address(swap),
            token0: address(risk), token1: address(loan), loanIsC0: false,
            fee: 3_000, tickSpacing: 60, hooks: address(0), minWidthTicks: 100,
            liqBonusBps: 800, protocolFeeBps: 1_000, harvestFeeBps: 1_000,
            closeFactorBps: 5_000, lltv: 0.8e18
        }));
        vm.prank(governor);
        vault.setLiquidator(keeper, true);
    }

    function _openUnhealthy()
        internal returns (uint256 id, uint128 liquidity, uint256 debtRisk, uint256 debtLoan)
    {
        id = vault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: 0, borrowRisk: 100e18, borrowLoan: 100e18,
            tickLower: -1_000, tickUpper: 1_000, amount0Max: type(uint128).max,
            amount1Max: type(uint128).max, minLiquidity: 0, deadline: block.timestamp + 1
        }));
        (, liquidity,,, debtRisk, debtLoan) = vault.positions(id);
        uint256 debtValue = lending.debt(debtRisk) + lending.debt(debtLoan);
        oracle.setValPerLiq((debtValue * 1e18) / liquidity);
    }

    function test_partialRepay_sizes_seizure_and_reward_from_actual() public {
        (uint256 id, uint128 liquidity, uint256 debtRisk, uint256 debtLoan) = _openUnhealthy();
        uint256 actualRisk = 10e18;
        uint256 actualLoan = 20e18;
        lending.setRepayCap(debtRisk, actualRisk);
        lending.setRepayCap(debtLoan, actualLoan);
        uint256 posValue = vault.positionValue(id);
        (uint256 seizeValue, uint256 keeperCap, uint256 feeCap) = _settlement(actualRisk + actualLoan);
        uint128 expectedSeized = uint128((uint256(liquidity) * seizeValue) / posValue);

        vm.recordLogs();
        vm.startPrank(keeper);
        risk.approve(address(vault), type(uint256).max);
        loan.approve(address(vault), type(uint256).max);
        vault.liquidate(id, UniV4DualVault.LiquidateParams({
            ratioBps: 5_000, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertEq(liquidity - liquidityAfter, expectedSeized, "LP seizure must use actual repay value");
        _assertDualEvent(address(vault), actualRisk, actualLoan, keeperCap, feeCap);
        assertEq(risk.balanceOf(address(vault)), 0);
        assertEq(loan.balanceOf(address(vault)), 0);
    }

    function test_zeroActualRepay_cannot_seize_collateral() public {
        (uint256 id, uint128 liquidity, uint256 debtRisk, uint256 debtLoan) = _openUnhealthy();
        lending.setRepayCap(debtRisk, 0);
        lending.setRepayCap(debtLoan, 0);
        vm.startPrank(keeper);
        risk.approve(address(vault), type(uint256).max);
        loan.approve(address(vault), type(uint256).max);
        vm.expectRevert(UniV4DualVault.DustLiq.selector);
        vault.liquidate(id, UniV4DualVault.LiquidateParams({
            ratioBps: 5_000, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertEq(liquidityAfter, liquidity);
    }
}

contract UniV3DualActualRepayTest is ActualRepayAssertions {
    V3Token risk;
    V3Token loan;
    V3Oracle oracle;
    MockV3PM pm;
    V3Swap swap;
    V3Pool poolState;
    CappedRepayLendingPool lending;
    UniV3DualVault vault;
    address keeper = makeAddr("v3-dual-keeper");
    address governor = makeAddr("v3-dual-governor");

    function setUp() public {
        V3Token a = new V3Token();
        V3Token b = new V3Token();
        (risk, loan) = address(a) < address(b) ? (a, b) : (b, a);
        oracle = new V3Oracle();
        pm = new MockV3PM(risk, loan);
        swap = new V3Swap(risk, loan, 1e18);
        poolState = new V3Pool();
        lending = new CappedRepayLendingPool();
        lending.setReserve(1, address(risk));
        lending.setReserve(2, address(loan));
        risk.mint(address(lending), 1_000e18);
        loan.mint(address(lending), 1_000e18);
        risk.mint(keeper, 1_000e18);
        loan.mint(keeper, 1_000e18);
        vault = new UniV3DualVault(UniV3DualVault.InitParams({
            governor: governor, positionManager: address(pm), pool: address(poolState),
            lendingPool: address(lending), reserveRisk: 1, reserveLoan: 2,
            oracle: address(oracle), swapExecutor: address(swap), token0: address(risk), token1: address(loan),
            loanIsC0: false, fee: 3_000, minWidthTicks: 100, liqBonusBps: 800,
            protocolFeeBps: 1_000, harvestFeeBps: 1_000, closeFactorBps: 5_000, lltv: 0.8e18
        }));
        vm.prank(governor);
        vault.setLiquidator(keeper, true);
    }

    function _openUnhealthy()
        internal returns (uint256 id, uint128 liquidity, uint256 debtRisk, uint256 debtLoan)
    {
        id = vault.open(UniV3DualVault.OpenParams({
            investRisk: 0, investLoan: 0, borrowRisk: 100e18, borrowLoan: 100e18,
            tickLower: -1_000, tickUpper: 1_000, amount0Min: 0, amount1Min: 0,
            minLiquidity: 0, deadline: block.timestamp + 1
        }));
        (, liquidity,,, debtRisk, debtLoan) = vault.positions(id);
        uint256 debtValue = lending.debt(debtRisk) + lending.debt(debtLoan);
        oracle.setValPerLiq((debtValue * 1e18) / liquidity);
    }

    function test_partialRepay_sizes_seizure_and_reward_from_actual() public {
        (uint256 id, uint128 liquidity, uint256 debtRisk, uint256 debtLoan) = _openUnhealthy();
        uint256 actualRisk = 10e18;
        uint256 actualLoan = 20e18;
        lending.setRepayCap(debtRisk, actualRisk);
        lending.setRepayCap(debtLoan, actualLoan);
        uint256 posValue = vault.positionValue(id);
        (uint256 seizeValue, uint256 keeperCap, uint256 feeCap) = _settlement(actualRisk + actualLoan);
        uint128 expectedSeized = uint128((uint256(liquidity) * seizeValue) / posValue);

        vm.recordLogs();
        vm.startPrank(keeper);
        risk.approve(address(vault), type(uint256).max);
        loan.approve(address(vault), type(uint256).max);
        vault.liquidate(id, UniV3DualVault.LiquidateParams({
            ratioBps: 5_000, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertEq(liquidity - liquidityAfter, expectedSeized, "LP seizure must use actual repay value");
        _assertDualEvent(address(vault), actualRisk, actualLoan, keeperCap, feeCap);
        assertEq(risk.balanceOf(address(vault)), 0);
        assertEq(loan.balanceOf(address(vault)), 0);
    }

    function test_zeroActualRepay_cannot_seize_collateral() public {
        (uint256 id, uint128 liquidity, uint256 debtRisk, uint256 debtLoan) = _openUnhealthy();
        lending.setRepayCap(debtRisk, 0);
        lending.setRepayCap(debtLoan, 0);
        vm.startPrank(keeper);
        risk.approve(address(vault), type(uint256).max);
        loan.approve(address(vault), type(uint256).max);
        vm.expectRevert(UniV3DualVault.DustLiq.selector);
        vault.liquidate(id, UniV3DualVault.LiquidateParams({
            ratioBps: 5_000, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertEq(liquidityAfter, liquidity);
    }
}
