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
    address  public  stakecore;
    bytes4 immutable public CLAIM_REWARDS_SELECTOR;
    bytes4 immutable public CLAIM_PRINCIPAL_SELECTOR;

    ShareInfo[] public shareInfos;

    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) public shareholdersInfo;

    // Events
    event ShareCreated(uint256 shareId, uint256 startT, uint256 endT, uint256 totalReward, uint256 totalPrincipal);
    event RewardsAccrued(uint256 shareId, uint256 gatherT, uint256 recycledRewards);
    event ShareholderAdded(address  shareholder, uint256 shareId, uint256 startTime, uint256 grantedReward, uint256 grantedPrincipal);
    event StakeRewardsClaimed(uint256 shareId, uint256 amount);

    event StakePrincipalClaimed(uint256 shareId, uint256 amount);
    event RewardsClaimed(address  shareholder, uint256 shareId, uint256 amount);
    event PrincipalClaimed(address  shareholder, uint256 shareId, uint256 amount);

    event RewardsCollected(uint256 amount);
    event Gathered(uint256 shareId, uint256 amount);


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

    function accrueRewards(uint256 shareId, uint256 gatherT) external onlyOwner nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo memory shareInfo = shareInfos[shareId];
        if (gatherT <= shareInfo.recycledTime || gatherT > shareInfo.endTime || gatherT > block.timestamp) revert StartTimeOutOfRange(gatherT, shareInfo.recycledTime, shareInfo.endTime);

        uint256 ungrantedReward = shareInfo.totalReward - shareInfo.grantedReward - shareInfo.totalRecycledReward;
        uint256 recycledReward = ungrantedReward * (gatherT - shareInfo.recycledTime) / (shareInfo.endTime - shareInfo.recycledTime);

        ShareInfo storage shareInfoStorage = shareInfos[shareId];
        shareInfoStorage.totalRecycledReward += recycledReward;
        shareInfoStorage.recycledTime = gatherT;
        emit RewardsAccrued(shareId, gatherT, recycledReward);
    }

    function gather(uint256 shareId, uint256 amount) external onlyOwner nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareInfo memory shareInfo = shareInfos[shareId];

        uint256 available = shareInfo.totalRecycledReward - shareInfo.withdrawnRecycledReward;
        if (amount > available) revert AmountExceedsWithdrawable(amount, available);

        uint256 withdrawableReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (amount > withdrawableReward) revert AmountExceedsBalance(amount, withdrawableReward);
        shareInfos[shareId].withdrawnReward += amount;
        shareInfos[shareId].withdrawnRecycledReward += amount;
        _sendToken(msg.sender, amount);
        emit Gathered(shareId, amount);
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

        if (shareInfo.grantedPrincipal + _grantedPrincipal > shareInfo.totalPrincipal) revert InsufficientUnallocatedPrincipal();
        if (_startTime < shareInfo.recycledTime || _startTime >= shareInfo.endTime) revert StartTimeOutOfRange(_startTime, shareInfo.recycledTime, shareInfo.endTime);

        uint256 unrecycledReward = _calUnrecycledReward(shareInfo, _grantedReward, _startTime);
        uint256 needtoRecycleReward = _calNeedToRecycleReward(shareInfo, _grantedReward, _startTime);


        if (shareInfo.grantedReward + shareInfo.totalRecycledReward + _grantedReward + unrecycledReward > shareInfo.totalReward) revert InsufficientUnallocatedRewards();
        if (shareholdersInfo[_getShareHolderKeyHash(_owner, shareId)].owner != address(0)) revert HolderAlreadyExists();
        shareholders.push(ShareHolderKey({
            owner: _owner,
            shareId: shareId
        }));

        shareholdersInfo[_getShareHolderKeyHash(_owner, shareId)] = ShareholderInfo({
            owner: _owner,
            shareId: shareId,
            _recycledReward: needtoRecycleReward,
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
        uint256 _before = balance();
        _claimStakeRewards(shareInfos[shareId].claimRewardArgs);
        uint256 _after = balance();
        uint256 amount = _after - _before;
        shareInfos[shareId].claimedReward += amount;
        emit StakeRewardsClaimed(shareId, amount);
    }

    function claimStakePrincipal(uint256 shareId) external nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        uint256 _before = balance();
        _claimStakePrincipal(shareInfos[shareId].claimPrincipalArgs);
        uint256 _after = balance();
        uint256 amount = _after - _before;
        shareInfos[shareId].claimedPrincipal += amount;
        emit StakePrincipalClaimed(shareId, amount);
    }

    function claimRewards(uint256 shareId) external nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, shareId)];
        if (info.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        ShareInfo storage shareInfo = shareInfos[info.shareId];
        uint256 claimableTotalReward = calculateShareholderRewards(info, shareId);
        if (claimableTotalReward <= info.withdrawnReward) revert NoRewards();
        uint256 claimableReward = claimableTotalReward - info.withdrawnReward;
        uint256 withdrawableReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (withdrawableReward == 0) revert InsufficientRewards();
        if (withdrawableReward < claimableReward) {
            claimableReward = withdrawableReward;
        }

        info.withdrawnReward += claimableReward;
        shareInfo.withdrawnReward += claimableReward;
        _sendToken(msg.sender, claimableReward);
        emit RewardsClaimed(msg.sender, shareId, claimableReward);
    }

    function claimPrincipal(uint256 shareId) external nonReentrant {
        if (shareId >= shareInfos.length) revert InvalidShareId();
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, shareId)];
        if (info.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 claimableTotalPrincipal = calculateShareholderPrincipal(info.grantedPrincipal, info.shareId);
        if (claimableTotalPrincipal <= info.withdrawnPrincipal) revert NoPrincipal();
        uint256 claimablePrincipal = claimableTotalPrincipal - info.withdrawnPrincipal;
        info.withdrawnPrincipal = claimableTotalPrincipal;
        _sendToken(msg.sender, claimablePrincipal);
        emit PrincipalClaimed(msg.sender, shareId, claimablePrincipal);
    }

    function calculateShareholderRewards(ShareholderInfo memory holderinfo, uint256 shareId) internal view returns (uint256){
        if (shareInfos[shareId].totalReward == 0 || shareInfos[shareId].claimedReward == 0) {
            return 0;
        }

        uint256 gross = ((holderinfo.grantedReward + holderinfo._recycledReward) * shareInfos[shareId].claimedReward) / shareInfos[shareId].totalReward;
        return gross > holderinfo._recycledReward ? gross - holderinfo._recycledReward : 0;
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
        uint256 lockedReward;
        uint256 shareIdsLength = shareInfos.length;
        for (uint256 i = 0; i < shareIdsLength; i++) {
            lockedReward += (shareInfos[i].claimedReward + shareInfos[i].claimedPrincipal - shareInfos[i].withdrawnReward - shareInfos[i].withdrawnPrincipal);
        }

        require(bal >= lockedReward, "Not enough token");
        _sendToken(msg.sender, bal - lockedReward);
        emit RewardsCollected(bal - lockedReward);
        return bal - lockedReward;
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
