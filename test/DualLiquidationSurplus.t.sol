// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {SettlementMath} from "../src/libraries/SettlementMath.sol";
import {CappedRepayLendingPool} from "./LiquidationActualRepay.t.sol";
import {MockV3PM, MockPool, MockERC20 as V3Token} from "./VaultFlow.integration.t.sol";
import {MockERC20, MockOracle, MockV4PositionManager, MockStateView} from "./V4VaultFlow.integration.t.sol";

contract SurplusSwap {
    uint256 public outputBps = 10000;
    uint256 public lastMinOut;
    uint256 public ratioNumerator;
    uint256 public ratioDenominator;
    bool public fail;
    function configureRatio(uint256 numerator, uint256 denominator) external { ratioNumerator = numerator; ratioDenominator = denominator; }
    function configure(uint256 bps, bool shouldFail) external { outputBps = bps; fail = shouldFail; }
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata path)
        external returns (uint256 out)
    {
        require(!fail, "SWAP_FAILED");
        require(path.length == 0, "UNTRUSTED_PATH");
        lastMinOut = minOut;
        out = ratioDenominator == 0 ? amountIn * outputBps / 10000 : amountIn * ratioNumerator / ratioDenominator;
        require(out >= minOut, "MINOUT");
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).transfer(msg.sender, out);
    }
}
interface ISurplusHarness {
    function payout(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId) external;
    function payoutWithCap(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId, uint256 cap) external;
}
contract SurplusV3Harness is UniV3DualVault {
    // Forge test marker: this exposes internal payout plumbing and is never deployed in production.
    bool public constant IS_TEST = true;
    constructor(InitParams memory p) UniV3DualVault(p) {}
    function payout(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId) external {
        _dispatch(borrower, riskAmount, loanAmount, riskId, loanId, 10e18);
    }
    function payoutWithCap(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId, uint256 cap) external {
        _dispatch(borrower, riskAmount, loanAmount, riskId, loanId, cap);
    }
    function _dispatch(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId, uint256 cap) internal {
        positions[1].debtRisk = riskId;
        positions[1].debtLoan = loanId;
        SettlementMath.Seize memory seize = SettlementMath.Seize(cap, cap, 0, cap);
        _payoutLiquidation(1, positions[1], borrower, riskAmount, loanAmount, seize, cap, 0, 0, 0, true);
    }
}
contract SurplusV4Harness is UniV4DualVault {
    // Forge test marker: this exposes internal payout plumbing and is never deployed in production.
    bool public constant IS_TEST = true;
    constructor(InitParams memory p) UniV4DualVault(p) {}
    function payout(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId) external {
        _dispatch(borrower, riskAmount, loanAmount, riskId, loanId, 10e18);
    }
    function payoutWithCap(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId, uint256 cap) external {
        _dispatch(borrower, riskAmount, loanAmount, riskId, loanId, cap);
    }
    function _dispatch(address borrower, uint256 riskAmount, uint256 loanAmount, uint256 riskId, uint256 loanId, uint256 cap) internal {
        positions[1].debtRisk = riskId;
        positions[1].debtLoan = loanId;
        SettlementMath.Seize memory seize = SettlementMath.Seize(cap, cap, 0, cap);
        _payoutLiquidation(1, positions[1], borrower, riskAmount, loanAmount, seize, cap, 0, 0, 0, true);
    }
}
abstract contract DualSurplusAssertions is Test {
    event SurplusRetained(uint256 indexed debtRisk, uint256 indexed debtLoan, address indexed token, uint256 amount);
    MockERC20 risk;
    MockERC20 loan;
    MockOracle oracle;
    SurplusSwap swap;
    CappedRepayLendingPool lending;
    address vault;
    address borrower = address(0xB0);
    uint256 riskId;
    uint256 loanId;
    function _deploy() internal virtual returns (address);
    function setUp() public {
        MockERC20 a = new MockERC20(); MockERC20 b = new MockERC20();
        (risk, loan) = address(a) < address(b) ? (a, b) : (b, a);
        oracle = new MockOracle(); swap = new SurplusSwap(); lending = new CappedRepayLendingPool();
        lending.setReserve(1, address(risk)); lending.setReserve(2, address(loan));
        riskId = lending.newDebtPosition(1); loanId = lending.newDebtPosition(2);
        risk.mint(address(lending), 10000e18); loan.mint(address(lending), 10000e18);
        risk.mint(address(swap), 10000e18); loan.mint(address(swap), 10000e18);
        vault = _deploy();
    }
    function _run(uint256 riskDebt, uint256 loanDebt, uint256 riskOut, uint256 loanOut) internal {
        lending.borrow(address(0xDEAD), riskId, riskDebt);
        lending.borrow(address(0xDEAD), loanId, loanDebt);
        risk.mint(vault, riskOut); loan.mint(vault, loanOut);
        ISurplusHarness(vault).payout(borrower, riskOut, loanOut, riskId, loanId);
    }
    function test_1000RiskDebt_90LoanSurplus_repaysRisk() public {
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 910e18, "90 LOAN must repay other-leg RISK debt");
        assertEq(loan.balanceOf(borrower), 0, "no refund before both debts cleared");
        assertEq(swap.lastMinOut(), 85.5e18, "oracle 5 percent minimum");
    }
    function test_1000LoanDebt_90RiskSurplus_repaysLoan() public {
        _run(0, 1000e18, 100e18, 0);
        assertEq(lending.debt(loanId), 910e18, "90 RISK must repay other-leg LOAN debt");
        assertEq(risk.balanceOf(borrower), 0);
    }
    function test_swapFailure_retainsProtocolSurplus() public {
        swap.configure(10000, true);
        lending.borrow(address(0xDEAD), riskId, 1000e18);
        loan.mint(vault, 100e18);
        vm.expectEmit(true, true, true, true, vault);
        emit SurplusRetained(riskId, loanId, address(loan), 90e18);
        ISurplusHarness(vault).payout(borrower, 0, 100e18, riskId, loanId);
        assertEq(loan.balanceOf(borrower), 0, "failed conversion cannot refund borrower");
        assertEq(loan.balanceOf(vault), 90e18);
        assertEq(lending.debt(riskId), 1000e18);
    }
    function test_slippageBeyondFivePercent_retainsSurplus() public {
        swap.configure(9499, false);
        _run(1000e18, 0, 0, 100e18);
        assertEq(loan.balanceOf(borrower), 0, "unsafe swap must retain surplus");
        assertEq(loan.balanceOf(vault), 90e18);
        assertEq(lending.debt(riskId), 1000e18);
    }
    function test_slippageAtFivePercent_repaysDebt() public {
        swap.configure(9500, false);
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 914.5e18, "5 percent boundary swap accepted");
        assertEq(loan.balanceOf(borrower), 0);
    }
    function test_mixedDecimals_18Risk6Loan_usesOracleRawUnits() public {
        // 2500 LOAN (6 decimals) per 1 RISK (18 decimals).
        oracle.setRiskPrice(2500e6);
        swap.configureRatio(1e18, 2500e6);
        lending.borrow(address(0xDEAD), riskId, 1000e18);
        loan.mint(vault, 100e6);
        ISurplusHarness(vault).payoutWithCap(borrower, 0, 100e6, riskId, loanId, 10e6);
        assertEq(lending.debt(riskId), 1000e18 - 0.036e18);
        assertEq(swap.lastMinOut(), 0.0342e18, "95 percent of oracle-derived RISK raw units");
        assertEq(loan.balanceOf(borrower), 0);
        assertEq(loan.balanceOf(vault), 0);
    }
    function test_positiveQuoteRoundedToZero_retainsSurplus() public {
        oracle.setRiskPrice(1e40);
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 1000e18);
        assertEq(loan.balanceOf(vault), 90e18);
        assertEq(loan.balanceOf(borrower), 0);
        assertEq(swap.lastMinOut(), 0, "no unprotected swap attempted");
    }
    function test_zeroReciprocalOracleQuote_retainsSurplus() public {
        oracle.setRiskPrice(0);
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 1000e18);
        assertEq(loan.balanceOf(vault), 90e18);
        assertEq(loan.balanceOf(borrower), 0);
    }
    function test_cappedConvertedRepay_retainsUnpaidSurplus() public {
        lending.setRepayCap(riskId, 10e18);
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 990e18);
        assertEq(risk.balanceOf(vault), 80e18);
        assertEq(risk.balanceOf(borrower), 0);
    }
    function test_cappedOwnRepay_doesNotDivertOwnDebtCollateral() public {
        lending.setRepayCap(loanId, 10e18);
        _run(1000e18, 20e18, 0, 100e18);
        assertEq(lending.debt(loanId), 10e18);
        assertEq(lending.debt(riskId), 1000e18);
        assertEq(loan.balanceOf(vault), 80e18);
        assertEq(loan.balanceOf(borrower), 0);
    }
    function test_reverseSwapFailure_retainsProtocolSurplus() public {
        swap.configure(10000, true);
        _run(0, 1000e18, 100e18, 0);
        assertEq(risk.balanceOf(borrower), 0);
        assertEq(risk.balanceOf(vault), 90e18);
        assertEq(lending.debt(loanId), 1000e18);
    }
    function test_reciprocalOracleQuote_usesRiskPrice() public {
        oracle.setRiskPrice(2e18);
        swap.configure(5000, false);
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 955e18);
        assertEq(swap.lastMinOut(), 42.75e18);
    }
    function test_debtFree_refundsSurplus() public {
        _run(0, 0, 0, 100e18);
        assertEq(loan.balanceOf(borrower), 90e18);
    }
    function test_sameTokenDebt_repaidBeforeCrossConversion() public {
        _run(1000e18, 20e18, 0, 100e18);
        assertEq(lending.debt(loanId), 0);
        assertEq(lending.debt(riskId), 930e18);
        assertEq(loan.balanceOf(borrower), 0);
    }
    function test_conversionRefund_usesActualRepayment() public {
        _run(20e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 0);
        assertEq(risk.balanceOf(borrower), 70e18);
    }
    function test_donatedBalances_remainIsolated() public {
        loan.mint(vault, 7e18); risk.mint(vault, 3e18);
        _run(1000e18, 0, 0, 100e18);
        assertEq(lending.debt(riskId), 910e18);
        assertEq(loan.balanceOf(vault), 7e18);
        assertEq(risk.balanceOf(vault), 3e18);
    }
}
contract V3DualLiquidationSurplusTest is DualSurplusAssertions {
    MockV3PM pm;
    function test_publicLiquidate_loanOnlySeizure_reducesRiskDebt() public {
        UniV3DualVault realVault = UniV3DualVault(vault);
        uint256 id = realVault.open(UniV3DualVault.OpenParams({
            investRisk: 0, investLoan: 0, borrowRisk: 100e18, borrowLoan: 100e18,
            tickLower: -1000, tickUpper: 1000, amount0Min: 0, amount1Min: 0,
            minLiquidity: 0, deadline: block.timestamp + 1
        }));
        (uint256 dexId, uint128 liquidity,,, uint256 rId, uint256 lId) = realVault.positions(id);
        oracle.setValPerLiq(200e18 * 1e18 / liquidity);
        pm.accrueFees(dexId, 0, 200e18);
        pm.setZeroRiskOnWithdraw(true);
        address keeper = address(0xC0);
        risk.mint(keeper, 100e18); loan.mint(keeper, 100e18);
        vm.prank(address(0xA0)); realVault.setLiquidator(keeper, true);
        uint256 borrowerLoanBefore = loan.balanceOf(address(this));
        vm.startPrank(keeper);
        risk.approve(vault, type(uint256).max); loan.approve(vault, type(uint256).max);
        realVault.liquidate(id, UniV3DualVault.LiquidateParams({
            ratioBps: 5000, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertLt(lending.debt(rId), 50e18, "LOAN-only surplus must additionally repay RISK");
        assertEq(lending.debt(lId), 0, "same-token debt repaid first");
        if (lending.debt(rId) != 0) assertEq(loan.balanceOf(address(this)), borrowerLoanBefore);
        assertGt(swap.lastMinOut(), 0, "public liquidation must use oracle-protected conversion");
    }

    function _deploy() internal override returns (address) {
        pm = new MockV3PM(V3Token(address(risk)), V3Token(address(loan)));
        return address(new SurplusV3Harness(UniV3DualVault.InitParams({
            governor: address(0xA0), positionManager: address(pm), pool: address(new MockPool()),
            lendingPool: address(lending), reserveRisk: 1, reserveLoan: 2,
            oracle: address(oracle), swapExecutor: address(swap), token0: address(risk), token1: address(loan),
            loanIsC0: false, fee: 3000, minWidthTicks: 100, liqBonusBps: 800,
            protocolFeeBps: 1000, harvestFeeBps: 1000, closeFactorBps: 5000, lltv: 0.8e18
        })));
    }
}
contract V4DualLiquidationSurplusTest is DualSurplusAssertions {
    MockV4PositionManager pm;
    function test_publicLiquidate_loanOnlySeizure_reducesRiskDebt() public {
        UniV4DualVault realVault = UniV4DualVault(vault);
        uint256 id = realVault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: 0, borrowRisk: 100e18, borrowLoan: 100e18,
            tickLower: -1000, tickUpper: 1000, amount0Max: type(uint128).max, amount1Max: type(uint128).max,
            minLiquidity: 0, deadline: block.timestamp + 1
        }));
        (uint256 dexId, uint128 liquidity,,, uint256 rId, uint256 lId) = realVault.positions(id);
        oracle.setValPerLiq(200e18 * 1e18 / liquidity);
        pm.accrueFees(dexId, 0, 200e18);
        pm.setZeroRiskOnWithdraw(true);
        address keeper = address(0xC0);
        risk.mint(keeper, 100e18); loan.mint(keeper, 100e18);
        vm.prank(address(0xA0)); realVault.setLiquidator(keeper, true);
        uint256 borrowerLoanBefore = loan.balanceOf(address(this));
        vm.startPrank(keeper);
        risk.approve(vault, type(uint256).max); loan.approve(vault, type(uint256).max);
        realVault.liquidate(id, UniV4DualVault.LiquidateParams({
            ratioBps: 5000, minSeizeValue: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertLt(lending.debt(rId), 50e18, "LOAN-only surplus must additionally repay RISK");
        assertEq(lending.debt(lId), 0, "same-token debt repaid first");
        if (lending.debt(rId) != 0) assertEq(loan.balanceOf(address(this)), borrowerLoanBefore);
        assertGt(swap.lastMinOut(), 0, "public liquidation must use oracle-protected conversion");
    }

    function _deploy() internal override returns (address) {
        pm = new MockV4PositionManager(risk, loan, uint160(1 << 96));
        return address(new SurplusV4Harness(UniV4DualVault.InitParams({
            governor: address(0xA0), positionManager: address(pm), stateView: address(new MockStateView(uint160(1 << 96), 0)), tickSpacing: 60, hooks: address(0),
            lendingPool: address(lending), reserveRisk: 1, reserveLoan: 2,
            oracle: address(oracle), swapExecutor: address(swap), token0: address(risk), token1: address(loan),
            loanIsC0: false, fee: 3000, minWidthTicks: 100, liqBonusBps: 800,
            protocolFeeBps: 1000, harvestFeeBps: 1000, closeFactorBps: 5000, lltv: 0.8e18
        })));
    }
}
