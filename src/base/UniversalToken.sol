// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseError} from "../contracts/interfaces/BaseError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


abstract contract UniversalToken is BaseError {
    using SafeERC20 for IERC20;

    IERC20 internal immutable _TOKEN;

    constructor(IERC20 __token){
        _TOKEN = __token;
    }

    function token() public view virtual returns (IERC20){
        return _TOKEN;
    }

    function isNativeToken() public view returns (bool){
        return (address(_TOKEN) == address(0));
    }

    function _sendToken(address account, uint256 amount) internal {
        if (isNativeToken()) {
            (bool success,) = payable(account).call{value: amount}("");
            require(success);
        } else {
            _TOKEN.safeTransfer(account, amount);
        }
    }

    function _receiveToken(uint256 amount) internal {
        if (isNativeToken()) {
            if (msg.value != amount) revert IllegalMsgValue();
        } else {
            if (msg.value != 0) revert IllegalMsgValue();
            _TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function balance() public view returns (uint256){
        if (isNativeToken()) {
            return address(this).balance;
        } else {
            return _TOKEN.balanceOf(address(this));
        }
    }
}