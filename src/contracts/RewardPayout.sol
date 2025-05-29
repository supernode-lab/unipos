// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore, StakeCore} from "./StakeCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract RewardPayout is IStakeCore, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Events
    event RewardsClaimed(address indexed staker, uint256 amount, uint256 index);
    event SecurityDeposited(uint256 amount, uint256 totalSecurity);
    event SecurityWithdrawn(uint256 amount, uint256 remainingSecurity);
    event CollectExtra(uint256 extraToken);


    struct Provider {
        address owner;
        address pendingOwner;
    }


    StakeCore public immutable stake;
    uint256 public constant PRECISION = 1e18;
    IERC20 public immutable token;
    uint256 public immutable lockPeriod;
    uint256 public immutable apy;
    uint256 public immutable installmentNum;

    // total user staked amount
    uint256 public totalCollateral;
    uint256 public totalClaimedRewards;
    // total security deposit amount
    uint256 public totalSecurityDeposit;
    // total required stake amount
    uint256 public requiredCollateral;

    IStakeCore.StakeInfo[] internal stakeRecords;

    address public beneficiary;
    address public admin;
    Provider public provider;

    constructor(StakeCore _stake, uint256 _apy, address _provider, address _beneficiary, address _admin) {
        stake = _stake;
        token = _stake.token();
        lockPeriod = _stake.lockPeriod();
        apy = (_apy * PRECISION) / 100;
        installmentNum = _stake.installmentNum();
        provider.owner = _provider;
        beneficiary = _beneficiary;
        admin = _admin;
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

    function sync() external returns (bool){
        uint256 start = stakeRecords.length;
        for (start;; start++) {
            try stake.getStakeInfo(start)returns (IStakeCore.StakeInfo memory stakeInfo){
                if (stakeInfo.amount + totalCollateral > requiredCollateral) {
                    return false;
                }

                uint256 lockedRewards = getSecurityDepositByCollateral(stakeInfo.amount);
                totalCollateral += stakeInfo.amount;
                stakeRecords.push(IStakeCore.StakeInfo({
                    owner: beneficiary,
                    amount: 0,
                    startTime: stakeInfo.startTime,
                    lockPeriod: stakeInfo.lockPeriod,
                    lockedRewards: lockedRewards,
                    claimedRewards: 0,
                    unstaked: false
                }));
            }catch{
                return true;
            }
        }

        return true;
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

    function unstake(uint256 _index) external pure returns (uint256){
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
        token.safeTransfer(_stake.owner, toBeClaimed);
        emit RewardsClaimed(_stake.owner, toBeClaimed, _index);
        return toBeClaimed;
    }

    // collect the locked token for admin
    function collect() external onlyAdmin returns (uint256) {
        require(
            totalSecurityDeposit < token.balanceOf(address(this)) + totalClaimedRewards,
            "No locked token"
        );
        uint256 extraToken = token.balanceOf(address(this)) - (totalSecurityDeposit - totalClaimedRewards);
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

    function getUnlockedInstallmentRewards(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 totalRewards = _stake.claimedRewards + _stake.lockedRewards;
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        // calculate the number of unlocked rewards by installment
        uint256 unlockedPhase = elapsedTime >= lockPeriod ? installmentNum : (elapsedTime * installmentNum) / lockPeriod;
        uint256 unlockedRewardsByInstallment = (totalRewards / installmentNum) * unlockedPhase;
        return unlockedRewardsByInstallment;
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

    function getStakeRecords(uint256 _index) external view returns (StakeInfo memory){
        return stakeRecords[_index];
    }

    function getUserStakeIndexes(address owner) external view returns (uint256[]memory){
        if (owner != beneficiary) {
            return new uint256[](0);
        }

        uint256 []memory indexes = new uint256[](stakeRecords.length);
        for (uint256 i = 0; i < indexes.length; i++) {
            indexes[i] = i;
        }

        return indexes;
    }


}