// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../../base/UniversalToken.sol";
import {IGeneralShare} from "../interfaces/IGeneralShare.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract GeneralShare is UniversalToken, IGeneralShare, ReentrancyGuard, Ownable {
    // Events
    event ShareCreated(uint256 shareId, uint256 startT, uint256 endT, uint256 totalReward, uint256 totalPrincipal);
    event RewardsAccrued(uint256 shareId, uint256 recycledT, uint256 recycledRewards);
    event ShareholderAdded(address  shareholder, uint256 shareId, uint256 startTime, uint256 grantedReward, uint256 grantedPrincipal);
    event FundsAllocated(uint256 shareId, uint256 allocatedReward, uint256 allocatedPrincipal);
    event StakeRewardsClaimed(uint256 shareId, uint256 amount);
    event StakePrincipalClaimed(uint256 shareId, uint256 amount);
    event RewardsClaimed(address  shareholder, uint256 shareId, uint256 amount);
    event PrincipalClaimed(address  shareholder, uint256 shareId, uint256 amount);
    event RewardsCollected(uint256 amount);
    event Recycled(uint256 shareId, uint256 amount);

    bytes4 immutable public CLAIM_REWARDS_SELECTOR;
    bytes4 immutable public CLAIM_PRINCIPAL_SELECTOR;

    address  public  stakecore;
    ShareInfo[] public shareInfos;
    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) public shareholdersInfo;
    uint256 heldFunds;

    receive() external payable {}

    constructor(address owner, address _stakecore, IERC20 token, bytes4 claimRewardsSelector, bytes4 claimPrincipalSelector) UniversalToken(token) Ownable(owner){
        stakecore = _stakecore;
        CLAIM_REWARDS_SELECTOR = claimRewardsSelector;
        CLAIM_PRINCIPAL_SELECTOR = claimPrincipalSelector;
    }

    function initStakeCore(address _stakecore) external onlyOwner nonReentrant {
        if (address(stakecore) != address(0)) revert StakeCoreAlreadySet();
        if (_stakecore == address(0)) revert InvalidParameter("stakecore");

        stakecore = _stakecore;
    }

    function newShare(bytes calldata claimRewardArgs, bytes calldata claimPrincipalArgs, uint256 startT, uint256 endT, uint256 totalReward, uint256 totalPrincipal) external onlyOwner nonReentrant {
        if (startT >= endT) revert InvalidParameter("time");
        if (totalReward + totalPrincipal == 0) revert InvalidParameter("totals");

        shareInfos.push(
            ShareInfo({
                claimRewardArgs: claimRewardArgs,
                claimPrincipalArgs: claimPrincipalArgs,

                startTime: startT,
                recycledTime: startT,
                endTime: endT,

                totalReward: totalReward,
                claimedReward: 0,
                withdrawnReward: 0,
                grantedReward: 0,

                totalRecycledReward: 0,
                withdrawnRecycledReward: 0,

                totalPrincipal: totalPrincipal,
                claimedPrincipal: 0,
                withdrawnPrincipal: 0,
                grantedPrincipal: 0
            })
        );

        emit ShareCreated(shareInfos.length - 1, startT, endT, totalReward, totalPrincipal);
    }

    function allocateFunds(uint256 shareId, uint256 allocatedReward, uint256 allocatedPrincipal) external onlyOwner nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        uint256 freeFunds = balance() - heldFunds;
        if (allocatedReward + allocatedPrincipal > freeFunds) revert AmountExceedsBalance();
        ShareInfo storage shareInfo = shareInfos[shareId];
        if (allocatedReward + shareInfo.claimedReward > shareInfo.totalReward) revert InvalidParameter("allocatedReward");
        if (allocatedPrincipal + shareInfo.claimedPrincipal > shareInfo.totalPrincipal) revert InvalidParameter("allocatedPrincipal");
        shareInfo.claimedReward += allocatedReward;
        shareInfo.claimedPrincipal += allocatedPrincipal;
        heldFunds += (allocatedReward + allocatedPrincipal);
        emit FundsAllocated(shareId, allocatedReward, allocatedPrincipal);
    }

    function accrueRewards(uint256 shareId, uint256 recycledT) external onlyOwner nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo memory shareInfo = shareInfos[shareId];
        if (recycledT <= shareInfo.recycledTime || recycledT > shareInfo.endTime || recycledT > block.timestamp) revert  InvalidParameter("recycledT");

        uint256 ungrantedReward = shareInfo.totalReward - shareInfo.grantedReward - shareInfo.totalRecycledReward;
        uint256 recycledReward = ungrantedReward * (recycledT - shareInfo.recycledTime) / (shareInfo.endTime - shareInfo.recycledTime);

        ShareInfo storage shareInfoStorage = shareInfos[shareId];
        shareInfoStorage.totalRecycledReward += recycledReward;
        shareInfoStorage.recycledTime = recycledT;
        emit RewardsAccrued(shareId, recycledT, recycledReward);
    }

    function recycle(uint256 shareId, uint256 amount) external onlyOwner nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo memory shareInfo = shareInfos[shareId];

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

    function addShareholder(address _owner, uint256 shareId, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyOwner nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        _addShareholder(_owner, shareId, shareInfos[shareId].startTime, _grantedReward, _grantedPrincipal);
    }

    function addShareholder2(address _owner, uint256 shareId, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyOwner nonReentrant {
        _addShareholder(_owner, shareId, _startTime, _grantedReward, _grantedPrincipal);
    }


    function _addShareholder(address _owner, uint256 shareId, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) private {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo memory shareInfo = shareInfos[shareId];

        if (shareInfo.grantedPrincipal + _grantedPrincipal > shareInfo.totalPrincipal) revert InvalidParameter("grantedPrincipal");
        if (_startTime < shareInfo.recycledTime || _startTime >= shareInfo.endTime) revert InvalidParameter("startTime");

        uint256 unrecycledReward = _calUnrecycledReward(shareInfo, _grantedReward, _startTime);
        uint256 needtoRecycleReward = _calNeedToRecycleReward(shareInfo, _grantedReward, _startTime);


        if (shareInfo.grantedReward + shareInfo.totalRecycledReward + _grantedReward + unrecycledReward > shareInfo.totalReward) revert InvalidParameter("grantedReward");
        if (shareholdersInfo[_getShareHolderKeyHash(_owner, shareId)].owner != address(0)) revert HolderAlreadyExists();
        shareholders.push(ShareHolderKey({
            owner: _owner,
            shareId: shareId
        }));

        shareholdersInfo[_getShareHolderKeyHash(_owner, shareId)] = ShareholderInfo({
            owner: _owner,
            shareId: shareId,
            preRecycledReward: needtoRecycleReward,
            grantedReward: _grantedReward,
            withdrawnReward: 0,
            grantedPrincipal: _grantedPrincipal,
            withdrawnPrincipal: 0
        });
        shareInfos[shareId].totalRecycledReward += unrecycledReward;
        shareInfos[shareId].grantedReward += _grantedReward;
        shareInfos[shareId].grantedPrincipal += _grantedPrincipal;

        emit ShareholderAdded(_owner, shareId, _startTime, _grantedReward, _grantedPrincipal);
    }

    function claimStakeRewards(uint256 shareId) external nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo storage shareInfo = shareInfos[shareId];

        uint256 _before = balance();
        _claimStakeRewards(shareInfo.claimRewardArgs);
        uint256 _after = balance();

        uint256 amount = _after - _before;
        uint256 maxAmount = shareInfo.totalReward - shareInfo.claimedReward;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        shareInfo.claimedReward += amount;
        heldFunds += amount;
        emit StakeRewardsClaimed(shareId, amount);
    }

    function claimStakePrincipal(uint256 shareId) external nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo storage shareInfo = shareInfos[shareId];

        uint256 _before = balance();
        _claimStakePrincipal(shareInfo.claimPrincipalArgs);
        uint256 _after = balance();

        uint256 amount = _after - _before;
        uint256 maxAmount = shareInfo.totalPrincipal - shareInfo.claimedPrincipal;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        shareInfos[shareId].claimedPrincipal += amount;
        heldFunds += amount;
        emit StakePrincipalClaimed(shareId, amount);
    }

    function withdrawRewards(uint256 shareId) external nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, shareId)];
        if (info.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlockedReward = calculateShareholderRewards(info, shareId);
        if (totalUnlockedReward <= info.withdrawnReward) revert AmountExceedsWithdrawable();
        uint256 withdrawableReward = totalUnlockedReward - info.withdrawnReward;

        ShareInfo storage shareInfo = shareInfos[info.shareId];
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
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, shareId)];
        if (info.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlockedPrincipal = calculateShareholderPrincipal(info.grantedPrincipal, info.shareId);
        if (totalUnlockedPrincipal <= info.withdrawnPrincipal) revert AmountExceedsWithdrawable();
        uint256 withdrawablePrincipal = totalUnlockedPrincipal - info.withdrawnPrincipal;

        ShareInfo storage shareInfo = shareInfos[info.shareId];
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

    function calculateShareholderRewards(ShareholderInfo memory holderinfo, uint256 shareId) internal view returns (uint256){
        if (shareInfos[shareId].totalReward == 0 || shareInfos[shareId].claimedReward == 0) {
            return 0;
        }

        uint256 gross = ((holderinfo.grantedReward + holderinfo.preRecycledReward) * shareInfos[shareId].claimedReward) / shareInfos[shareId].totalReward;
        return gross > holderinfo.preRecycledReward ? gross - holderinfo.preRecycledReward : 0;
    }


    function calculateShareholderPrincipal(uint256 _shareholderGrantedPrincipal, uint256 shareId) internal view returns (uint256){
        if (shareInfos[shareId].totalPrincipal == 0) {
            return 0;
        }

        return _shareholderGrantedPrincipal * shareInfos[shareId].claimedPrincipal / shareInfos[shareId].totalPrincipal;
    }

    function collect() external onlyOwner nonReentrant returns (uint256) {
        //  withdraw extra token from this contract
        uint256 bal = balance();
        uint256 lockedReward = heldFunds;
        require(bal >= lockedReward, "Not enough token");
        uint256 extraToken = bal - lockedReward;
        _sendToken(msg.sender, extraToken);
        emit RewardsCollected(extraToken);
        return extraToken;
    }

    function getShareholderInfo(address _shareholder, uint256 shareId) public view returns (ShareholderInfo memory) {
        return shareholdersInfo[_getShareHolderKeyHash(_shareholder, shareId)];
    }

    function _claimStakeRewards(bytes memory args) private {
        (bool ok,bytes memory retData) = stakecore.call(abi.encodePacked(CLAIM_REWARDS_SELECTOR, args));
        if (!ok) {
            if (retData.length > 0) {
                assembly {
                    revert(add(retData, 0x20), mload(retData))
                }
            } else {
                revert("DynamicCall: call failed");
            }
        }
    }

    function _claimStakePrincipal(bytes memory args) private {
        (bool ok,bytes memory retData) = stakecore.call(abi.encodePacked(CLAIM_PRINCIPAL_SELECTOR, args));
        if (!ok) {
            if (retData.length > 0) {
                assembly {
                    revert(add(retData, 0x20), mload(retData))
                }
            } else {
                revert("DynamicCall: call failed");
            }
        }
    }

    function _calUnrecycledReward(ShareInfo memory shareInfo, uint256 grantedReward, uint256 startT) private pure returns (uint256) {
        return grantedReward * (startT - shareInfo.recycledTime) / (shareInfo.endTime - startT);
    }

    function _calNeedToRecycleReward(ShareInfo memory shareInfo, uint256 grantedReward, uint256 startT) private pure returns (uint256){
        return grantedReward * (startT - shareInfo.startTime) / (shareInfo.endTime - startT);
    }

    function _getShareHolderKeyHash(address owner, uint256 shareId) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, shareId));
    }
}
