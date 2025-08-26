// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseError} from "./BaseError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IStakeCore is BaseError {
    error InsufficientBalance(uint256 balance, uint256 needed);
    error InsufficientDeposit(uint256 balance, uint256 needed);
    error UnauthorizedCaller(address);
    error NoRewards();
    error NoPrincipal();
    error NoExcessTokens();

    event Staked(address  staker, uint256 amount, uint256 startTime, uint256 lockPeriod, uint256 index);
    event PrincipalWithdrawn(address  staker, uint256 amount, uint256 index);
    event RewardsWithdrawn(address  staker, uint256 amount, uint256 index);
    event BeneficiaryRewardsWithdrawn(address  beneficiary, uint256 amount);
    event SecurityDeposited(uint256 amount, uint256 totalSecurity);
    event SecurityWithdrawn(uint256 amount, uint256 remainingSecurity);
    event BeneficiaryInitialized(address  beneficiary);
    event ExcessCollected(uint256 extraToken);

    struct StakeInfo {
        address owner;
        uint256 startTime;
        uint256 lockPeriod;
        uint256 totalPrincipal;
        uint256 withdrawnPrincipal;
        uint256 totalRewards;
        uint256 withdrawnRewards;
    }

    function depositSecurity(uint256 _amount) external payable;

    function stake(address, uint256) external payable;

    function withdrawPrincipal(uint256) external returns (uint256);

    function withdrawRewards(uint256) external returns (uint256);

    function minStakeAmount() external returns (uint256);

    function getUserStakeIndexes(address) external returns (uint256[]memory);

    function getStakeRecords(uint256) external returns (StakeInfo memory);

    function token() external returns (IERC20);
}