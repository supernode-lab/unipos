// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {BaseShareCore} from "./basesharecore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract ShareCore is BaseShareCore {
    // Events
    event Registered(uint256[] shareIds);
    event StakeRewardsClaimedBatch(uint256[] shareIds, uint256[] amounts);

    constructor(address admin, address _stakecore, IERC20 token, bool enableShareholderWhiteList) BaseShareCore(admin, _stakecore, token, enableShareholderWhiteList){
        if (address(_stakecore) != address(0)) {
            if (IStakeCore(_stakecore).token() != token) revert InvalidParameter("stakecore/token");
        }
    }

    function initStakeCore(address _stakecore) external override onlyAdmin nonReentrant {
        if (address(stakecore) != address(0)) revert StakeCoreAlreadySet();
        if (address(_stakecore) == address(0)) revert InvalidParameter("stakecore");
        if (IStakeCore(_stakecore).token() != token()) revert InvalidParameter("stakecore");

        stakecore = _stakecore;
    }

    function registerNewShares() external nonReentrant {
        uint256[] memory _shareIds = IStakeCore(stakecore).getUserStakeIndexes(address(this));
        uint256 curShareIdsLen = shareIds.length;
        if (_shareIds.length == curShareIdsLen) {
            return;
        }

        uint256 newN = _shareIds.length - curShareIdsLen;
        if (newN > 8) {
            newN = 8;
        }

        uint256 cliff = IStakeCore(stakecore).CLIFF_PERIOD();

        uint256[] memory newShareIds = new uint256[](newN);
        uint256 length = curShareIdsLen + newN;
        for (uint256 i = curShareIdsLen; i < length; i++) {
            uint256 shareId = _shareIds[i];
            IStakeCore.StakeInfo memory stakeInfo = IStakeCore(stakecore).getStakeRecords(shareId);
            uint256 startTime = stakeInfo.startTime + cliff;
            shareInfos[shareId] = ShareInfo({
                isSet: true,
                startTime: startTime,
                recycledTime: startTime,
                endTime: stakeInfo.startTime + stakeInfo.lockPeriod,
                totalReward: stakeInfo.totalRewards,
                claimedReward: 0,
                withdrawnReward: 0,
                grantedReward: 0,

                totalRecycledReward: 0,
                withdrawnRecycledReward: 0,
                totalPrincipal: stakeInfo.totalPrincipal,
                claimedPrincipal: 0,
                withdrawnPrincipal: 0,
                grantedPrincipal: 0

            });

            shareIds.push(shareId);
            newShareIds[i - curShareIdsLen] = shareId;
        }

        emit Registered(newShareIds);
    }


    function claimStakeRewards(uint256 shareId) external override nonReentrant {
        if (!shareInfos[shareId].isSet) revert InvalidShareId(shareId);
        uint256 amount = IStakeCore(stakecore).withdrawRewards(shareId);
        shareInfos[shareId].claimedReward += amount;
        heldFunds += amount;
        emit StakeRewardsClaimed(shareId, amount);
    }

    function claimStakeRewardsBatch(uint256 startI, uint256 len) external nonReentrant {
        uint256 lenMax = shareIds.length;
        if (startI >= lenMax) return;

        if (len == 0 || startI + len > lenMax) {
            len = lenMax - startI;
        }

        uint256 endI = startI + len;
        uint256[] memory _shareIds = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 j;
        uint256 sum;
        for (uint256 i = startI; i < endI;) {
            uint256 shareId = shareIds[i];
            _shareIds[j] = shareId;
            try IStakeCore(stakecore).withdrawRewards(shareId)returns (uint256 amount){
                shareInfos[shareId].claimedReward += amount;
                sum += amount;
                amounts[j] = amount;
            }catch{

            }

            unchecked {++i;
                ++j;}
        }

        if (sum > 0) {
            heldFunds += sum;
        }

        emit StakeRewardsClaimedBatch(_shareIds, amounts);
    }

    function claimStakePrincipal(uint256 shareId) external override nonReentrant {
        if (!shareInfos[shareId].isSet) revert InvalidShareId(shareId);
        uint256 amount = IStakeCore(stakecore).withdrawPrincipal(shareId);
        shareInfos[shareId].claimedPrincipal += amount;
        heldFunds += amount;
        emit StakePrincipalClaimed(shareId, amount);
    }
}
