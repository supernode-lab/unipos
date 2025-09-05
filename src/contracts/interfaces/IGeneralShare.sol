// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseError} from "./BaseError.sol";

interface IGeneralShare is BaseError {
    error InvalidShareId(uint256 shareId);
    error HolderAlreadyExists();
    error StakeCoreAlreadySet();
    error AmountExceedsWithdrawable();
    error AmountExceedsBalance();

    event RewardsAccrued(uint256 shareId, uint256 recycledT, uint256 recycledRewards);
    event ShareholderAdded(address  shareholder, uint256 shareId, uint256 startTime, uint256 grantedReward, uint256 grantedPrincipal);
    event FundsAllocated(uint256 shareId, uint256 allocatedReward, uint256 allocatedPrincipal);
    event RewardsClaimed(address  shareholder, uint256 shareId, uint256 amount);
    event PrincipalClaimed(address  shareholder, uint256 shareId, uint256 amount);
    event ExcessCollected(uint256 amount);

    event StakeRewardsClaimed(uint256 shareId, uint256 amount);
    event StakePrincipalClaimed(uint256 shareId, uint256 amount);

    struct ShareholderInfo {
        address owner;
        uint256 shareId;
        uint256 preRecycledReward;
        uint256 grantedReward;
        uint256 withdrawnReward;
        uint256 grantedPrincipal;
        uint256 withdrawnPrincipal;
    }

    struct ShareHolderKey {
        address owner;
        uint256 shareId;
    }

    struct ShareInfo {
        bool  isSet;
        uint256 startTime;
        uint256 recycledTime;
        uint256 endTime;

        uint256 totalReward;
        uint256 claimedReward;
        uint256 withdrawnReward;
        uint256 grantedReward;

        uint256 totalRecycledReward;
        uint256 withdrawnRecycledReward;

        uint256 totalPrincipal;
        uint256 claimedPrincipal;
        uint256 withdrawnPrincipal;
        uint256 grantedPrincipal;
    }

}