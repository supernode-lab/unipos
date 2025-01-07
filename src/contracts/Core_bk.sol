// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice 
 */
contract Core {
    using SafeERC20 for IERC20;
    struct StakeInfo {
        address owner;
        uint256 amount; 
        uint256 startTime;
        uint256 lockPeriod;
        bool claimed;
        bool unstaked;
    }
    struct BeneficiaryStorage {
        address owner;
        uint256 totalRewards;
        uint256 claimedRewards;
    }
    uint256 public constant PRECISION = 1e18;
    IERC20 public immutable token;
    uint256 public immutable stakePeriod;
    uint256 public immutable stakerShare;
    uint256 public immutable apy;
    uint256 public immutable minimumStakeAmount;

    // total user staked amount
    uint256 public totalCollateral;
    // total security deposit amount
    uint256 public totalSecurityDeposite;
    // total required stake amount
    uint256 public requiredCollateral;

    StakeInfo[] public StakesList;
    mapping(address => uint256[]) public userStakes; // 每个用户的质押记录

    address public admin;
    BeneficiaryStorage public beneficiary;


    constructor(IERC20 _token, address _beneficiary) {
        token = _token;
        stakePeriod = 180 days;
        stakerShare = 60; // percentage, based on 100
        apy = 120 * PRECISION / 100;
        minimumStakeAmount = 100 * 1e18;
        admin = msg.sender;
        beneficiary.owner = _beneficiary;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function deposit(uint256 _amount) external onlyAdmin {
        token.safeTransferFrom(msg.sender, address(this), _amount);
        totalSecurityDeposite += _amount;
        requiredCollateral = getCollateralBySecurityDeposit(totalSecurityDeposite);
    }

    function withdraw(uint256 _amount) external onlyAdmin {
        uint256 remainingCollateral = requiredCollateral - totalCollateral;
        uint256 withdrawnableSecurityDeposit = getSecurityDepositByCollateral(remainingCollateral);
        require(withdrawnableSecurityDeposit >= _amount, "No enough balance");
        token.safeTransfer(msg.sender, _amount);
        totalSecurityDeposite -= _amount;
        requiredCollateral = getCollateralBySecurityDeposit(totalSecurityDeposite);
    }

    /// @notice stakers stake tokens, and can stake multiple times
    function stake(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(_amount >= minimumStakeAmount, "Amount must be greater than minimum stake amount");
        require(totalCollateral + _amount <= requiredCollateral, "No enough allowance");
        token.safeTransferFrom(msg.sender, address(this), _amount);
        totalCollateral += _amount;
        StakesList.push(StakeInfo({
            owner: msg.sender,
            amount: _amount,
            startTime: block.timestamp,
            lockPeriod: stakePeriod,
            claimed: false,
            unstaked: false
        }));
        userStakes[msg.sender].push(StakesList.length - 1);
    }

    function unstake(uint256 _index) external {
        StakeInfo storage _stake = StakesList[_index];
        require(_stake.owner == msg.sender, "Not owner");
        require(block.timestamp >= _stake.startTime + _stake.lockPeriod, "Lock period not ended");
        require(!_stake.unstaked, "Already claimed");
        _stake.unstaked = true;
        token.safeTransfer(msg.sender, _stake.amount);
    }

    function claimRewards(uint256 _index) external {
        StakeInfo storage _stake = StakesList[_index];
        require(_stake.owner == msg.sender || _stake.owner == beneficiary.owner, "Not owner or Beneficiary");
        require(block.timestamp >= _stake.startTime + _stake.lockPeriod, "Lock period not ended");
        require(!_stake.claimed, "Already claimed");
        uint256 totalRewards = getSecurityDepositByCollateral(_stake.amount);
        uint256 beneficiaryRewards = totalRewards * stakerShare / 100;
        _stake.claimed = true;
        // transfer rewards to owner
        token.safeTransfer(_stake.owner, totalRewards - beneficiaryRewards);
        beneficiary.totalRewards += beneficiaryRewards;
    }

    function claimBeneficiaryRewards() external {
        require(beneficiary.owner == msg.sender, "Not Beneficiary");
        uint256 rewards = beneficiary.totalRewards - beneficiary.claimedRewards;
        beneficiary.claimedRewards += rewards;
        token.safeTransfer(msg.sender, rewards);
    }

    function getCollateralBySecurityDeposit(uint256 _amount) public view returns (uint256) {
        // (apy * stakePeriod / 365 days) = x days rewards rate
        // collateral * (x days rewards rate) = security deposit
        return _amount * PRECISION / (apy * stakePeriod / 365 days);
    }

    function getSecurityDepositByCollateral(uint256 _amount) public view returns (uint256) {
        return _amount * (apy * stakePeriod / 365 days) / PRECISION;
    }

    function getStakerRewards(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = StakesList[_index];
        uint256 totalRewards = getSecurityDepositByCollateral(_stake.amount);
        uint256 beneficiaryRewards = totalRewards * stakerShare / 100;
        return totalRewards - beneficiaryRewards;
    }

    // function getStaker
}
