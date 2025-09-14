// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignedCredential} from "../../Types/Structs/Credentials.sol";
import {BaseCredential} from "../../base/baseCredential.sol";
import {BaseShareCore} from "./basesharecore.sol";
import {ShareCore} from "./sharecore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract Subscription is ShareCore, BaseCredential {
    using SafeERC20 for IERC20;

    // Events
    event SubscribedByUSDT(address shareholder, uint256 shareId, uint256 grantedReward, uint256 grantedPrincipal, uint256 amount);
    event SubscribedByToken(address shareholder, uint256 shareId, uint256 grantedReward, uint256 grantedPrincipal, uint256 amount);
    event USDTWithdrawn(address account, uint256 amount);
    event TokenWithdrawn(address account, uint256 amount);

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


    constructor(address admin, address governor, address _stakecore, IERC20 token, address usdtContAddr, bool enableShareholderWhiteList)ShareCore(admin, _stakecore, token, enableShareholderWhiteList) BaseCredential(governor){
        USDT = IERC20(usdtContAddr);
    }

    function withdrawUsdt(uint256 amount) external onlyAdmin nonReentrant {
        if (amount + withdrawnUsdt > depositedUsdt) revert  AmountExceedsWithdrawable();
        withdrawnUsdt += amount;
        USDT.safeTransfer(msg.sender, amount);
        emit USDTWithdrawn(msg.sender, amount);
    }

    function withdrawToken(uint256 amount) external onlyAdmin nonReentrant {
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
        if (ENABLE_SHAREHOLDER_WHITE_LIST) {
            _checkRole(SHAREHOLDER_ROLE, _owner);
        }

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
        if (ENABLE_SHAREHOLDER_WHITE_LIST) {
            _checkRole(SHAREHOLDER_ROLE, _owner);
        }

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
            shareholder.preRecycledReward += needtoRecycleReward;
            shareholder.grantedReward += _grantedReward;
            shareholder.grantedPrincipal += _grantedPrincipal;
            shareholderFunds[holderkey].depositedToken += _depositedToken;
            shareholderFunds[holderkey].depositedUsdt += _depositedUsdt;
        }

        shareInfo.grantedReward += _grantedReward;
        shareInfo.grantedPrincipal += _grantedPrincipal;
    }

    function collect(IERC20 erc20) external override onlyAdmin nonReentrant returns (uint256) {
        uint256 bal;
        uint256 heldToken;
        if (erc20 == token()) {
            bal = balance();
            heldToken = heldFunds;
        } else if (erc20 == USDT) {
            bal = erc20.balanceOf(address(this));
            heldToken = depositedUsdt - withdrawnUsdt;
        } else if (address(erc20) == address(0)) {
            bal = address(this).balance;
            heldToken = 0;
        } else {
            bal = erc20.balanceOf(address(this));
            heldToken = 0;
        }

        if (bal <= heldToken) revert NoExcessTokens();
        uint256 extraToken = bal - heldToken;
        if (address(erc20) == address(0)) {
            (bool success,) = payable(msg.sender).call{value: extraToken}("");
            require(success);
        } else {
            erc20.safeTransfer(msg.sender, extraToken);
        }

        emit ExcessCollected(address(erc20), extraToken);
        return extraToken;
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

    function grantRole(bytes32 role, address account) public override(BaseShareCore, AccessControl) onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32, address) public pure override(BaseShareCore, AccessControl) {
        revert Forbid();
    }

    function renounceRole(bytes32, address) public pure override(BaseShareCore, AccessControl) {
        revert Forbid();
    }
}
