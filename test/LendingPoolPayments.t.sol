// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

interface IERC20AccountingView {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Test-only ERC20 that burns 10% of every transfer as a transfer tax.
contract TaxedERC20 {
    string public name = "Taxed Token";
    string public symbol = "TAX";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    bool public taxEnabled = true;
    function setTaxEnabled(bool enabled) external { taxEnabled = enabled; }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fee = taxEnabled ? amount / 10 : 0;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

/// @dev Test-only WETH9 with real ETH backing for deposit/withdraw flows.
contract MockWETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH_TRANSFER_FAILED");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Test helper for bypassing LendingPool.receive() and forcing an ETH balance.
contract ForceETH {
    constructor() payable {}

    function force(address payable target) external {
        selfdestruct(target);
    }
}

contract LendingPoolPaymentsTest is Test {
    uint256 internal constant TAXED_RESERVE_ID = 1;
    uint256 internal constant WETH_RESERVE_ID = 2;
    uint256 internal constant VAULT_ID = 1;
    uint256 internal constant MINIMUM_ETOKEN_AMOUNT = 1000;

    TaxedERC20 internal taxedToken;
    MockWETH9 internal weth;
    AddressRegistry internal registry;
    SolonVaultRegistry internal vaultRegistry;
    LendingPool internal lendingPool;

    address internal lender = makeAddr("lender");
    address internal vault = makeAddr("vault");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        taxedToken = new TaxedERC20();
        weth = new MockWETH9();
        registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, treasury);

        vaultRegistry = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultRegistry));

        lendingPool = new LendingPool(address(registry), address(weth));
        lendingPool.initReserve(address(taxedToken));
        lendingPool.initReserve(address(weth));

        vaultRegistry.setVault(VAULT_ID, vault);
        lendingPool.enableVaultToBorrow(VAULT_ID);
        lendingPool.setCreditsOfVault(VAULT_ID, TAXED_RESERVE_ID, 1_000 ether);
    }

    function test_feeOnTransferDepositRevertsAtomically() public {
        _assertTaxedDepositRejected(false);
    }

    function test_feeOnTransferStakeRevertsAtomically() public {
        _assertTaxedDepositRejected(true);
    }

    function _assertTaxedDepositRejected(bool stake) internal {
        taxedToken.mint(lender, 100 ether);
        address eToken = lendingPool.getETokenAddress(TAXED_RESERVE_ID);
        vm.startPrank(lender);
        taxedToken.approve(address(lendingPool), 100 ether);
        vm.expectRevert(bytes4(keccak256("InsufficientTokenReceived()")));
        if (stake) lendingPool.depositAndStake(TAXED_RESERVE_ID, 100 ether, lender, 0);
        else lendingPool.deposit(TAXED_RESERVE_ID, 100 ether, lender, 0);
        vm.stopPrank();
        assertEq(taxedToken.balanceOf(eToken), 0);
        assertEq(taxedToken.balanceOf(lender), 100 ether);
        assertEq(IERC20AccountingView(eToken).totalSupply(), 0);
        assertEq(IERC20AccountingView(lendingPool.getStakingAddress(TAXED_RESERVE_ID)).balanceOf(lender), 0);
    }

    function test_feeOnTransferRepayRevertsAtomically() public {
        taxedToken.setTaxEnabled(false);
        _depositTaxedLiquidity(1_000 ether);
        vm.startPrank(vault);
        uint256 debtId = lendingPool.newDebtPosition(TAXED_RESERVE_ID);
        lendingPool.borrow(vault, debtId, 100 ether);
        vm.stopPrank();
        taxedToken.setTaxEnabled(true);
        address eToken = lendingPool.getETokenAddress(TAXED_RESERVE_ID);
        uint256 cashBefore = taxedToken.balanceOf(eToken);
        uint256 creditBefore = lendingPool.credits(TAXED_RESERVE_ID, vault);
        (uint256 debtBefore,) = lendingPool.getCurrentDebt(debtId);
        vm.startPrank(vault);
        taxedToken.approve(address(lendingPool), 100 ether);
        vm.expectRevert(bytes4(keccak256("InsufficientTokenReceived()")));
        lendingPool.repay(vault, debtId, 100 ether);
        vm.stopPrank();
        (uint256 debtAfter,) = lendingPool.getCurrentDebt(debtId);
        assertEq(debtAfter, debtBefore);
        assertEq(lendingPool.totalBorrowsOfReserve(TAXED_RESERVE_ID), debtBefore);
        assertEq(lendingPool.credits(TAXED_RESERVE_ID, vault), creditBefore);
        assertEq(taxedToken.balanceOf(eToken), cashBefore);
        assertEq(taxedToken.balanceOf(vault), 100 ether);
    }

    /// Native redemption must settle only its accounted WETH.
    function test_nativeRedeemPreservesPreexistingWeth() public {
        uint256 depositAmount = 100 ether;
        uint256 preexistingWeth = 7 ether;
        address recipient = makeAddr("nativeRedeemRecipient");
        vm.deal(lender, depositAmount + preexistingWeth);

        vm.prank(lender);
        lendingPool.deposit{value: depositAmount}(WETH_RESERVE_ID, depositAmount, lender, 0);

        vm.startPrank(lender);
        weth.deposit{value: preexistingWeth}();
        weth.transfer(address(lendingPool), preexistingWeth);
        vm.stopPrank();

        address eToken = lendingPool.getETokenAddress(WETH_RESERVE_ID);
        uint256 lenderShares = IERC20AccountingView(eToken).balanceOf(lender);
        vm.startPrank(lender);
        IERC20AccountingView(eToken).approve(address(lendingPool), lenderShares);
        uint256 redeemedAmount = lendingPool.redeem(WETH_RESERVE_ID, lenderShares, recipient, true);
        vm.stopPrank();

        assertEq(recipient.balance, redeemedAmount, "recipient receives only accounted redemption");
        assertEq(weth.balanceOf(address(lendingPool)), preexistingWeth, "unrelated WETH is preserved");
    }

    /// Forced ETH must survive later payable deposits.
    function test_nativeDepositPreservesForcedEth() public {
        uint256 depositAmount = 10 ether;
        uint256 forcedEth = 3 ether;
        address depositor = makeAddr("payableDepositor");
        vm.deal(depositor, depositAmount);
        vm.deal(address(this), forcedEth);

        ForceETH forceSender = new ForceETH{value: forcedEth}();
        forceSender.force(payable(address(lendingPool)));
        assertEq(address(lendingPool).balance, forcedEth, "forced balance reached pool");

        uint256 balanceBefore = depositor.balance;
        vm.prank(depositor);
        lendingPool.deposit{value: depositAmount}(WETH_RESERVE_ID, depositAmount, depositor, 0);

        assertEq(
            depositor.balance,
            balanceBefore - depositAmount,
            "depositor pays only current deposit"
        );
        assertEq(address(lendingPool).balance, forcedEth, "unrelated ETH is preserved");
    }

    function test_nativeStakeRefundsOnlyCurrentExcess() public {
        vm.deal(address(lendingPool), 3 ether);
        vm.deal(lender, 12 ether);
        vm.prank(lender);
        lendingPool.depositAndStake{value: 12 ether}(WETH_RESERVE_ID, 10 ether, lender, 0);
        assertEq(lender.balance, 2 ether);
        assertEq(address(lendingPool).balance, 3 ether);
        assertEq(IERC20AccountingView(lendingPool.getStakingAddress(WETH_RESERVE_ID)).balanceOf(lender), 10 ether - 1000);
    }

    function test_nativeDepositRefundsOnlyCurrentExcess() public {
        vm.deal(address(lendingPool), 3 ether);
        vm.deal(lender, 12 ether);
        vm.prank(lender);
        lendingPool.deposit{value: 12 ether}(WETH_RESERVE_ID, 10 ether, lender, 0);
        assertEq(lender.balance, 2 ether);
        assertEq(address(lendingPool).balance, 3 ether);
    }

    function test_nativeDepositCannotUseForcedEthWithZeroValue() public {
        vm.deal(address(lendingPool), 10 ether);
        vm.prank(lender);
        vm.expectRevert();
        lendingPool.deposit(WETH_RESERVE_ID, 10 ether, lender, 0);
        assertEq(address(lendingPool).balance, 10 ether);
    }

    function test_nativeDepositCannotUseForcedEthWithInsufficientValue() public {
        vm.deal(address(lendingPool), 10 ether);
        vm.deal(lender, 1 ether);
        vm.prank(lender);
        vm.expectRevert(bytes4(keccak256("InsufficientNativeValue()")));
        lendingPool.deposit{value: 1 ether}(WETH_RESERVE_ID, 10 ether, lender, 0);
        assertEq(address(lendingPool).balance, 10 ether);
        assertEq(lender.balance, 1 ether);
    }

    function test_nativeUnstakePreservesUnrelatedBalances() public {
        vm.deal(lender, 17 ether);
        vm.startPrank(lender);
        lendingPool.depositAndStake{value: 10 ether}(WETH_RESERVE_ID, 10 ether, lender, 0);
        weth.deposit{value: 7 ether}();
        weth.transfer(address(lendingPool), 7 ether);
        vm.stopPrank();
        vm.deal(address(lendingPool), 3 ether);
        vm.prank(lender);
        uint256 redeemed = lendingPool.unStakeAndWithdraw(WETH_RESERVE_ID, 10 ether - 1000, lender, true);
        assertEq(lender.balance, redeemed);
        assertEq(address(lendingPool).balance, 3 ether);
        assertEq(weth.balanceOf(address(lendingPool)), 7 ether);
    }

    function test_standardTokenDepositAndRepayRemainExact() public {
        taxedToken.setTaxEnabled(false);
        _depositTaxedLiquidity(1_000 ether);
        address eToken = lendingPool.getETokenAddress(TAXED_RESERVE_ID);
        assertEq(IERC20AccountingView(eToken).totalSupply(), 1_000 ether);
        vm.startPrank(vault);
        uint256 debtId = lendingPool.newDebtPosition(TAXED_RESERVE_ID);
        lendingPool.borrow(vault, debtId, 100 ether);
        taxedToken.approve(address(lendingPool), 100 ether);
        assertEq(lendingPool.repay(vault, debtId, 100 ether), 100 ether);
        vm.stopPrank();
        (uint256 debt,) = lendingPool.getCurrentDebt(debtId);
        assertEq(debt, 0);
        assertEq(taxedToken.balanceOf(eToken), 1_000 ether);
        assertEq(lendingPool.credits(TAXED_RESERVE_ID, vault), 1_000 ether);
    }

    function test_wethTokenDepositDoesNotConsumeForcedEth() public {
        vm.deal(address(lendingPool), 3 ether);
        vm.deal(lender, 10 ether);
        vm.startPrank(lender);
        weth.deposit{value: 10 ether}();
        weth.approve(address(lendingPool), 10 ether);
        lendingPool.deposit(WETH_RESERVE_ID, 10 ether, lender, 0);
        vm.stopPrank();
        assertEq(weth.balanceOf(lender), 0);
        assertEq(weth.balanceOf(lendingPool.getETokenAddress(WETH_RESERVE_ID)), 10 ether);
        assertEq(address(lendingPool).balance, 3 ether);
    }

    function test_nonWethDepositRefundsCurrentValueOnly() public {
        taxedToken.setTaxEnabled(false);
        taxedToken.mint(lender, 10 ether);
        vm.deal(address(lendingPool), 3 ether);
        vm.deal(lender, 2 ether);
        vm.startPrank(lender);
        taxedToken.approve(address(lendingPool), 10 ether);
        lendingPool.deposit{value: 2 ether}(TAXED_RESERVE_ID, 10 ether, lender, 0);
        vm.stopPrank();
        assertEq(lender.balance, 2 ether);
        assertEq(address(lendingPool).balance, 3 ether);
        assertEq(taxedToken.balanceOf(lendingPool.getETokenAddress(TAXED_RESERVE_ID)), 10 ether);
    }

    function _depositTaxedLiquidity(uint256 amount) internal {
        taxedToken.mint(lender, amount);
        vm.startPrank(lender);
        taxedToken.approve(address(lendingPool), amount);
        lendingPool.deposit(TAXED_RESERVE_ID, amount, lender, 0);
        vm.stopPrank();
    }
}
