// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseError} from "./BaseError.sol";

interface IGeneralShare is BaseError {
    error InsufficientUnallocatedPrincipal();
    error InsufficientUnallocatedRewards();
    error HolderAlreadyExists();
    error NoRewards();
    error NoPrincipal();
    error InvalidShareId();
    error StakeCoreAlreadySet();
    error StartTimeOutOfRange(uint256 startTime, uint256 shareStart, uint256 shareEnd);
    error AmountExceedsWithdrawable(uint256 amount, uint256 withdrawable);
    error AmountExceedsBalance(uint256 amount, uint256 balance);
    error InsufficientRewards();

    struct ShareholderInfo {
        address owner;
        uint256 shareId;
        uint256 _recycledReward;
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
        bytes claimRewardArgs;
        bytes claimPrincipalArgs;

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