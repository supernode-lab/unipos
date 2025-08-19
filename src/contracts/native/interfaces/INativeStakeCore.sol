// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INativeStakeCore {
    struct StakeInfo {
        address owner;
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;
        uint256 claimedRewards;
        uint256 lockedRewards;
        bool unstaked;
    }

    function minStakeAmount() external returns (uint256);

    function claimRewards(uint256) external returns (uint256);

    function getUserStakeIndexes(address) external returns (uint256[]memory);

    function getStakeRecords(uint256) external returns (StakeInfo memory);

    function stake(address) external payable;

    function unstake(uint256) external returns (uint256);
}