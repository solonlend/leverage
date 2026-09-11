// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {UniV3ActualRepayTest, UniV4ActualRepayTest} from "./LiquidationActualRepay.t.sol";
import {UniV3LeverageVault} from "../src/UniV3LeverageVault.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";

contract UniV3SingleLiquidationReviewTest is UniV3ActualRepayTest {
    function test_review_secondRepay_refundsUnspentRequest() public {
        (uint256 id, uint128 liquidity, uint256 debtId) = _openUnhealthy();
        oracle.setValPerLiq(20e18 * 1e18 / liquidity);
        lending.setRepayCap(debtId, 20e18);
        uint256 principal = risk.balanceOf(address(pm)) + loan.balanceOf(address(pm));
        uint256 borrowerBefore = loan.balanceOf(address(this));
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        bool closed = vault.liquidate(id, UniV3LeverageVault.LiquidateParams({
            repayAmount: 50e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertTrue(closed, "exercise excess repayment after full seizure");
        assertEq(lending.debt(debtId), 60e18, "both repayments actually settle only 20");
        assertEq(loan.balanceOf(address(this)) - borrowerBefore, principal - 41.6e18,
            "refund subtracts actual second repay, not requested amount");
        assertEq(loan.balanceOf(address(vault)), 0, "unspent second repay must not remain in vault");
    }

    function test_review_partialLiquidation_skimsHarvestFees() public { _checkHarvest(false); }
    function test_review_fullLiquidation_skimsHarvestFees() public { _checkHarvest(true); }

    function _checkHarvest(bool full) internal {
        (uint256 id, uint128 liquidity,) = _openUnhealthy();
        (uint256 tokenId,,,,) = vault.positions(id);
        pm.accrueFees(tokenId, 10e18, 20e18);
        if (full) oracle.setValPerLiq(20e18 * 1e18 / liquidity);
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        bool closed = vault.liquidate(id, UniV3LeverageVault.LiquidateParams({
            repayAmount: 50e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertEq(closed, full, "exercise requested liquidation branch");
        assertEq(risk.balanceOf(governor), 1e18, "harvest risk cut before liquidation swap");
        assertEq(loan.balanceOf(governor), 2.4e18, "harvest loan cut plus liquidation fee");
        assertEq(risk.balanceOf(address(vault)), 0, "net fees must join settlement");
        assertEq(loan.balanceOf(address(vault)), 0, "net fees must join settlement");
    }
}

contract UniV4SingleLiquidationReviewTest is UniV4ActualRepayTest {
    function test_review_secondRepay_refundsUnspentRequest() public {
        (uint256 id, uint128 liquidity, uint256 debtId) = _openUnhealthy();
        oracle.setValPerLiq(20e18 * 1e18 / liquidity);
        lending.setRepayCap(debtId, 20e18);
        uint256 principal = risk.balanceOf(address(pm)) + loan.balanceOf(address(pm));
        uint256 borrowerBefore = loan.balanceOf(address(this));
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        bool closed = vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: 50e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertTrue(closed, "exercise excess repayment after full seizure");
        assertEq(lending.debt(debtId), 60e18, "both repayments actually settle only 20");
        assertEq(loan.balanceOf(address(this)) - borrowerBefore, principal - 41.6e18,
            "refund subtracts actual second repay, not requested amount");
        assertEq(loan.balanceOf(address(vault)), 0, "unspent second repay must not remain in vault");
    }

    function test_review_partialLiquidation_skimsHarvestFees() public { _checkHarvest(false); }
    function test_review_fullLiquidation_skimsHarvestFees() public { _checkHarvest(true); }

    function _checkHarvest(bool full) internal {
        (uint256 id, uint128 liquidity,) = _openUnhealthy();
        (uint256 tokenId,,,,) = vault.positions(id);
        pm.accrueFees(tokenId, 10e18, 20e18);
        if (full) oracle.setValPerLiq(20e18 * 1e18 / liquidity);
        vm.startPrank(keeper);
        loan.approve(address(vault), type(uint256).max);
        bool closed = vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: 50e18, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertEq(closed, full, "exercise requested liquidation branch");
        assertEq(risk.balanceOf(governor), 1e18, "harvest risk cut before liquidation swap");
        assertEq(loan.balanceOf(governor), 2.4e18, "harvest loan cut plus liquidation fee");
        assertEq(risk.balanceOf(address(vault)), 0, "net fees must join settlement");
        assertEq(loan.balanceOf(address(vault)), 0, "net fees must join settlement");
    }
}

