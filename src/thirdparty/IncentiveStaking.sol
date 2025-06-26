// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Whitelist.sol";


interface IIncentiveStaking {
    struct StakeInfo {
        uint256 amount;           // Principal amount
        uint256 startTime;        // Staking start time
        uint256 totalInterest;    // Total interest
        uint256 claimedInterest;  // Claimed interest
        bool isActive;            // Whether active
        bool isAdminStake;        // Whether this is an admin stake (true for admin, false for regular user)
    }

    function praiToken() external returns (IERC20);

    function withdrawalStakes(address user,uint256 index) external view returns (StakeInfo memory);

    function getWithdrawalAddressStakeDetails(address withdrawalAddress) external view returns (
        uint256[] memory amounts,
        uint256[] memory startTimes,
        uint256[] memory availableInterests,
        uint256[] memory claimedInterests,
        bool[] memory isMatured,
        bool[] memory isActive,
        bool[] memory isAdminStakes
    );

    function withdraw()external returns(uint256);
}


/**
 * @title PRAI Incentive Staking Contract
 * @dev Implements PRAI token staking, interest calculation and withdrawal functionality
 * @notice Architecture: Indexed by withdrawal address as primary key
 */
contract IncentiveStaking is
ReentrancyGuard,
Whitelist
{

    struct StakeInfo {
        uint256 amount;           // Principal amount
        uint256 startTime;        // Staking start time
        uint256 totalInterest;    // Total interest
        uint256 claimedInterest;  // Claimed interest
        bool isActive;            // Whether active
        bool isAdminStake;        // Whether this is an admin stake (true for admin, false for regular user)
    }

    IERC20 public praiToken;

    // Constants definition
    uint256 public constant STAKING_PERIOD = 180 days; // Staking period 180 days
    uint256 public constant APY_RATE = 35; // 6-month yield 35% (APY 70%)
    uint256 public constant DAILY_RELEASE_DENOMINATOR = 180; // Daily release denominator
    uint256 public constant MAX_STAKES_PER_USER = 100; // Maximum stakes per withdrawal address
    uint256 public constant MAX_CONTRACT_BALANCE = 800000000 * 10**18; // Maximum contract balance 800 million PRAI

    // Configurable parameters
    uint256 public MINIMUM_STAKE; // Configurable minimum stake amount


    // PRIMARY INDEX: Withdrawal address -> Stakes
    mapping(address => StakeInfo[]) public withdrawalStakes;

    // Withdrawal addresses tracking
    address[] public withdrawalAddresses;                    // Array of all withdrawal addresses
    mapping(address => bool) public withdrawalAddressExists; // Check if address already exists

    // Contract global statistics
    uint256 public totalPoolAmount;     // Total principal pool
    uint256 public totalInterestPool;   // Total available interest funds (actual funded amount)
    uint256 public totalStakeInterest;  // Total stake interest debt (all promised interest)
    uint256 public totalHistoricalDeposits; // Total historical deposits


    // Events definition
    event Staked(address indexed staker, address indexed withdrawalAddress, uint256 indexed stakeIndex, uint256 amount, uint256 timestamp);
    event Withdrawn(address indexed withdrawalAddress, uint256 principal, uint256 interest, uint256 total, uint256[] processedIndexes);

    event InterestPoolFunded(address indexed funder, uint256 amount);
    event MinimumStakeUpdated(uint256 oldMinimumStake, uint256 newMinimumStake);

    constructor(address _praiToken) {
        require(_praiToken != address(0), "Invalid token address");

        praiToken = IERC20(_praiToken);

        // Set default minimum stake
        MINIMUM_STAKE = 1000000 * 10**18; // Default 1,000,000 PRAI
    }

    /**
     * @dev Stake PRAI tokens (normal user staking)
     * @param amount Amount to stake
     * @param withdrawalAddress Withdrawal address (must be msg.sender)
     */
    function stake(uint256 amount, address withdrawalAddress) external nonReentrant {
        require(amount >= MINIMUM_STAKE, "Insufficient stake amount");
        require(praiToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(praiToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");

        // Check contract balance limit
        require(praiToken.balanceOf(address(this)) + amount <= MAX_CONTRACT_BALANCE, "Contract balance limit exceeded");

        // Withdrawal address must be the same as msg.sender
        require(withdrawalAddress == msg.sender, "Withdrawal address mismatch");

        // Check withdrawal address stake limit
        require(withdrawalStakes[withdrawalAddress].length < MAX_STAKES_PER_USER, "Max stakes exceeded");

        // Transfer tokens to contract
        require(praiToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // Calculate total interest (6-month yield 35%)
        uint256 totalInterest = amount * APY_RATE / 100;

        // Create new stake record
        StakeInfo memory newStake = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            totalInterest: totalInterest,
            claimedInterest: 0,
            isActive: true,
            isAdminStake: false  // Regular user staking
        });

        // Update primary index (withdrawal address -> stakes)
        withdrawalStakes[withdrawalAddress].push(newStake);

        // Add withdrawal address to array if not exists
        if (!withdrawalAddressExists[withdrawalAddress]) {
            withdrawalAddresses.push(withdrawalAddress);
            withdrawalAddressExists[withdrawalAddress] = true;
        }

        // Update global statistics
        totalPoolAmount += amount;
        totalStakeInterest += totalInterest;  // Record promised interest debt
        totalHistoricalDeposits += amount; // Update historical total deposits

        emit Staked(msg.sender, withdrawalAddress, withdrawalStakes[withdrawalAddress].length - 1, amount, block.timestamp);
    }

    /**
     * @dev Admin stake function - whitelist users or owner can stake for any user with custom withdrawal address
     * @param amount Amount to stake
     * @param withdrawalAddress Withdrawal address (can be different from staker)
     */
    function adminStake(uint256 amount, address withdrawalAddress) external nonReentrant onlyOperationWhitelist() {
        require(withdrawalAddress != address(0), "Invalid withdrawal address");
        require(amount >= MINIMUM_STAKE, "Insufficient stake amount");
        require(praiToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(praiToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");

        // Check contract balance limit
        require(praiToken.balanceOf(address(this)) + amount <= MAX_CONTRACT_BALANCE, "Contract balance limit exceeded");

        // Check withdrawal address stake limit
        require(withdrawalStakes[withdrawalAddress].length < MAX_STAKES_PER_USER, "Max stakes exceeded");

        // Transfer tokens to contract
        require(praiToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // Calculate total interest (6-month yield 35%)
        uint256 totalInterest = amount * APY_RATE / 100;

        // Create new stake record
        StakeInfo memory newStake = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            totalInterest: totalInterest,
            claimedInterest: 0,
            isActive: true,
            isAdminStake: true   // Admin staking
        });

        // Update primary index
        withdrawalStakes[withdrawalAddress].push(newStake);

        // Add withdrawal address to array if not exists
        if (!withdrawalAddressExists[withdrawalAddress]) {
            withdrawalAddresses.push(withdrawalAddress);
            withdrawalAddressExists[withdrawalAddress] = true;
        }

        // Update global statistics
        totalPoolAmount += amount;
        totalStakeInterest += totalInterest;  // Record promised interest debt
        totalHistoricalDeposits += amount; // Update historical total deposits

        emit Staked(msg.sender, withdrawalAddress, withdrawalStakes[withdrawalAddress].length - 1, amount, block.timestamp);
    }

    /**
     * @dev Calculate available interest for withdrawal
     * @param withdrawalAddress Withdrawal address
     * @param stakeIndex Stake index under this withdrawal address
     */
    function calculateAvailableInterest(address withdrawalAddress, uint256 stakeIndex) public view returns (uint256) {
        require(stakeIndex < withdrawalStakes[withdrawalAddress].length, "Invalid stake index");

        StakeInfo memory stakeInfo = withdrawalStakes[withdrawalAddress][stakeIndex];
        if (!stakeInfo.isActive) {
            return 0;
        }

        uint256 daysPassed = (block.timestamp - stakeInfo.startTime) / 1 days;
        if (daysPassed > DAILY_RELEASE_DENOMINATOR) {
            daysPassed = DAILY_RELEASE_DENOMINATOR;
        }

        uint256 totalAvailable = stakeInfo.totalInterest * daysPassed / DAILY_RELEASE_DENOMINATOR;
        return totalAvailable - stakeInfo.claimedInterest;
    }

    /**
     * @dev Calculate total available interest for all stakes under a withdrawal address
     */
    function calculateTotalAvailableInterest(address withdrawalAddress) public view returns (uint256) {
        uint256 totalAvailable = 0;
        for (uint256 i = 0; i < withdrawalStakes[withdrawalAddress].length; i++) {
            totalAvailable += calculateAvailableInterest(withdrawalAddress, i);
        }
        return totalAvailable;
    }

    /**
     * @dev Check if stake has matured
     * @param withdrawalAddress Withdrawal address
     * @param stakeIndex Stake index under this withdrawal address
     */
    function isStakeMature(address withdrawalAddress, uint256 stakeIndex) public view returns (bool) {
        require(stakeIndex < withdrawalStakes[withdrawalAddress].length, "Invalid stake index");

        StakeInfo memory stakeInfo = withdrawalStakes[withdrawalAddress][stakeIndex];
        return block.timestamp >= stakeInfo.startTime + STAKING_PERIOD;
    }


    /**
     * @dev Withdraw all available funds from withdrawal address
     * - Withdraws all available interest from all stakes
     * - For matured stakes: withdraws principal + remaining interest
     */
    function withdraw() external nonReentrant returns(uint256) {
        address withdrawalAddress = msg.sender;
        require(withdrawalStakes[withdrawalAddress].length > 0, "No stake records");

        uint256 totalInterest = 0;
        uint256 totalPrincipal = 0;
        bool hasValidStake = false;
        uint256[] memory processedIndexes = new uint256[](withdrawalStakes[withdrawalAddress].length);
        uint256 processedCount = 0;

        // Process all stakes for this withdrawal address
        for (uint256 i = 0; i < withdrawalStakes[withdrawalAddress].length; i++) {
            StakeInfo storage stakeInfo = withdrawalStakes[withdrawalAddress][i];

            if (!stakeInfo.isActive) {
                continue;
            }

            uint256 availableInterest = calculateAvailableInterest(withdrawalAddress, i);

            // Only process stakes that have available funds
            if (availableInterest > 0 || isStakeMature(withdrawalAddress, i)) {
                hasValidStake = true;
                processedIndexes[processedCount] = i;
                processedCount++;

                // If stake has matured, give all remaining interest to avoid precision loss
                if (isStakeMature(withdrawalAddress, i)) {
                    // Give all remaining interest (fixes precision issues)
                    uint256 remainingInterest = stakeInfo.totalInterest - stakeInfo.claimedInterest;
                    totalInterest += remainingInterest;
                    stakeInfo.claimedInterest = stakeInfo.totalInterest; // Mark all interest as claimed

                    totalPrincipal += stakeInfo.amount;
                    totalPoolAmount -= stakeInfo.amount;
                    stakeInfo.isActive = false;
                } else {
                    // For non-mature stakes, use calculated available interest
                    totalInterest += availableInterest;
                    stakeInfo.claimedInterest += availableInterest;
                }
            }
        }

        require(hasValidStake, "No funds available");
        require(totalInterest > 0 || totalPrincipal > 0, "No funds available");

        uint256 totalWithdrawal = totalInterest + totalPrincipal;

        // Check if interest pool has sufficient balance for interest withdrawal
        if (totalInterest > 0) {
            require(totalInterestPool >= totalInterest, "Insufficient interest pool balance");
        }

        // Check if contract has sufficient balance
        require(praiToken.balanceOf(address(this)) >= totalWithdrawal, "Insufficient contract balance");

        // Update global statistics
        if (totalInterest > 0) {
            totalInterestPool -= totalInterest;  // Deduct from available interest funds
            totalStakeInterest -= totalInterest; // Reduce interest debt
        }

        // Transfer to withdrawal address
        require(praiToken.transfer(withdrawalAddress, totalWithdrawal), "Withdrawal failed");

        // Emit unified withdrawal event
        uint256[] memory actualProcessed = new uint256[](processedCount);
        for (uint256 i = 0; i < processedCount; i++) {
            actualProcessed[i] = processedIndexes[i];
        }
        emit Withdrawn(withdrawalAddress, totalPrincipal, totalInterest, totalWithdrawal, actualProcessed);

        return totalWithdrawal;
    }

    /**
     * @dev Get detailed status of all stakes under a withdrawal address
     */
    function getWithdrawalAddressStakeDetails(address withdrawalAddress) external view returns (
        uint256[] memory amounts,
        uint256[] memory startTimes,
        uint256[] memory availableInterests,
        uint256[] memory claimedInterests,
        bool[] memory isMatured,
        bool[] memory isActive,
        bool[] memory isAdminStakes
    ) {
        uint256 length = withdrawalStakes[withdrawalAddress].length;

        amounts = new uint256[](length);
        startTimes = new uint256[](length);
        availableInterests = new uint256[](length);
        claimedInterests = new uint256[](length);
        isMatured = new bool[](length);
        isActive = new bool[](length);
        isAdminStakes = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            StakeInfo memory stakeRecord = withdrawalStakes[withdrawalAddress][i];
            amounts[i] = stakeRecord.amount;
            startTimes[i] = stakeRecord.startTime;
            availableInterests[i] = calculateAvailableInterest(withdrawalAddress, i);
            claimedInterests[i] = stakeRecord.claimedInterest;
            isMatured[i] = isStakeMature(withdrawalAddress, i);
            isActive[i] = stakeRecord.isActive;
            isAdminStakes[i] = stakeRecord.isAdminStake;
        }
    }


    /**
     * @dev Get total claimed interest for withdrawal address
     */
    function getTotalClaimedInterest(address withdrawalAddress) external view returns (uint256) {
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < withdrawalStakes[withdrawalAddress].length; i++) {
            totalClaimed += withdrawalStakes[withdrawalAddress][i].claimedInterest;
        }
        return totalClaimed;
    }


    /**
     * @dev Admin function: Inject funds into interest pool
     * @notice Increases the actual available interest funds for withdrawals
     */
    function fundInterestPool(uint256 amount) external{
        require(amount > 0, "Amount must be greater than zero");
        require(praiToken.transferFrom(msg.sender, address(this), amount), "Fund injection failed");
        totalInterestPool += amount;  // Increase available interest funds

        emit InterestPoolFunded(msg.sender, amount);
    }


    function getCompleteContractStats() external view returns (
        uint256 _totalPoolAmount,
        uint256 _totalInterestPool,
        uint256 _totalStakeInterest,        // Total promised interest debt
        uint256 _contractBalance,
        uint256 _totalHistoricalDeposits    // Return historical total deposits
    ) {
        return (
            totalPoolAmount,
            totalInterestPool,
            totalStakeInterest,
            praiToken.balanceOf(address(this)),
            totalHistoricalDeposits
        );
    }

    /**
     * @dev Set minimum stake amount - only owner can call
     * @param _minimumStake New minimum stake amount
     */
    function setMinimumStake(uint256 _minimumStake) external onlyOwner {
        require(_minimumStake > 0, "Minimum stake must be greater than zero");

        uint256 oldMinimumStake = MINIMUM_STAKE;
        MINIMUM_STAKE = _minimumStake;

        emit MinimumStakeUpdated(oldMinimumStake, _minimumStake);
    }

    /**
     * @dev Get current minimum stake amount
     */
    function getMinimumStake() external view returns (uint256) {
        return MINIMUM_STAKE;
    }

    /**
     * @dev Get all withdrawal addresses
     */
    function getAllWithdrawalAddresses() external view returns (address[] memory) {
        return withdrawalAddresses;
    }

    /**
     * @dev Get total historical deposits
     * @return Total amount of all deposits made since contract inception
     */
    function getTotalHistoricalDeposits() external view returns (uint256) {
        return totalHistoricalDeposits;
    }

    /**
     * @dev Get total stake interest debt
     * @return Total amount of all promised interest across all stakes
     */
    function getTotalStakeInterest() external view returns (uint256) {
        return totalStakeInterest;
    }

}
