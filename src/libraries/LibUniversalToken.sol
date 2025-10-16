// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../Types/Structs/UniversalToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library LibUniversalToken {
    using SafeERC20 for IERC20;

    error WrongMsgValue(uint256 expected, uint256 got);
    error NativeTransferFailed();
    error ERC20ReceiveMismatch(uint256 expected, uint256 received);

    function isNativeToken(UniversalToken uToken) internal pure returns (bool){
        return UniversalToken.unwrap(uToken) == address(0);
    }
    /// @notice 收币（ETH 或 ERC20）。返回“实际收到”的数量
    function receiveToken(UniversalToken uToken, uint256 amount)
    internal
    returns (uint256 received)
    {
        if (isNativeToken(uToken)) {
            if (msg.value != amount) revert WrongMsgValue(amount, msg.value);
            return amount;
        } else {
            if (msg.value != 0) revert WrongMsgValue(0, msg.value);
            uint256 beforeBal = IERC20(UniversalToken.unwrap(uToken)).balanceOf(address(this));
            IERC20(UniversalToken.unwrap(uToken)).safeTransferFrom(msg.sender, address(this), amount);
            uint256 afterBal = IERC20(UniversalToken.unwrap(uToken)).balanceOf(address(this));
            received = afterBal - beforeBal;
            return received;
        }
    }

    /// @notice 转币（ETH 或 ERC20）。
    function sendToken(UniversalToken uToken, address account, uint256 amount) internal {
        if (isNativeToken(uToken)) {
            (bool success,) = payable(account).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(UniversalToken.unwrap(uToken)).safeTransfer(account, amount);
        }
    }

    /// @notice 查询任意账户余额
    function balanceOf(UniversalToken uToken, address account) internal view returns (uint256) {
        if (isNativeToken(uToken)) {
            return account.balance;
        } else {
            return IERC20(UniversalToken.unwrap(uToken)).balanceOf(account);
        }
    }

    function decimals(UniversalToken uToken) internal view returns (uint8){
        if (isNativeToken(uToken)) {
            uint256 one = 1 ether;
            uint8 _decimals = 0;
            while (one > 1) {
                one /= 10;
                _decimals++;
            }
            return _decimals;
        } else {
            return IERC20Metadata(UniversalToken.unwrap(uToken)).decimals();
        }
    }
}