// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract Whitelist is Ownable {
    address[] private _whitelist;
    mapping(address => bool) private _isInWhitelisted;

    event WhitelistUpdated(address indexed account, bool status);

    modifier onlyOperationWhitelist() {
        require(_isInWhitelisted[msg.sender], "Caller not whitelisted");
        _;
    }

    constructor() Ownable(msg.sender) {
        // 构造函数中直接初始化 Ownable
    }

    function _addToWhitelist(address account) internal {
        require(account != address(0), "Invalid address");
        if (!_isInWhitelisted[account]) {
            _whitelist.push(account);
            _isInWhitelisted[account] = true;
            emit WhitelistUpdated(account, true);
        }
    }

    function _removeFromWhitelist(address account) internal {
        require(account != address(0), "Invalid address");
        if (_isInWhitelisted[account]) {
            for (uint256 i = 0; i < _whitelist.length; i++) {
                if (_whitelist[i] == account) {
                    _whitelist[i] = _whitelist[_whitelist.length - 1];
                    _whitelist.pop();
                    break;
                }
            }
            _isInWhitelisted[account] = false;
            emit WhitelistUpdated(account, false);
        }
    }

    function addToWhitelist(address account) external onlyOwner {
        _addToWhitelist(account);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        _removeFromWhitelist(account);
    }

    // 查询函数
    function isInOperationWhitelist(
        address account
    ) external view returns (bool) {
        return _isInWhitelisted[account];
    }

    function getOperationWhitelistAddresses()
        external
        view
        returns (address[] memory)
    {
        return _whitelist;
    }

    function getOperationWhitelistCount() external view returns (uint256) {
        return _whitelist.length;
    }
} 