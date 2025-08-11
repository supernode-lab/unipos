// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract StakeCore is IStakeCore, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Events
    event Stake(address indexed staker, uint256 amount, uint256 startTime, uint256 lockPeriod);
    event RewardsClaimed(address indexed staker, uint256 amount, uint256 index);

    struct BeneficiaryInfo {
        address owner;
        uint256 totalRewards;
        uint256 claimedRewards;
    }

    uint256 public constant PRECISION = 1e18;
    uint256 public immutable lockPeriod;
    uint256 public immutable minStakeAmount;
    uint256 public immutable installmentNum;

    // total user staked amount
    uint256 public totalClaimedRewards;
    // total security deposit amount
    uint256 public totalCollateral;

    IStakeCore.StakeInfo[] internal stakeRecords;
    mapping(address => uint256[]) public userStakeIndexes; // 每个用户的质押记录


    function getStakeRecords(uint256 _index) external view returns (StakeInfo memory){
        return stakeRecords[_index];
    }

    function getUserStakeIndexes(address owner) external view returns (uint256[]memory){
        return userStakeIndexes[owner];
    }


    constructor(uint256 _lockPeriod, uint256 installmentCount, uint256 _minStakeAmount) {
        lockPeriod = _lockPeriod;
        minStakeAmount = _minStakeAmount;
        installmentNum = installmentCount;
    }

    /// @notice stakers stake tokens, and can stake multiple times
    function stake(address owner, uint256 _amount) external payable {
        require(_amount > 0, "Amount must be greater than 0");
        require(_amount >= minStakeAmount, "Amount must be greater than minimum stake amount");
        totalCollateral += _amount;
        stakeRecords.push(
            StakeInfo({
                owner: owner,
                amount: 0,
                startTime: block.timestamp,
                lockPeriod: lockPeriod,
                lockedRewards: _amount,
                claimedRewards: 0,
                unstaked: false
            })
        );
        userStakeIndexes[owner].push(stakeRecords.length - 1);
        emit Stake(owner, _amount, block.timestamp, lockPeriod);
    }

    function unstake(uint256 _index) external returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        require(_stake.owner == msg.sender, "Not owner");
        require(block.timestamp >= _stake.startTime + _stake.lockPeriod, "Lock period not ended");
        require(!_stake.unstaked, "Already claimed");
        _stake.unstaked = true;
        return 0;
    }

    function claimRewards(uint256 _index) external returns (uint256){
        StakeInfo storage _stake = stakeRecords[_index];
        require(_stake.owner == msg.sender, "Not owner");
        //require(_stake.owner == msg.sender || _stake.owner == beneficiary.owner, "Not owner or Beneficiary");
        uint256 totalUnlocked = getUnlockedInstallmentRewards(_index);
        require(_stake.claimedRewards < totalUnlocked, "Can't claim");
        uint256 toBeClaimed = totalUnlocked - _stake.claimedRewards;
        _stake.claimedRewards += toBeClaimed;
        _stake.lockedRewards -= toBeClaimed;
        totalClaimedRewards += toBeClaimed;
        (bool success,) = payable(_stake.owner).call{value: toBeClaimed}("");
        require(success, "transfer failed");
        emit RewardsClaimed(_stake.owner, toBeClaimed, _index);
        return toBeClaimed;
    }


    function getUnlockedInstallmentRewards(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 totalRewards = _stake.claimedRewards + _stake.lockedRewards;
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        // calculate the number of unlocked rewards by installment
        uint256 unlockedPhase = elapsedTime >= lockPeriod ? installmentNum : (elapsedTime * installmentNum) / lockPeriod;
        uint256 unlockedRewardsByInstallment = (totalRewards / installmentNum) * unlockedPhase;
        return unlockedRewardsByInstallment;
    }

    function getStakeInfo(uint256 _index) public view returns (StakeInfo memory) {
        return stakeRecords[_index];
    }

    function getStakeInfoByAddress(address _staker) public view returns (StakeInfo[] memory) {
        uint256[] memory indexes = userStakeIndexes[_staker];
        StakeInfo[] memory stakeInfo = new StakeInfo[](indexes.length);
        for (uint256 i = 0; i < indexes.length; i++) {
            stakeInfo[i] = stakeRecords[indexes[i]];
        }
        return stakeInfo;
    }

    // get stake infos by range [start, end)
    function getStakeInfoByPage(uint256 start, uint256 end) public view returns (StakeInfo[] memory) {
        require(end <= stakeRecords.length, "End index out of bounds");
        StakeInfo[] memory stakeInfo = new StakeInfo[](end - start);
        for (uint256 i = start; i < end; i++) {
            stakeInfo[i - start] = stakeRecords[i];
        }
        return stakeInfo;
    }
}
