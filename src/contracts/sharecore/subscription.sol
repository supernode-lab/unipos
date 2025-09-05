// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignedCredential} from "../../Types/Structs/Credentials.sol";
import {BaseCredential} from "../../base/baseCredential.sol";
import {ShareCore} from "./sharecore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract Subscription is ShareCore, BaseCredential {
    using SafeERC20 for IERC20;

    // Events
    event SubscribedByUSDT(address  shareholder, uint256 shareId, uint256 grantedReward, uint256 grantedPrincipal, uint256 amount);
    event SubscribedByToken(address  shareholder, uint256 shareId, uint256 grantedReward, uint256 grantedPrincipal, uint256 amount);
    event USDTWithdrawn(address  account, uint256 amount);
    event TokenWithdrawn(address  account, uint256 amount);
    event USDTCollected(uint256 amount);

    struct ShareholderFund {
        uint256 depositedToken;
        uint256 depositedUsdt;
    }

    uint256 private constant PRECISION = 1e18;
    IERC20 public immutable USDT;
    mapping(bytes32 => ShareholderFund) private shareholderFunds;

    uint256 public depositedUsdt;
    uint256 public withdrawnUsdt;

    uint256 public depositedToken;
    uint256 public withdrawnToken;


    constructor(address owner, address _stakecore, IERC20 token, address usdtContAddr)ShareCore(owner, _stakecore, token) BaseCredential(owner){
        USDT = IERC20(usdtContAddr);
    }

    function withdrawUsdt(uint256 amount) external onlyOwner nonReentrant {
        if (amount + withdrawnUsdt > depositedUsdt) revert  AmountExceedsWithdrawable();
        withdrawnUsdt += amount;
        USDT.safeTransfer(msg.sender, amount);
        emit USDTWithdrawn(msg.sender, amount);
    }

    function withdrawToken(uint256 amount) external onlyOwner nonReentrant {
        if (amount + withdrawnToken > depositedToken) revert  AmountExceedsWithdrawable();
        withdrawnToken += amount;
        heldFunds -= amount;
        _sendToken(msg.sender, amount);
        emit TokenWithdrawn(msg.sender, amount);
    }


    function subscribeByUsdt(
        address _owner,
        uint256 _shareId,
        uint256 amount,
        uint256 _grantedReward,
        uint256 _grantedPrincipal,
        SignedCredential calldata sc
    )
    validateAndBurnCred(sc, abi.encode(_owner, _shareId, amount, _grantedReward, _grantedPrincipal)) nonReentrant external {
        if (!shareInfos[_shareId].isSet) revert InvalidShareId(_shareId);

        depositedUsdt += amount;
        USDT.safeTransferFrom(msg.sender, address(this), amount);
        _addShareholder(_owner, _shareId, _grantedReward, _grantedPrincipal, 0, amount);
        emit SubscribedByUSDT(_owner, _shareId, _grantedReward, _grantedPrincipal, amount);
    }

    function subscribeByToken(
        address _owner,
        uint256 _shareId,
        uint256 amount,
        uint256 _grantedReward,
        uint256 _grantedPrincipal,
        SignedCredential calldata sc
    )
    validateAndBurnCred(sc, abi.encode(_owner, _shareId, amount, _grantedReward, _grantedPrincipal)) nonReentrant external {
        if (!shareInfos[_shareId].isSet) revert InvalidShareId(_shareId);

        depositedToken += amount;
        heldFunds += amount;
        _receiveToken(amount);
        _addShareholder(_owner, _shareId, _grantedReward, _grantedPrincipal, amount, 0);
        emit SubscribedByToken(_owner, _shareId, _grantedReward, _grantedPrincipal, amount);
    }

    function _addShareholder(
        address _owner,
        uint256 _shareId,
        uint256 _grantedReward,
        uint256 _grantedPrincipal,
        uint256 _depositedToken,
        uint256 _depositedUsdt) private {
        ShareInfo storage shareInfo = shareInfos[_shareId];
        if (shareInfo.grantedPrincipal + _grantedPrincipal > shareInfo.totalPrincipal) revert InvalidParameter("grantedPrincipal");

        uint256 recycledTime = shareInfo.recycledTime;
        uint256 endTime = shareInfo.endTime;
        uint256 needtoRecycleReward = _calNeedToRecycleReward(recycledTime, shareInfo.startTime, endTime, _grantedReward);
        if (shareInfo.grantedReward + shareInfo.totalRecycledReward + _grantedReward > shareInfo.totalReward) revert InvalidParameter("grantedReward");

        bytes32 holderkey = _getShareHolderKeyHash(_owner, _shareId);
        ShareholderInfo storage shareholder = shareholdersInfos[holderkey];
        if (shareholder.owner == address(0)) {
            shareholders.push(ShareHolderKey({
                owner: _owner,
                shareId: _shareId
            }));

            shareholdersInfos[holderkey] = ShareholderInfo({
                owner: _owner,
                shareId: _shareId,
                preRecycledReward: needtoRecycleReward,
                grantedReward: _grantedReward,
                withdrawnReward: 0,
                grantedPrincipal: _grantedPrincipal,
                withdrawnPrincipal: 0

            });
            shareholderFunds[holderkey] = ShareholderFund({
                depositedToken: _depositedToken,
                depositedUsdt: _depositedUsdt
            });
        } else {
            shareholder.grantedReward += _grantedReward;
            shareholder.grantedPrincipal += _grantedPrincipal;
            shareholderFunds[holderkey].depositedToken += _depositedToken;
            shareholderFunds[holderkey].depositedUsdt += _depositedUsdt;
        }

        shareInfo.grantedReward += _grantedReward;
        shareInfo.grantedPrincipal += _grantedPrincipal;
    }

    function collectUsdt() external onlyOwner nonReentrant returns (uint256) {
//  withdraw extra token from this contract
        uint256 balance = USDT.balanceOf(address(this));
        uint256 remain = depositedUsdt - withdrawnUsdt;
        require(balance > remain, "Not enough token");
        USDT.safeTransfer(msg.sender, balance - remain);
        emit USDTCollected(balance - remain);
        return balance - remain;
    }

    function getShareholderFund(address _shareholder, uint256 shareId) public view returns (ShareholderFund memory) {
        return shareholderFunds[_getShareHolderKeyHash(_shareholder, shareId)];
    }

    function addShareholder(address, uint256, uint256, uint256) external pure override {
        revert Forbid();
    }

    function addShareholderWithStartTime(address, uint256, uint256, uint256, uint256) external pure override {
        revert Forbid();
    }
}
