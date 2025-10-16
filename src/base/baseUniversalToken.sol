// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../Types/Structs/UniversalToken.sol";
import {LibUniversalToken} from "../libraries/LibUniversalToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


abstract contract BaseUniversalToken {
    using LibUniversalToken for UniversalToken;
    using SafeERC20 for IERC20;

    UniversalToken internal immutable _TOKEN;

    constructor(IERC20 __token){
        _TOKEN = UniversalToken.wrap(address(__token));
    }

    receive() external payable {}

    function token() public view virtual returns (IERC20){
        return IERC20(UniversalToken.unwrap(_TOKEN));
    }

    function isNativeToken() public view returns (bool){
        return _TOKEN.isNativeToken();
    }

    function _sendToken(address account, uint256 amount) internal {
        _TOKEN.sendToken(account, amount);
    }

    function _receiveToken(uint256 amount) internal {
        uint256 received = _TOKEN.receiveToken(amount);
        if (received != amount) revert LibUniversalToken.ERC20ReceiveMismatch(amount, received);
    }

    function balance() public view returns (uint256){
        return _TOKEN.balanceOf(address(this));
    }

    function decimals() public view returns (uint8){
        return _TOKEN.decimals();
    }
}