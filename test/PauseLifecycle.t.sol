// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPoolIntegrationFixture, IERC20View, NamedMockERC20} from "./LendingPoolIntegration.t.sol";
import {ExploitDualV3Fixture} from "./ExploitDualV3.t.sol";
import {
    MockERC20 as V3MockERC20,
    MockV3PM,
    MockSwap as V3MockSwap,
    MockOracle as V3MockOracle,
    MockPool as V3MockPool
} from "./VaultFlow.integration.t.sol";
import {MockERC20 as V4MockERC20} from "./V4VaultFlow.integration.t.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {UniV3LeverageVault} from "../src/UniV3LeverageVault.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {DataTypes} from "../src/lending/libraries/types/DataTypes.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";
import {MovablePM, MovableSV, CountingSwap, DualMockOracle} from "./DualVault.t.sol";

contract PauseLifecycleTest is LendingPoolIntegrationFixture {
    function test_pause_blocks_selfFunded_UniV4_increase_and_unpause_restores() public {
        uint256 id = _open(1_000e18, 2_000e18);
        (, uint128 liquidityBefore,,, uint256 debtId) = vault.positions(id);
        (uint256 debtBefore,) = lending.getCurrentDebt(debtId);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV4LeverageVault.IncreaseParams({
                amountInvest: 100e18,
                amountBorrow: 0,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        (, uint128 liquidityPaused,,,) = vault.positions(id);
        (uint256 debtPaused,) = lending.getCurrentDebt(debtId);
        assertEq(liquidityPaused, liquidityBefore, "paused self-funded increase preserves liquidity");
        assertEq(debtPaused, debtBefore, "paused self-funded increase preserves debt");

        lending.unPauseAll();
        vm.prank(user);
        vault.increase(
            id,
            UniV4LeverageVault.IncreaseParams({
                amountInvest: 100e18,
                amountBorrow: 0,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );

        (, uint128 liquidityAfter,,,) = vault.positions(id);
        (uint256 debtAfter,) = lending.getCurrentDebt(debtId);
        assertGt(liquidityAfter, liquidityBefore, "unpause restores self-funded increase");
        assertEq(debtAfter, debtBefore, "self-funded increase leaves debt unchanged");
    }

    function test_pauseLifecycle_blocksGrowth_allowsWindDown_andRestoresConsistently() public {
        uint256 id = _open(1_000e18, 2_000e18);
        (,,,, uint256 debtId) = vault.positions(id);
        (uint256 debtBefore,) = lending.getCurrentDebt(debtId);
        uint256 nextDebtBefore = lending.nextDebtPositionId();

        address blockedDepositor = makeAddr("blockedDepositor");
        usdg.mint(blockedDepositor, 10e18);
        vm.prank(blockedDepositor);
        usdg.approve(address(lending), type(uint256).max);

        address eToken = lending.getETokenAddress(RESERVE_ID);
        vm.prank(lender);
        IERC20View(eToken).approve(address(lending), type(uint256).max);

        lending.emergencyPauseAll();
        assertTrue(lending.paused(), "pause active");

        vm.startPrank(blockedDepositor);
        vm.expectRevert(bytes("83"));
        lending.deposit(RESERVE_ID, 10e18, blockedDepositor, 0);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert(bytes("83"));
        lending.redeem(RESERVE_ID, 1e18, lender, false);
        vm.stopPrank();

        vm.startPrank(address(vault));
        vm.expectRevert(bytes("83"));
        lending.newDebtPosition(RESERVE_ID);
        vm.expectRevert(bytes("83"));
        lending.borrow(address(vault), debtId, 1e18);
        vm.stopPrank();
        assertEq(lending.nextDebtPositionId(), nextDebtBefore, "paused newDebt did not advance id");

        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.open(
            UniV4LeverageVault.OpenParams({
                amountInvest: 100e18,
                amountBorrow: 100e18,
                tickLower: -1000,
                tickUpper: 1000,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        // Repay is deliberately available during an emergency pause.
        usdg.mint(address(vault), 100e18);
        vm.startPrank(address(vault));
        usdg.approve(address(lending), type(uint256).max);
        uint256 repaid = lending.repay(user, debtId, 100e18);
        vm.stopPrank();
        (uint256 debtDuringPause,) = lending.getCurrentDebt(debtId);
        assertEq(repaid, 100e18, "direct paused repay amount");
        assertEq(debtDuringPause, debtBefore - repaid, "direct paused repay reduced debt");

        // Risk-reducing administration remains available; inverse operations remain blocked.
        lending.disableVaultToBorrow(VAULT_ID);
        lending.setCreditsOfVault(VAULT_ID, RESERVE_ID, 1e18);
        lending.freezeReserve(RESERVE_ID);
        lending.disableBorrowing(RESERVE_ID);
        lending.setReserveCapacity(RESERVE_ID, LENDER_DEPOSIT);

        vm.expectRevert(bytes("83"));
        lending.enableVaultToBorrow(VAULT_ID);
        vm.expectRevert(bytes("83"));
        lending.setCreditsOfVault(VAULT_ID, RESERVE_ID, 2e18);
        vm.expectRevert(bytes("83"));
        lending.unFreezeReserve(RESERVE_ID);
        vm.expectRevert(bytes("83"));
        lending.enableBorrowing(RESERVE_ID);
        vm.expectRevert(bytes("83"));
        lending.setReserveCapacity(RESERVE_ID, LENDER_DEPOSIT + 1);

        lending.unPauseAll();
        assertFalse(lending.paused(), "pause cleared");
        assertFalse(lending.borrowingWhiteList(address(vault)), "vault disable persists after unpause");
        assertEq(lending.credits(RESERVE_ID, address(vault)), 1e18, "lower credit persists after unpause");

        (,,,,,, uint256 persistedCap,,,,, DataTypes.Flags memory persistedFlags) = lending.reserves(RESERVE_ID);
        assertEq(persistedCap, LENDER_DEPOSIT, "lower cap persists after unpause");
        assertTrue(persistedFlags.frozen, "freeze persists after unpause");
        assertFalse(persistedFlags.borrowingEnabled, "borrowing disable persists after unpause");

        // Explicit recovery is possible and does not undo the paused repayment.
        lending.unFreezeReserve(RESERVE_ID);
        lending.enableBorrowing(RESERVE_ID);
        lending.enableVaultToBorrow(VAULT_ID);
        lending.setCreditsOfVault(VAULT_ID, RESERVE_ID, type(uint128).max);
        lending.setReserveCapacity(RESERVE_ID, type(uint256).max);

        vm.prank(blockedDepositor);
        lending.deposit(RESERVE_ID, 10e18, blockedDepositor, 0);
        vm.prank(lender);
        uint256 redeemedAfterRecovery = lending.redeem(RESERVE_ID, 1e18, lender, false);
        assertGt(redeemedAfterRecovery, 0, "redeem resumes after explicit recovery");

        uint256 newId = _open(100e18, 100e18);
        (, uint128 newLiquidity,,, uint256 newDebtId) = vault.positions(newId);
        (uint256 newDebt,) = lending.getCurrentDebt(newDebtId);
        assertGt(newLiquidity, 0, "new position works after explicit recovery");
        assertEq(newDebt, 100e18, "new debt accounting resumes consistently");
        (uint256 debtAfterRecovery,) = lending.getCurrentDebt(debtId);
        assertEq(debtAfterRecovery, debtDuringPause, "unpause did not rewrite existing debt");
    }
}

contract NamedV3MockERC20 is V3MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    constructor(string memory tokenName, string memory tokenSymbol) {
        name = tokenName;
        symbol = tokenSymbol;
    }
}

contract UniV3LeveragePausedE2ETest is Test {
    NamedV3MockERC20 risk;
    NamedV3MockERC20 loan;
    LendingPool lending;
    SolonVaultRegistry vaultRegistry;
    MockV3PM positionManager;
    V3MockSwap swap;
    V3MockOracle oracle;
    V3MockPool poolState;
    UniV3LeverageVault vault;

    address user = makeAddr("v3PausedUser");
    address lender = makeAddr("v3PausedLender");
    address governor = makeAddr("v3PausedGovernor");

    function setUp() public {
        NamedV3MockERC20 a = new NamedV3MockERC20("Risk", "RISK");
        NamedV3MockERC20 b = new NamedV3MockERC20("Loan", "LOAN");
        (risk, loan) = address(a) < address(b) ? (a, b) : (b, a);

        AddressRegistry registry = new AddressRegistry(address(risk));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("v3PausedTreasury"));
        lending = new LendingPool(address(registry), address(risk));
        lending.initReserve(address(loan));
        vaultRegistry = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultRegistry));

        positionManager = new MockV3PM(V3MockERC20(address(risk)), V3MockERC20(address(loan)));
        swap = new V3MockSwap(V3MockERC20(address(risk)), V3MockERC20(address(loan)), 1e18);
        oracle = new V3MockOracle();
        poolState = new V3MockPool();
        vault = new UniV3LeverageVault(
            UniV3LeverageVault.InitParams({
                governor: governor,
                positionManager: address(positionManager),
                pool: address(poolState),
                lendingPool: address(lending),
                reserveId: 1,
                oracle: address(oracle),
                swapExecutor: address(swap),
                token0: address(risk),
                token1: address(loan),
                loanIsC0: false,
                fee: 3000,
                minWidthTicks: 100,
                liqBonusBps: 800,
                protocolFeeBps: 1000,
                harvestFeeBps: 1000,
                borrowFeeBps: 0,
                closeFactorBps: 5000,
                lltv: 0.8e18
            })
        );

        vaultRegistry.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);

        loan.mint(lender, 100_000e18);
        vm.startPrank(lender);
        loan.approve(address(lending), type(uint256).max);
        lending.deposit(1, 100_000e18, lender, 0);
        vm.stopPrank();

        loan.mint(user, 10_000e18);
        loan.mint(address(swap), 1_000_000e18);
        risk.mint(address(swap), 1_000_000e18);
    }

    function _open(uint256 invest, uint256 borrow) internal returns (uint256 id) {
        vm.startPrank(user);
        loan.approve(address(vault), type(uint256).max);
        id = vault.open(
            UniV3LeverageVault.OpenParams({
                amountInvest: invest,
                amountBorrow: borrow,
                tickLower: -1000,
                tickUpper: 1000,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_paused_UniV3LeverageVault_close_repaysDebt_andBurnsPosition() public {
        uint256 id = _open(1_000e18, 2_000e18);
        (, uint128 liquidityBefore,,, uint256 debtId) = vault.positions(id);
        assertGt(liquidityBefore, 0, "precondition: live V3 liquidity");

        lending.emergencyPauseAll();
        vm.prank(user);
        vault.close(
            id,
            UniV3LeverageVault.CloseParams({
                percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
            })
        );

        (uint256 debtAfter,) = lending.getCurrentDebt(debtId);
        (, uint128 liquidityAfter,,,) = vault.positions(id);
        assertEq(debtAfter, 0, "paused V3 close repaid real-pool debt");
        assertEq(vault.ownerOf(id), address(0), "paused V3 close burned position NFT");
        assertEq(liquidityAfter, 0, "paused V3 close removed all liquidity");
    }

    function test_pause_blocks_selfFunded_UniV3_increase_and_unpause_restores() public {
        uint256 id = _open(1_000e18, 2_000e18);
        (, uint128 liquidityBefore,,, uint256 debtId) = vault.positions(id);
        (uint256 debtBefore,) = lending.getCurrentDebt(debtId);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV3LeverageVault.IncreaseParams({
                amountInvest: 100e18,
                amountBorrow: 0,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        (, uint128 liquidityPaused,,,) = vault.positions(id);
        (uint256 debtPaused,) = lending.getCurrentDebt(debtId);
        assertEq(liquidityPaused, liquidityBefore, "paused self-funded increase preserves liquidity");
        assertEq(debtPaused, debtBefore, "paused self-funded increase preserves debt");

        lending.unPauseAll();
        vm.prank(user);
        vault.increase(
            id,
            UniV3LeverageVault.IncreaseParams({
                amountInvest: 100e18,
                amountBorrow: 0,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );

        (, uint128 liquidityAfter,,,) = vault.positions(id);
        (uint256 debtAfter,) = lending.getCurrentDebt(debtId);
        assertGt(liquidityAfter, liquidityBefore, "unpause restores self-funded increase");
        assertEq(debtAfter, debtBefore, "self-funded increase leaves debt unchanged");
    }

    function test_paused_UniV3LeverageVault_increaseWithBorrow_revertsAtomically() public {
        uint256 id = _open(1_000e18, 2_000e18);
        (, uint128 liquidityBefore,,, uint256 debtId) = vault.positions(id);
        (uint256 debtBefore,) = lending.getCurrentDebt(debtId);
        uint256 userLoanBefore = loan.balanceOf(user);
        uint256 userRiskBefore = risk.balanceOf(user);
        uint256 vaultLoanBefore = loan.balanceOf(address(vault));
        uint256 vaultRiskBefore = risk.balanceOf(address(vault));
        uint256 managerLoanBefore = loan.balanceOf(address(positionManager));
        uint256 managerRiskBefore = risk.balanceOf(address(positionManager));
        address eToken = lending.getETokenAddress(1);
        uint256 reserveCashBefore = loan.balanceOf(eToken);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV3LeverageVault.IncreaseParams({
                amountInvest: 100e18,
                amountBorrow: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                zapPath: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        (, uint128 liquidityAfter,,,) = vault.positions(id);
        (uint256 debtAfter,) = lending.getCurrentDebt(debtId);
        assertEq(liquidityAfter, liquidityBefore, "reverted paused increase preserves liquidity");
        assertEq(debtAfter, debtBefore, "reverted paused increase preserves debt");
        assertEq(loan.balanceOf(user), userLoanBefore, "reverted pull preserves user loan balance");
        assertEq(risk.balanceOf(user), userRiskBefore, "user risk balance unchanged");
        assertEq(loan.balanceOf(address(vault)), vaultLoanBefore, "vault loan balance unchanged");
        assertEq(risk.balanceOf(address(vault)), vaultRiskBefore, "vault risk balance unchanged");
        assertEq(loan.balanceOf(address(positionManager)), managerLoanBefore, "NFPM loan balance unchanged");
        assertEq(risk.balanceOf(address(positionManager)), managerRiskBefore, "NFPM risk balance unchanged");
        assertEq(loan.balanceOf(eToken), reserveCashBefore, "reserve cash unchanged");
    }
}

contract UniV3DualPausedE2ETest is ExploitDualV3Fixture {
    struct DualState {
        uint128 liquidity;
        uint256 riskDebt;
        uint256 loanDebt;
        uint256 userRisk;
        uint256 userLoan;
        uint256 vaultRisk;
        uint256 vaultLoan;
        uint256 managerRisk;
        uint256 managerLoan;
        uint256 reserveRiskCash;
        uint256 reserveLoanCash;
    }

    function _dualState(uint256 id) internal view returns (DualState memory state) {
        (, uint128 liquidity,,, uint256 debtRisk, uint256 debtLoan) = vault.positions(id);
        state.liquidity = liquidity;
        (state.riskDebt,) = lending.getCurrentDebt(debtRisk);
        (state.loanDebt,) = lending.getCurrentDebt(debtLoan);
        state.userRisk = weth.balanceOf(user);
        state.userLoan = usdg.balanceOf(user);
        state.vaultRisk = weth.balanceOf(address(vault));
        state.vaultLoan = usdg.balanceOf(address(vault));
        state.managerRisk = weth.balanceOf(address(pm));
        state.managerLoan = usdg.balanceOf(address(pm));
        state.reserveRiskCash = weth.balanceOf(lending.getETokenAddress(2));
        state.reserveLoanCash = usdg.balanceOf(lending.getETokenAddress(1));
    }

    function _assertDualStateUnchanged(DualState memory beforeState, DualState memory afterState) internal pure {
        assertEq(afterState.liquidity, beforeState.liquidity, "liquidity rolled back");
        assertEq(afterState.riskDebt, beforeState.riskDebt, "risk debt rolled back");
        assertEq(afterState.loanDebt, beforeState.loanDebt, "loan debt rolled back");
        assertEq(afterState.userRisk, beforeState.userRisk, "user risk balance rolled back");
        assertEq(afterState.userLoan, beforeState.userLoan, "user loan balance rolled back");
        assertEq(afterState.vaultRisk, beforeState.vaultRisk, "vault risk balance rolled back");
        assertEq(afterState.vaultLoan, beforeState.vaultLoan, "vault loan balance rolled back");
        assertEq(afterState.managerRisk, beforeState.managerRisk, "PM risk balance rolled back");
        assertEq(afterState.managerLoan, beforeState.managerLoan, "PM loan balance rolled back");
        assertEq(afterState.reserveRiskCash, beforeState.reserveRiskCash, "risk reserve cash rolled back");
        assertEq(afterState.reserveLoanCash, beforeState.reserveLoanCash, "loan reserve cash rolled back");
    }

    function test_pause_blocks_selfFunded_UniV3Dual_increase_and_unpause_restores() public {
        // Start from a genuinely self-funded, zero-debt position so V3 LP rounding
        // dust cannot be mistaken for a change in either borrowing leg.
        weth.mint(user, 1_000e18);
        usdg.mint(user, 1_000e18);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        uint256 id = vault.open(
            UniV3DualVault.OpenParams({
                investRisk: 1_000e18,
                investLoan: 1_000e18,
                borrowRisk: 0,
                borrowLoan: 0,
                tickLower: -1000,
                tickUpper: 1000,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
        weth.mint(user, 100e18);
        usdg.mint(user, 100e18);
        DualState memory beforeState = _dualState(id);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV3DualVault.IncreaseParams({
                investRisk: 100e18,
                investLoan: 100e18,
                borrowRisk: 0,
                borrowLoan: 0,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        _assertDualStateUnchanged(beforeState, _dualState(id));

        lending.unPauseAll();
        vm.prank(user);
        vault.increase(
            id,
            UniV3DualVault.IncreaseParams({
                investRisk: 100e18,
                investLoan: 100e18,
                borrowRisk: 0,
                borrowLoan: 0,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );

        DualState memory afterState = _dualState(id);
        assertGt(afterState.liquidity, beforeState.liquidity, "unpause restores self-funded increase");
        assertEq(afterState.riskDebt, beforeState.riskDebt, "self-funded increase leaves risk debt unchanged");
        assertEq(afterState.loanDebt, beforeState.loanDebt, "self-funded increase leaves loan debt unchanged");
    }

    function test_paused_UniV3Dual_riskOnlyBorrowIncrease_revertsAtomically() public {
        uint256 id = _open(user, 1_000e18, 2_000e18, 1_000e18);
        DualState memory beforeState = _dualState(id);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV3DualVault.IncreaseParams({
                investRisk: 0,
                investLoan: 0,
                borrowRisk: 100e18,
                borrowLoan: 0,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        _assertDualStateUnchanged(beforeState, _dualState(id));
    }

    function test_paused_UniV3Dual_loanOnlyBorrowIncrease_revertsAtomically() public {
        uint256 id = _open(user, 1_000e18, 2_000e18, 1_000e18);
        DualState memory beforeState = _dualState(id);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV3DualVault.IncreaseParams({
                investRisk: 0,
                investLoan: 0,
                borrowRisk: 0,
                borrowLoan: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        _assertDualStateUnchanged(beforeState, _dualState(id));
    }

    function test_paused_UniV3Dual_close_repaysBothDebts_andBurnsPosition() public {
        uint256 id = _open(user, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liquidityBefore,,, uint256 debtRisk, uint256 debtLoan) = vault.positions(id);
        assertGt(liquidityBefore, 0, "precondition: live dual V3 liquidity");

        lending.emergencyPauseAll();
        _close(user, id);

        (uint256 riskDebtAfter,) = lending.getCurrentDebt(debtRisk);
        (uint256 loanDebtAfter,) = lending.getCurrentDebt(debtLoan);
        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertLe(riskDebtAfter, 1e3, "paused dual V3 close cleared risk debt");
        assertLe(loanDebtAfter, 1e3, "paused dual V3 close cleared loan debt");
        assertEq(vault.ownerOf(id), address(0), "paused dual V3 close burned position NFT");
        assertEq(liquidityAfter, 0, "paused dual V3 close removed all liquidity");
    }

    function test_paused_UniV3Dual_addMargin_reducesBothDebts_andKeepsPosition() public {
        uint256 id = _open(user, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liquidityBefore,,, uint256 debtRisk, uint256 debtLoan) = vault.positions(id);
        (uint256 riskDebtBefore,) = lending.getCurrentDebt(debtRisk);
        (uint256 loanDebtBefore,) = lending.getCurrentDebt(debtLoan);

        weth.mint(user, 500e18);
        usdg.mint(user, 300e18);
        lending.emergencyPauseAll();
        vm.prank(user);
        vault.addMargin(id, 500e18, 300e18);

        (uint256 riskDebtAfter,) = lending.getCurrentDebt(debtRisk);
        (uint256 loanDebtAfter,) = lending.getCurrentDebt(debtLoan);
        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertLt(riskDebtAfter, riskDebtBefore, "paused dual V3 margin reduced risk debt");
        assertLt(loanDebtAfter, loanDebtBefore, "paused dual V3 margin reduced loan debt");
        assertApproxEqAbs(riskDebtBefore - riskDebtAfter, 500e18, 1e3, "paused margin repaid exact risk amount");
        assertApproxEqAbs(loanDebtBefore - loanDebtAfter, 300e18, 1e3, "paused margin repaid exact loan amount");
        assertEq(vault.ownerOf(id), user, "paused margin keeps position NFT");
        assertEq(liquidityAfter, liquidityBefore, "paused margin does not alter LP liquidity");
    }

    function test_paused_UniV3Dual_liquidation_reducesDebt_andLiquidity() public {
        uint256 id = _open(user, 1_000e18, 2_000e18, 1_000e18);
        (, uint128 liquidityBefore,,, uint256 debtRisk, uint256 debtLoan) = vault.positions(id);
        (uint256 riskDebtBefore,) = lending.getCurrentDebt(debtRisk);
        (uint256 loanDebtBefore,) = lending.getCurrentDebt(debtLoan);
        oracle.setValPerLiq((3_000e18 * 1e18) / liquidityBefore);

        address keeper = makeAddr("pausedV3DualKeeper");
        vm.prank(gov);
        vault.setLiquidator(keeper, true);
        weth.mint(keeper, 10_000e18);
        usdg.mint(keeper, 10_000e18);
        lending.emergencyPauseAll();

        vm.startPrank(keeper);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.liquidate(
            id, UniV3DualVault.LiquidateParams({ratioBps: 5000, minSeizeValue: 0, deadline: block.timestamp + 1})
        );
        vm.stopPrank();

        (uint256 riskDebtAfter,) = lending.getCurrentDebt(debtRisk);
        (uint256 loanDebtAfter,) = lending.getCurrentDebt(debtLoan);
        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        assertLt(riskDebtAfter, riskDebtBefore, "paused dual V3 liquidation reduced risk debt");
        assertLt(loanDebtAfter, loanDebtBefore, "paused dual V3 liquidation reduced loan debt");
        assertLe(
            riskDebtAfter,
            riskDebtBefore - (riskDebtBefore * 5000) / 10000,
            "paused liquidation repaid at least close-factor risk debt"
        );
        assertLe(
            loanDebtAfter,
            loanDebtBefore - (loanDebtBefore * 5000) / 10000,
            "paused liquidation repaid at least close-factor loan debt"
        );
        assertLt(liquidityAfter, liquidityBefore, "paused dual V3 liquidation seized liquidity");
        assertGt(liquidityAfter, 0, "partial liquidation retains liquidity");
        assertEq(vault.ownerOf(id), user, "partial liquidation retains position NFT");
    }
}

contract UniV4DualPausedE2ETest is Test {
    NamedMockERC20 weth;
    NamedMockERC20 usdg;
    LendingPool lending;
    SolonVaultRegistry vaultRegistry;
    MovablePM positionManager;
    CountingSwap swap;
    DualMockOracle oracle;
    MovableSV stateView;
    UniV4DualVault vault;

    address user = makeAddr("v4DualPausedUser");
    address governor = makeAddr("v4DualPausedGovernor");

    function setUp() public {
        NamedMockERC20 a = new NamedMockERC20("Wrapped ETH", "WETH");
        NamedMockERC20 b = new NamedMockERC20("USD Global", "USDG");
        (weth, usdg) = address(a) < address(b) ? (a, b) : (b, a);

        AddressRegistry registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("v4DualPausedTreasury"));
        lending = new LendingPool(address(registry), address(weth));
        lending.initReserve(address(usdg));
        lending.initReserve(address(weth));
        vaultRegistry = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultRegistry));

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        positionManager = new MovablePM(V4MockERC20(address(weth)), V4MockERC20(address(usdg)), sqrtP);
        swap = new CountingSwap(V4MockERC20(address(weth)), V4MockERC20(address(usdg)));
        oracle = new DualMockOracle();
        stateView = new MovableSV(sqrtP, 0);
        vault = new UniV4DualVault(
            UniV4DualVault.InitParams({
                governor: governor,
                positionManager: address(positionManager),
                stateView: address(stateView),
                lendingPool: address(lending),
                reserveRisk: 2,
                reserveLoan: 1,
                oracle: address(oracle),
                swapExecutor: address(swap),
                token0: address(weth),
                token1: address(usdg),
                loanIsC0: false,
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0),
                minWidthTicks: 100,
                liqBonusBps: 800,
                protocolFeeBps: 1000,
                harvestFeeBps: 1000,
                closeFactorBps: 5000,
                lltv: 0.8e18
            })
        );

        vaultRegistry.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        lending.setCreditsOfVault(1, 2, type(uint128).max);
        _deposit(makeAddr("v4DualLoanLender"), usdg, 1, 1_000_000e18);
        _deposit(makeAddr("v4DualRiskLender"), weth, 2, 1_000_000e18);

        weth.mint(user, 2_000e18);
        usdg.mint(user, 2_000e18);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address lender, NamedMockERC20 token, uint256 reserveId, uint256 amount) internal {
        token.mint(lender, amount);
        vm.startPrank(lender);
        token.approve(address(lending), type(uint256).max);
        lending.deposit(reserveId, amount, lender, 0);
        vm.stopPrank();
    }

    function test_pause_blocks_selfFunded_UniV4Dual_increase_and_unpause_restores() public {
        vm.prank(user);
        uint256 id = vault.open(
            UniV4DualVault.OpenParams({
                investRisk: 1_000e18,
                investLoan: 1_000e18,
                borrowRisk: 0,
                borrowLoan: 0,
                tickLower: -1000,
                tickUpper: 1000,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );
        (, uint128 liquidityBefore,,, uint256 debtRisk, uint256 debtLoan) = vault.positions(id);

        lending.emergencyPauseAll();
        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.increase(
            id,
            UniV4DualVault.IncreaseParams({
                investRisk: 100e18,
                investLoan: 100e18,
                borrowRisk: 0,
                borrowLoan: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        (, uint128 liquidityPaused,,,,) = vault.positions(id);
        assertEq(liquidityPaused, liquidityBefore, "paused self-funded increase preserves liquidity");

        lending.unPauseAll();
        vm.prank(user);
        vault.increase(
            id,
            UniV4DualVault.IncreaseParams({
                investRisk: 100e18,
                investLoan: 100e18,
                borrowRisk: 0,
                borrowLoan: 0,
                minLiquidity: 0,
                deadline: block.timestamp + 1
            })
        );

        (, uint128 liquidityAfter,,,,) = vault.positions(id);
        (uint256 riskDebt,) = lending.getCurrentDebt(debtRisk);
        (uint256 loanDebt,) = lending.getCurrentDebt(debtLoan);
        assertGt(liquidityAfter, liquidityBefore, "unpause restores self-funded increase");
        assertEq(riskDebt, 0, "self-funded increase leaves risk debt unchanged");
        assertEq(loanDebt, 0, "self-funded increase leaves loan debt unchanged");
    }
}
