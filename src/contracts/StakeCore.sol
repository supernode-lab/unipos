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
    event Unstake(address indexed staker, uint256 amount, uint256 index);
    event RewardsClaimed(address indexed staker, uint256 amount, uint256 index);
    event BeneficiaryRewardsClaimed(address indexed beneficiary, uint256 amount);
    event SecurityDeposited(uint256 amount, uint256 totalSecurity);
    event SecurityWithdrawn(uint256 amount, uint256 remainingSecurity);
    event BeneficiaryInitialized(address indexed beneficiary);
    event CollectExtra(uint256 extraToken);


    struct BeneficiaryInfo {
        address owner;
        uint256 totalRewards;
        uint256 claimedRewards;
    }

    struct Provider {
        address owner;
        address pendingOwner;
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
    uint256 public unstakedCollateral;
    uint256 public totalClaimedRewards;
    // total security deposit amount
    uint256 public totalSecurityDeposit;
    // total required stake amount
    uint256 public requiredCollateral;

    IStakeCore.StakeInfo[] internal stakeRecords;
    mapping(address => uint256[]) public userStakeIndexes; // 每个用户的质押记录


    function getStakeRecords(uint256 _index) external view returns (StakeInfo memory){
        return stakeRecords[_index];
    }

    function getUserStakeIndexes(address owner) external view returns (uint256[]memory){
        return userStakeIndexes[owner];
    }


    address public admin;
    BeneficiaryInfo public beneficiary;
    Provider public provider;

    constructor(IERC20 _token, address _provider, uint256 _lockPeriod, uint256 stakerShares, uint256 _apy, uint256 installmentCount) {
        require(address(_token) != address(0), "Invalid Token address");
        require(_provider != address(0), "Invalid provider address");
        token = _token;
        provider.owner = _provider;
        lockPeriod = _lockPeriod;
        stakerRewardShare = stakerShares; // percentage, based on 100
        apy = (_apy * PRECISION) / 100;
        minStakeAmount = 100 * 1e18;
        admin = msg.sender;
        installmentNum = installmentCount;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
    modifier onlyProvider() {
        require(msg.sender == provider.owner, "Only provider can call this function");
        _;
    }

    function transferProviderOwnership(address _newProvider) external onlyProvider {
        provider.pendingOwner = _newProvider;
    }

    function acceptProviderOwnership() external {
        require(msg.sender == provider.pendingOwner, "Only pending owner can accept ownership");
        provider.owner = provider.pendingOwner;
        provider.pendingOwner = address(0);
    }

    function initBeneficiary(address _bf) external onlyAdmin {
        require(_bf != address(0), "Invalid address");
        require(beneficiary.owner == address(0), "Inited");
        beneficiary.owner = _bf;
        emit BeneficiaryInitialized(_bf);
    }

    function depositSecurity(uint256 _amount) external onlyProvider nonReentrant {
        totalSecurityDeposit += _amount;
        requiredCollateral = getCollateralBySecurityDeposit(totalSecurityDeposit);
        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit SecurityDeposited(_amount, totalSecurityDeposit);
    }

    function withdrawSecurity(uint256 _amount) external onlyProvider nonReentrant {
        uint256 remainingCollateral = requiredCollateral - totalCollateral;
        uint256 withdrawnableSecurityDeposit = getSecurityDepositByCollateral(remainingCollateral);
        require(withdrawnableSecurityDeposit >= _amount, "No enough balance");
        totalSecurityDeposit -= _amount;
        requiredCollateral = getCollateralBySecurityDeposit(totalSecurityDeposit);
        token.safeTransfer(msg.sender, _amount);
        emit SecurityWithdrawn(_amount, totalSecurityDeposit);
    }

    /// @notice stakers stake tokens, and can stake multiple times
    function stake(address owner, uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(_amount >= minStakeAmount, "Amount must be greater than minimum stake amount");
        require(totalCollateral + _amount <= requiredCollateral, "No enough allowance");
        token.safeTransferFrom(msg.sender, address(this), _amount);
        totalCollateral += _amount;
        stakeRecords.push(
            StakeInfo({
                owner: owner,
                amount: _amount,
                startTime: block.timestamp,
                lockPeriod: lockPeriod,
                lockedRewards: calculateStakerRewards(_amount),
                claimedRewards: 0,
                unstaked: false
            })
        );
        userStakeIndexes[owner].push(stakeRecords.length - 1);
        emit Stake(owner, _amount, block.timestamp, lockPeriod);
    }

    function unstake(uint256 _index) external returns (uint256){
        StakeInfo storage _stake = stakeRecords[_index];
        require(_stake.owner == msg.sender, "Not owner");
        require(block.timestamp >= _stake.startTime + _stake.lockPeriod, "Lock period not ended");
        require(!_stake.unstaked, "Already claimed");
        _stake.unstaked = true;
        unstakedCollateral += _stake.amount;
        token.safeTransfer(_stake.owner, _stake.amount);
        emit Unstake(_stake.owner, _stake.amount, _index);
        return _stake.amount;
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
        token.safeTransfer(_stake.owner, toBeClaimed);
        // toBeClaimed / beneficiaryShare = stakerRewardShare / (100 - stakerRewardShare)
        uint256 beneficiaryShare = (toBeClaimed * (100 - stakerRewardShare)) / stakerRewardShare;
        beneficiary.totalRewards += beneficiaryShare;
        emit RewardsClaimed(_stake.owner, toBeClaimed, _index);
        return toBeClaimed;
    }

    function claimBeneficiaryRewards() external returns (uint256) {
        require(beneficiary.owner == msg.sender, "Not Beneficiary");
        uint256 rewards = beneficiary.totalRewards - beneficiary.claimedRewards;
        beneficiary.claimedRewards += rewards;
        totalClaimedRewards += rewards;
        token.safeTransfer(msg.sender, rewards);
        emit BeneficiaryRewardsClaimed(msg.sender, rewards);
        return rewards;
    }

    // collect the locked token for admin
    function collect() external onlyAdmin returns (uint256) {
        require(
            totalCollateral + totalSecurityDeposit < token.balanceOf(address(this)) + unstakedCollateral + totalClaimedRewards,
            "No locked token"
        );
        uint256 extraToken = token.balanceOf(address(this)) - (totalCollateral + totalSecurityDeposit - unstakedCollateral - totalClaimedRewards);
        token.safeTransfer(provider.owner, extraToken);
        emit CollectExtra(extraToken);
        return extraToken;
    }

    function getCollateralBySecurityDeposit(uint256 _amount) public view returns (uint256) {
        // (apy * lockPeriod / 360 days) = x days rewards rate
        // collateral * (x days rewards rate) = security deposit
        return (_amount * PRECISION) / ((apy * lockPeriod) / 360 days);
    }

    function getSecurityDepositByCollateral(uint256 _amount) public view returns (uint256) {
        return (_amount * ((apy * lockPeriod) / 360 days)) / PRECISION;
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
