// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title SettlementMath — STANDARD liquidation settlement (loan/USDG units).
/// @notice Bit-exact twin of reference/settlement_golden.py.
///         Liquidation follows the industry-standard model (Aave/Morpho/Compound/Extra all do this):
///         the liquidator repays `repay` of the borrower's debt and seizes collateral worth
///         repay×(1+bonus); the bonus is the liquidator's incentive. The protocol may take a small
///         cut (protocolFeeBps) of the bonus. The borrower keeps whatever collateral remains in the
///         position — no confiscation, no burn, no clawback. We follow the standard; the ONLY custom
///         piece is how the LP collateral is *valued* (anti-manipulation LpShareOracle), not the mechanics.
///         Fees are flat (Extra model, 2026-09-03 decision): revenue = borrow interest + liquidation;
///         NO high-water performance fee.
library SettlementMath {
    uint256 internal constant BPS = 10000;

    struct Seize {
        uint256 repay;           // debt the liquidator repays (loan units)
        uint256 seizeValue;      // collateral value taken from the position = repay×(1+bonus)
        uint256 protocolFee;     // protocol's cut of the bonus (loan units)
        uint256 liquidatorSeize; // liquidator's net take = seizeValue - protocolFee
    }

    /// @notice Standard liquidation seize. Caller caps `seizeValue` at the position's available
    ///         collateral before executing (underwater → liquidator simply gets less bonus).
    function liquidationSeize(uint256 repay, uint256 bonusBps, uint256 protocolFeeBps)
        internal pure returns (Seize memory s)
    {
        s.repay = repay;
        s.seizeValue = (repay * (BPS + bonusBps)) / BPS;
        uint256 bonus = s.seizeValue - repay;
        s.protocolFee = (bonus * protocolFeeBps) / BPS;
        s.liquidatorSeize = s.seizeValue - s.protocolFee;
    }
}
