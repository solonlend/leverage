// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "./interfaces/IWETH9.sol";
import "./libraries/TransferHelper.sol";

import "./libraries/helpers/Errors.sol";

abstract contract Payments {
    error InsufficientTokenReceived();
    error InsufficientNativeValue();

    address public immutable WETH9;

    modifier avoidUsingNativeEther() {
        require(msg.value == 0, "avoid using native ether");
        _;
    }

    constructor(address _WETH9) {
        WETH9 = _WETH9;
    }

    receive() external payable {
        require(msg.sender == WETH9, Errors.VL_NOT_WETH9);
    }

    function unwrapWETH9(uint256 amount, address recipient) internal {
        require(IWETH9(WETH9).balanceOf(address(this)) >= amount, Errors.VL_INSUFFICIENT_WETH9);
        if (amount > 0) {
            IWETH9(WETH9).withdraw(amount);
            TransferHelper.safeTransferETH(recipient, amount);
        }
    }

    function refundETH(uint256 amount) internal {
        if (amount > 0) TransferHelper.safeTransferETH(msg.sender, amount);
    }

    /// @dev Check the actual recipient, since reserve assets are held by its eToken.
    function pullToken(address token, address payer, address recipient, uint256 value) internal {
        uint256 beforeBalance = IWETH9(token).balanceOf(recipient);
        TransferHelper.safeTransferFrom(token, payer, recipient, value);
        uint256 afterBalance = IWETH9(token).balanceOf(recipient);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance < value) {
            revert InsufficientTokenReceived();
        }
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH9 && msg.value > 0) {
            if (msg.value < value) revert InsufficientNativeValue();
            // pay with WETH9
            IWETH9(WETH9).deposit{value: value}(); // wrap only what is needed to pay
            require(
                IWETH9(WETH9).transfer(recipient, value),
                "transfer failed"
            );
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            pullToken(token, payer, recipient, value);
        }
    }
}
