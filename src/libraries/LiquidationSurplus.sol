// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

interface ISurplusLendingPool {
    function getCurrentDebt(uint256 debtId) external view returns (uint256, uint256);
    function repay(address onBehalfOf, uint256 debtId, uint256 amount) external returns (uint256);
}

interface ISurplusOracle {
    function riskValueInLoan(uint256 amount) external view returns (uint256);
}

interface ISurplusSwapExecutor {
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata path)
        external returns (uint256);
}

interface ISurplusToken {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Shared, delegatecalled liquidation settlement; operates only on this liquidation's surplus.
/// @dev Kept external to fit both Dual vaults under EIP-170. No storage layout dependencies.
library LiquidationSurplus {
    error TokenCallFailed();
    event SurplusRetained(uint256 indexed debtRisk, uint256 indexed debtLoan, address indexed token, uint256 amount);

    struct Context {
        address lendingPool;
        address oracle;
        address swapExecutor;
        address risk;
        address loan;
        uint256 debtRisk;
        uint256 debtLoan;
        uint256 maxSlippageBps;
    }

    /// @return gotRisk Refundable RISK, zero if any debt remains.
    /// @return gotLoan Refundable LOAN, zero if any debt remains.
    function settle(Context memory c, uint256 gotRisk, uint256 gotLoan) external returns (uint256, uint256) {
        // Match both legs before spending either surplus across currencies.
        gotRisk -= _repay(c.lendingPool, c.risk, c.debtRisk, gotRisk);
        gotLoan -= _repay(c.lendingPool, c.loan, c.debtLoan, gotLoan);
        uint256 oweRisk = _debt(c.lendingPool, c.debtRisk);
        uint256 oweLoan = _debt(c.lendingPool, c.debtLoan);
        bool buyRisk = oweRisk > 0 && oweLoan == 0 && gotLoan > 0;
        bool buyLoan = oweLoan > 0 && oweRisk == 0 && gotRisk > 0;
        if (buyRisk || buyLoan) {
            uint256 surplus = buyRisk ? gotLoan : gotRisk;
            uint256 minOut;
            if (buyRisk) {
                uint256 price = ISurplusOracle(c.oracle).riskValueInLoan(1e18);
                if (price > 0) minOut = (surplus * (10000 - c.maxSlippageBps) / 10000) * 1e18 / price;
            } else {
                minOut = ISurplusOracle(c.oracle).riskValueInLoan(surplus) * (10000 - c.maxSlippageBps) / 10000;
            }
            // Do not turn a rounded-to-zero quote into an unprotected dust swap.
            if (minOut > 0) {
                address tokenIn = buyRisk ? c.loan : c.risk;
                address tokenOut = buyRisk ? c.risk : c.loan;
                _approveIfNeeded(tokenIn, c.swapExecutor, surplus);
                try ISurplusSwapExecutor(c.swapExecutor).swapExactInput(tokenIn, tokenOut, surplus, minOut, "")
                    returns (uint256 bought)
                {
                    uint256 refund = bought - _repay(
                        c.lendingPool, tokenOut, buyRisk ? c.debtRisk : c.debtLoan, bought
                    );
                    if (buyRisk) { gotLoan = 0; gotRisk += refund; }
                    else { gotRisk = 0; gotLoan += refund; }
                } catch {
                    // Keep liquidation live: failed swaps roll back their transfers.
                    // The balance is protocol-owned, isolated by the vault's existing snapshots.
                }
            }
        }

        // Fresh debt reads also cover repay caps/rounding. Never refund ahead of either lender.
        if (_debt(c.lendingPool, c.debtRisk) > 0 || _debt(c.lendingPool, c.debtLoan) > 0) {
            if (gotRisk > 0) emit SurplusRetained(c.debtRisk, c.debtLoan, c.risk, gotRisk);
            if (gotLoan > 0) emit SurplusRetained(c.debtRisk, c.debtLoan, c.loan, gotLoan);
            return (0, 0);
        }
        return (gotRisk, gotLoan);
    }

    function _debt(address pool, uint256 id) private view returns (uint256 amount) {
        (amount,) = ISurplusLendingPool(pool).getCurrentDebt(id);
    }

    function _repay(address pool, address token, uint256 id, uint256 available) private returns (uint256) {
        if (available == 0) return 0;
        uint256 due = _debt(pool, id);
        uint256 amount = available < due ? available : due;
        if (amount == 0) return 0;
        _approveIfNeeded(token, pool, amount);
        return ISurplusLendingPool(pool).repay(address(this), id, amount);
    }

    function _approveIfNeeded(address token, address spender, uint256 amount) private {
        if (ISurplusToken(token).allowance(address(this), spender) < amount) {
            (bool ok, bytes memory ret) = token.call(
                abi.encodeWithSelector(ISurplusToken.approve.selector, spender, type(uint256).max)
            );
            if (!(ok && (ret.length == 0 || abi.decode(ret, (bool))))) revert TokenCallFailed();
        }
    }
}
