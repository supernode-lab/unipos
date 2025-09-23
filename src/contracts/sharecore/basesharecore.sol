// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseUniversalToken} from "../../base/BaseUniversalToken.sol";
import {IGeneralShare} from "../interfaces/IGeneralShare.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
abstract contract BaseShareCore is BaseUniversalToken, IGeneralShare, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant SHAREHOLDER_ROLE = keccak256("SHAREHOLDER");

    bool public immutable ENABLE_SHAREHOLDER_WHITE_LIST;

    address  public  stakecore;
    uint256[] public shareIds;
    mapping(uint256 shareId => ShareInfo) internal shareInfos;
    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) internal shareholdersInfos;
    uint256 public heldFunds;

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }

    constructor(address admin, address _stakecore, IERC20 token, bool enableShareholderWhiteList) BaseUniversalToken(token) {
        stakecore = _stakecore;
        ENABLE_SHAREHOLDER_WHITE_LIST = enableShareholderWhiteList;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function initStakeCore(address _stakecore) external virtual onlyAdmin nonReentrant {
        if (address(stakecore) != address(0)) revert StakeCoreAlreadySet();
        if (_stakecore == address(0)) revert InvalidParameter("stakecore");

        stakecore = _stakecore;
    }

    function claimStakeRewards(uint256 shareId) external virtual;

    function claimStakePrincipal(uint256 shareId) external virtual;

    function accrueRewards(uint256 shareId, uint256 recycledT) external onlyAdmin nonReentrant {
        ShareInfo memory shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);

        if (recycledT <= shareInfo.recycledTime || recycledT > shareInfo.endTime || recycledT > block.timestamp) revert  InvalidParameter("recycledT");

        uint256 ungrantedReward = shareInfo.totalReward - shareInfo.grantedReward - shareInfo.totalRecycledReward;
        uint256 recycledReward = ungrantedReward * (recycledT - shareInfo.recycledTime) / (shareInfo.endTime - shareInfo.recycledTime);

        ShareInfo storage shareInfoStorage = shareInfos[shareId];
        shareInfoStorage.totalRecycledReward += recycledReward;
        shareInfoStorage.recycledTime = recycledT;
        emit RewardsAccrued(shareId, recycledT, recycledReward);
    }

    function recycle(uint256 shareId, uint256 amount) external onlyAdmin nonReentrant {
        ShareInfo memory shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);

        uint256 available = shareInfo.totalRecycledReward - shareInfo.withdrawnRecycledReward;
        if (amount > available) revert AmountExceedsWithdrawable();

        uint256 withdrawableReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (amount > withdrawableReward) revert AmountExceedsBalance();
        shareInfos[shareId].withdrawnReward += amount;
        shareInfos[shareId].withdrawnRecycledReward += amount;
        heldFunds -= amount;
        _sendToken(msg.sender, amount);
        emit Recycled(shareId, amount);
    }

    function addShareholder(address _owner, uint256 shareId, uint256 _grantedReward, uint256 _grantedPrincipal) external virtual onlyAdmin nonReentrant {
        if (!shareInfos[shareId].isSet) revert InvalidShareId(shareId);
        _addShareholder(_owner, shareId, shareInfos[shareId].recycledTime, _grantedReward, _grantedPrincipal);
    }

    function addShareholderWithStartTime(address _owner, uint256 shareId, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) external virtual onlyAdmin nonReentrant {
        _addShareholder(_owner, shareId, _startTime, _grantedReward, _grantedPrincipal);
    }

    function _addShareholder(address _owner, uint256 shareId, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) private {
        if (ENABLE_SHAREHOLDER_WHITE_LIST) {
            _checkRole(SHAREHOLDER_ROLE, _owner);
        }

        ShareInfo storage shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);

        uint256 recycledTime = shareInfo.recycledTime;
        uint256 endTime = shareInfo.endTime;

        if (shareInfo.grantedPrincipal + _grantedPrincipal > shareInfo.totalPrincipal) revert InvalidParameter("grantedPrincipal");
        if (_startTime < recycledTime || _startTime > endTime) revert InvalidParameter("startTime");
        if (_startTime == endTime && _grantedReward != 0) revert InvalidParameter("grantedReward");

        uint256 unrecycledReward = 0;
        uint256 needtoRecycleReward = 0;
        if (_grantedReward != 0) {
            unrecycledReward = _calNeedToRecycleReward(_startTime, recycledTime, endTime, _grantedReward);
            needtoRecycleReward = _calNeedToRecycleReward(_startTime, shareInfo.startTime, endTime, _grantedReward);
        }

        if (shareInfo.grantedReward + shareInfo.totalRecycledReward + _grantedReward + unrecycledReward > shareInfo.totalReward) revert InvalidParameter("grantedReward");
        bytes32 holderkey = _getShareHolderKeyHash(_owner, shareId);
        ShareholderInfo storage shareholder = shareholdersInfos[holderkey];
        if (shareholder.owner == address(0)) {
            shareholders.push(ShareHolderKey({
                owner: _owner,
                shareId: shareId
            }));

            shareholdersInfos[holderkey] = ShareholderInfo({
                owner: _owner,
                shareId: shareId,
                preRecycledReward: needtoRecycleReward,
                grantedReward: _grantedReward,
                withdrawnReward: 0,
                grantedPrincipal: _grantedPrincipal,
                withdrawnPrincipal: 0
            });
        } else {
            shareholder.preRecycledReward += needtoRecycleReward;
            shareholder.grantedReward += _grantedReward;
            shareholder.grantedPrincipal += _grantedPrincipal;
        }

        shareInfo.totalRecycledReward += unrecycledReward;
        shareInfo.grantedReward += _grantedReward;
        shareInfo.grantedPrincipal += _grantedPrincipal;

        emit ShareholderAdded(_owner, shareId, _startTime, needtoRecycleReward, _grantedReward, _grantedPrincipal);
    }


    function withdrawRewards(uint256 shareId) external nonReentrant {
        ShareInfo storage shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);

        ShareholderInfo storage info = shareholdersInfos[_getShareHolderKeyHash(msg.sender, shareId)];
        if (info.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlockedReward = _calculateShareholderRewards(info, shareId);
        if (totalUnlockedReward <= info.withdrawnReward) revert AmountExceedsWithdrawable();
        uint256 withdrawableReward = totalUnlockedReward - info.withdrawnReward;

        uint256 balanceReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (balanceReward == 0) revert AmountExceedsBalance();
        if (balanceReward < withdrawableReward) {
            withdrawableReward = balanceReward;
        }

        info.withdrawnReward += withdrawableReward;
        shareInfo.withdrawnReward += withdrawableReward;
        heldFunds -= withdrawableReward;
        _sendToken(msg.sender, withdrawableReward);
        emit RewardsClaimed(msg.sender, shareId, withdrawableReward);
    }

    function withdrawPrincipal(uint256 shareId) external nonReentrant {
        ShareInfo storage shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);
        ShareholderInfo storage info = shareholdersInfos[_getShareHolderKeyHash(msg.sender, shareId)];
        if (info.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlockedPrincipal = _calculateShareholderPrincipal(info.grantedPrincipal, info.shareId);
        if (totalUnlockedPrincipal <= info.withdrawnPrincipal) revert AmountExceedsWithdrawable();
        uint256 withdrawablePrincipal = totalUnlockedPrincipal - info.withdrawnPrincipal;

        uint256 balancePrincipal = shareInfo.claimedPrincipal - shareInfo.withdrawnPrincipal;
        if (balancePrincipal == 0) revert AmountExceedsBalance();
        if (balancePrincipal < withdrawablePrincipal) {
            withdrawablePrincipal = balancePrincipal;
        }

        info.withdrawnPrincipal += withdrawablePrincipal;
        shareInfo.withdrawnPrincipal += withdrawablePrincipal;
        heldFunds -= withdrawablePrincipal;
        _sendToken(msg.sender, withdrawablePrincipal);
        emit PrincipalClaimed(msg.sender, shareId, withdrawablePrincipal);
    }

    function collect(IERC20 erc20) external virtual onlyAdmin nonReentrant returns (uint256) {
        uint256 bal;
        uint256 heldToken;
        if (erc20 == token()) {
            bal = balance();
            heldToken = heldFunds;
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

    function shareholdersLength() public view returns (uint256){
        return shareholders.length;
    }

    function getShareholderInfo(address _shareholder, uint256 shareId) public view returns (ShareholderInfo memory) {
        return shareholdersInfos[_getShareHolderKeyHash(_shareholder, shareId)];
    }

    function shareIdsLength() public view returns (uint256){
        return shareIds.length;
    }

    function getShareInfo(uint256 shareId) public view returns (ShareInfo memory){
        return shareInfos[shareId];
    }

    function _calculateShareholderRewards(ShareholderInfo storage holderinfo, uint256 shareId) internal view returns (uint256){
        if (shareInfos[shareId].totalReward == 0 || shareInfos[shareId].claimedReward == 0) {
            return 0;
        }

        uint256 gross = ((holderinfo.grantedReward + holderinfo.preRecycledReward) * shareInfos[shareId].claimedReward) / shareInfos[shareId].totalReward;
        return gross > holderinfo.preRecycledReward ? gross - holderinfo.preRecycledReward : 0;
    }

    function _calculateShareholderPrincipal(uint256 _shareholderGrantedPrincipal, uint256 shareId) internal view returns (uint256){
        if (shareInfos[shareId].totalPrincipal == 0) {
            return 0;
        }

        return _shareholderGrantedPrincipal * shareInfos[shareId].claimedPrincipal / shareInfos[shareId].totalPrincipal;
    }

    function _calNeedToRecycleReward(uint256 startT, uint256 startTime, uint256 endTime, uint256 grantedReward) internal pure returns (uint256){
        return grantedReward * (startT - startTime) / (endTime - startT);
    }

    function _getShareHolderKeyHash(address owner, uint256 shareId) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, shareId));
    }

    function isAdmin(address addr) public view returns (bool){
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function isShareholder(address addr) public view returns (bool){
        return hasRole(SHAREHOLDER_ROLE, addr);
    }

    function grantRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32, address) public virtual pure override {
        revert Forbid();
    }

    function renounceRole(bytes32, address) public virtual pure override {
        revert Forbid();
    }
}
