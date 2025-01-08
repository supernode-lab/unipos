// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// import "forge-std/console.sol";

interface IStakeCore {
    function claimBeneficiaryRewards() external returns (uint256);
}

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract StakeCore is IStakeCore {
    using SafeERC20 for IERC20;
    using Math for uint256;

      // Events
    event Stake(address indexed staker, uint256 amount, uint256 startTime, uint256 lockPeriod);
    event Unstake(address indexed staker, uint256 amount, uint256 index);
    event RewardsClaimed(address indexed staker, uint256 amount, uint256 index);
    event BeneficiaryRewardsClaimed(address indexed beneficiary, uint256 amount);
    event SecurityDeposited(uint256 amount, uint256 totalSecurity);
    event SecurityWithdrawn(uint256 amount, uint256 remainingSecurity);
    event BeneficiaryInitialized(address indexed beneficiary);
    
    struct StakeInfo {
        address owner;
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;
        uint256 claimedRewards;
        uint256 lockedRewards;
        bool unstaked;
    }
    struct BeneficiaryInfo {
        address owner;
        uint256 totalRewards;
        uint256 claimedRewards;
    }
    uint256 public constant PRECISION = 1e18;
    IERC20 public immutable token;
    uint256 public immutable lockPeriod;
    uint256 public immutable stakerRewardShare;
    uint256 public immutable apy;
    uint256 public immutable minStakeAmount;
    uint256 public immutable installmentNum;

    // total user staked amount
    uint256 public totalCollateral;
    // total security deposit amount
    uint256 public totalSecurityDeposit;
    // total required stake amount
    uint256 public requiredCollateral;

    StakeInfo[] public stakeRecords;
    mapping(address => uint256[]) public userStakeIndexes; // 每个用户的质押记录

    address public admin;
    BeneficiaryInfo public beneficiary;

    constructor(IERC20 _token, uint256 lockDays, uint256 stakerShares, uint256 installmentCount) {
        token = _token;
        lockPeriod = lockDays;
        stakerRewardShare = stakerShares; // percentage, based on 100
        apy = (200 * PRECISION) / 100;
        minStakeAmount = 100 * 1e18;
        admin = msg.sender;
        installmentNum = installmentCount;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function initBeneficiary(address _bf) external onlyAdmin {
        require(_bf != address(0), "Invalid address");
        require(beneficiary.owner == address(0), "Inited");
        beneficiary.owner = _bf;
        emit BeneficiaryInitialized(_bf);
    }

    function depositSecurity(uint256 _amount) external onlyAdmin {
        token.safeTransferFrom(msg.sender, address(this), _amount);
        totalSecurityDeposit += _amount;
        requiredCollateral = getCollateralBySecurityDeposit(totalSecurityDeposit);
        emit SecurityDeposited(_amount, totalSecurityDeposit);
    }

    function withdrawSecurity(uint256 _amount) external onlyAdmin {
        uint256 remainingCollateral = requiredCollateral - totalCollateral;
        uint256 withdrawnableSecurityDeposit = getSecurityDepositByCollateral(remainingCollateral);
        require(withdrawnableSecurityDeposit >= _amount, "No enough balance");
        token.safeTransfer(msg.sender, _amount);
        totalSecurityDeposit -= _amount;
        requiredCollateral = getCollateralBySecurityDeposit(totalSecurityDeposit);
        emit SecurityWithdrawn(_amount, totalSecurityDeposit);
    }

    /// @notice stakers stake tokens, and can stake multiple times
    function stake(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(_amount >= minStakeAmount, "Amount must be greater than minimum stake amount");
        require(totalCollateral + _amount <= requiredCollateral, "No enough allowance");
        token.safeTransferFrom(msg.sender, address(this), _amount);
        totalCollateral += _amount;
        stakeRecords.push(
            StakeInfo({
                owner: msg.sender,
                amount: _amount,
                startTime: block.timestamp,
                lockPeriod: lockPeriod,
                lockedRewards: calculateStakerRewards(_amount),
                claimedRewards: 0,
                unstaked: false
            })
        );
        userStakeIndexes[msg.sender].push(stakeRecords.length - 1);
        emit Stake(msg.sender, _amount, block.timestamp, lockPeriod);
    }

    function unstake(uint256 _index) external {
        StakeInfo storage _stake = stakeRecords[_index];
        require(_stake.owner == msg.sender, "Not owner");
        require(block.timestamp >= _stake.startTime + _stake.lockPeriod, "Lock period not ended");
        require(!_stake.unstaked, "Already claimed");
        _stake.unstaked = true;
        token.safeTransfer(msg.sender, _stake.amount);
        emit Unstake(msg.sender, _stake.amount, _index);
    }

    function claimRewards(uint256 _index) external {
        StakeInfo storage _stake = stakeRecords[_index];
        require(_stake.owner == msg.sender || _stake.owner == beneficiary.owner, "Not owner or Beneficiary");
        uint256 totalUnlocked = getUnlockedInstallmentRewards(_index);
        require(_stake.claimedRewards < totalUnlocked, "Can't claim");
        uint256 toBeClaimed = totalUnlocked - _stake.claimedRewards;
        _stake.claimedRewards += toBeClaimed;
        _stake.lockedRewards -= toBeClaimed;
        token.safeTransfer(_stake.owner, toBeClaimed);
        // toBeClaimed / beneficiaryShare = stakerRewardShare / (100 - stakerRewardShare)
        uint256 beneficiaryShare = (toBeClaimed * (100 - stakerRewardShare)) / stakerRewardShare;
        beneficiary.totalRewards += beneficiaryShare;
        emit RewardsClaimed(_stake.owner, toBeClaimed, _index);
    }

    function claimBeneficiaryRewards() external returns (uint256) {
        require(beneficiary.owner == msg.sender, "Not Beneficiary");
        uint256 rewards = beneficiary.totalRewards - beneficiary.claimedRewards;
        beneficiary.claimedRewards += rewards;
        token.safeTransfer(msg.sender, rewards);
        emit BeneficiaryRewardsClaimed(msg.sender, rewards);
        return rewards;
    }

    function getCollateralBySecurityDeposit(uint256 _amount) public view returns (uint256) {
        // (apy * lockPeriod / 365 days) = x days rewards rate
        // collateral * (x days rewards rate) = security deposit
        return (_amount * PRECISION) / ((apy * lockPeriod) / 365 days);
    }

    function getSecurityDepositByCollateral(uint256 _amount) public view returns (uint256) {
        return (_amount * ((apy * lockPeriod) / 365 days)) / PRECISION;
    }

    function calculateStakerRewards(uint256 _collataralAmount) public view returns (uint256) {
        uint256 totalRewards = getSecurityDepositByCollateral(_collataralAmount);
        uint256 stakerShare = (totalRewards * stakerRewardShare) / 100;
        return stakerShare;
    }
    function calculateBeneficiaryRewards(uint256 _collataralAmount) public view returns (uint256) {
        uint256 totalRewards = getSecurityDepositByCollateral(_collataralAmount);
        uint256 stakerShare = (totalRewards * stakerRewardShare) / 100;
        return totalRewards - stakerShare;
    }

    function getUnlockedInstallmentRewards(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 totalRewards = _stake.claimedRewards + _stake.lockedRewards;
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        // calculate the number of unlocked rewards by installment
        uint256 unlockedPhase = elapsedTime >= lockPeriod ? installmentNum : (elapsedTime * installmentNum) / lockPeriod;
        // console.log("unlockedPhase", unlockedPhase);
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
