// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import "forge-std/console.sol";

interface IStakeCore {
    struct StakeInfo {
        address owner;
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;
        uint256 claimedRewards;
        uint256 lockedRewards;
        bool unstaked;
    }

    function claimRewards(uint256) external returns (uint256);

    function getUserStakeIndexes(address) external returns (uint256[]memory);

    function getStakeRecords(uint256) external returns (StakeInfo memory);

    function unstake(uint256) external returns (uint256);
}