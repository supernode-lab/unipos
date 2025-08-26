// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface BaseError {
    error InvalidParameter(string key);
    error IllegalMsgValue();
    error UnauthorizedCaller(address);
    error Forbid();
}