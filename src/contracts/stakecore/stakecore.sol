// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../../base/UniversalToken.sol";
import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract StakeCore is UniversalToken, IStakeCore, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PROVIDER_ROLE = keccak256("PROVIDER");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER");
    bytes32 public constant BENEFICIARY_ROLE = keccak256("BENEFICIARY");

    bool public immutable ENABLE_STAKER_WHITE_LIST;
    bool public immutable ENABLE_BENEFICIARY_WHITE_LIST;
    uint256 public constant PRECISION = 1e18;

    uint256 public immutable LOCK_PERIOD;
    uint256 public immutable CLIFF_PERIOD;
    uint256 public immutable APY;
    uint256 public immutable INSTALLMENT_NUM;
    //uint256 public immutable principalInstallments;
    uint256 private immutable MIN_STAKE_AMOUNT;
    // total user staked amount
    uint256 public totalCollateral;
    uint256 public unstakedCollateral;

    uint256 public totalRewards;
    uint256 public totalWithdrawnRewards;
    // total security deposit amount
    uint256 public totalSecurityDeposit;

    IStakeCore.StakeInfo[] private stakeRecords;
    mapping(address => uint256[]) private userStakeIndexes; // 每个用户的质押记录

    constructor(address admin, address[] memory providers, IERC20 _token, uint256 lockPeriod, uint256 cliffPeriod, uint256 _apy, uint256 _installmentNum, uint256 _minStakeAmount, bool enableStakerWhiteList, bool enableBeneficiaryWhiteList)UniversalToken(_token) {
        if (admin == address(0)) revert InvalidParameter("admin");
        if (providers.length == 0) revert InvalidParameter("providers");
        if (_installmentNum == 0) revert InvalidParameter("installmentNum");
        if (cliffPeriod > lockPeriod) revert InvalidParameter("cliffPeriod");

        ENABLE_STAKER_WHITE_LIST = enableStakerWhiteList;
        ENABLE_BENEFICIARY_WHITE_LIST = enableBeneficiaryWhiteList;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(PROVIDER_ROLE, PROVIDER_ROLE);
        for (uint256 i = 0; i < providers.length; i++) {
            if (providers[i] == address(0)) revert InvalidParameter("providers");
            bool ok = _grantRole(PROVIDER_ROLE, providers[i]);
            if (!ok) revert InvalidParameter("providers");
        }
        LOCK_PERIOD = lockPeriod;
        CLIFF_PERIOD = cliffPeriod;
        APY = (_apy * PRECISION) / 100;
        MIN_STAKE_AMOUNT = _minStakeAmount;
        INSTALLMENT_NUM = _installmentNum;
    }


    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }

    modifier onlyProvider() {
        _checkRole(PROVIDER_ROLE);
        _;
    }

    function depositSecurity(uint256 _amount) external payable onlyProvider nonReentrant {
        if (APY == 0) revert Forbid();
        totalSecurityDeposit += _amount;
        _receiveToken(_amount);
        emit SecurityDeposited(_amount, totalSecurityDeposit);
    }

    function withdrawSecurity(uint256 _amount) external onlyProvider nonReentrant {
        if (APY == 0) revert Forbid();
        uint256 tsd = totalSecurityDeposit;
        uint256 tr = totalRewards;
        if (tsd < tr) revert InsufficientBalance(0, _amount);
        uint256 available = tsd - tr;
        if (available < _amount) revert InsufficientBalance(available, _amount);
        tsd -= _amount;
        totalSecurityDeposit = tsd;
        _sendToken(msg.sender, _amount);
        emit SecurityWithdrawn(_amount, tsd);
    }

    /// @notice stakers stake tokens, and can stake multiple times
    function stake(address owner, uint256 _amount) external payable nonReentrant {
        if (owner == address(0)) revert InvalidParameter("owner");
        if (_amount == 0 || _amount < MIN_STAKE_AMOUNT) revert InvalidParameter("amount");
        if (ENABLE_STAKER_WHITE_LIST) {
            _checkRole(STAKER_ROLE);
        }

        if (ENABLE_BENEFICIARY_WHITE_LIST) {
            _checkRole(BENEFICIARY_ROLE, owner);
        }

        uint256 rewards;
        uint256 principal;
        if (APY == 0) {
            principal = 0;
            rewards = _amount;
        } else {
            principal = _amount;
            rewards = getSecurityDepositByCollateral(_amount);
            if (rewards + totalRewards > totalSecurityDeposit) revert InsufficientDeposit(totalSecurityDeposit - totalRewards, rewards);
        }

        totalCollateral += principal;
        totalRewards += rewards;
        _receiveToken(_amount);
        stakeRecords.push(
            StakeInfo({
                owner: owner,
                startTime: block.timestamp,
                lockPeriod: LOCK_PERIOD,
                totalPrincipal: principal,
                withdrawnPrincipal: 0,
                totalRewards: rewards,
                withdrawnRewards: 0
            })
        );

        uint256 idx = stakeRecords.length - 1;
        userStakeIndexes[owner].push(idx);
        emit Staked(owner, principal, rewards, block.timestamp, LOCK_PERIOD, idx);
    }

    function withdrawPrincipal(uint256 _index) external nonReentrant returns (uint256){
        StakeInfo storage _stake = stakeRecords[_index];
        if (_stake.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlocked = getUnlockedInstallmentPrincipal(_index);
        if (_stake.withdrawnPrincipal >= totalUnlocked) revert NoPrincipal();
        uint256 toBeWithdrawn = totalUnlocked - _stake.withdrawnPrincipal;
        _stake.withdrawnPrincipal += toBeWithdrawn;
        unstakedCollateral += toBeWithdrawn;
        _sendToken(_stake.owner, toBeWithdrawn);
        emit PrincipalWithdrawn(_stake.owner, toBeWithdrawn, _index);
        return toBeWithdrawn;
    }

    function withdrawRewards(uint256 _index) external nonReentrant returns (uint256){
        StakeInfo storage _stake = stakeRecords[_index];
        address owner = _stake.owner;
        uint256 withdrawnRewards = _stake.withdrawnRewards;
        if (owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlocked = getUnlockedInstallmentRewards(_index);
        if (withdrawnRewards >= totalUnlocked) revert NoRewards();
        uint256 toBeWithdrawn = totalUnlocked - withdrawnRewards;
        _stake.withdrawnRewards += toBeWithdrawn;
        totalWithdrawnRewards += toBeWithdrawn;
        _sendToken(owner, toBeWithdrawn);
        emit RewardsWithdrawn(owner, toBeWithdrawn, _index);
        return toBeWithdrawn;
    }

    // collect the locked token for admin
    function collect() external onlyAdmin nonReentrant returns (uint256) {
        uint256 _balance = balance();
        uint256 netObligation;
        if (APY == 0) {
            netObligation = totalRewards - totalWithdrawnRewards;
        } else {
            netObligation = totalCollateral + totalSecurityDeposit
                - unstakedCollateral - totalWithdrawnRewards;
        }

        if (_balance <= netObligation) revert NoExcessTokens();
        uint256 extraToken = _balance - netObligation;
        _sendToken(msg.sender, extraToken);
        emit ExcessCollected(extraToken);
        return extraToken;
    }

    function getCollateralBySecurityDeposit(uint256 _amount) public view returns (uint256) {
        // (apy * lockPeriod / 360 days) = x days rewards rate
        // collateral * (x days rewards rate) = security deposit
        if (APY == 0) {
            return type(uint256).max;
        }
        return (_amount * PRECISION) / ((APY * LOCK_PERIOD) / 360 days);
    }

    function getSecurityDepositByCollateral(uint256 _amount) public view returns (uint256) {
        return (_amount * ((APY * LOCK_PERIOD) / 360 days)) / PRECISION;
    }

    function getUnlockedInstallmentRewards(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        if (elapsedTime < CLIFF_PERIOD) {
            return 0;
        }

        if (elapsedTime >= LOCK_PERIOD) {
            return _stake.totalRewards;
        }

        uint256 vestWindow = LOCK_PERIOD - CLIFF_PERIOD;
        uint256 vestedTime = elapsedTime - CLIFF_PERIOD;
        uint256 unlockedPhase = (vestedTime * INSTALLMENT_NUM) / vestWindow;
        uint256 unlockedRewardsByInstallment = (_stake.totalRewards / INSTALLMENT_NUM) * unlockedPhase;
        return unlockedRewardsByInstallment;
    }

    function getUnlockedInstallmentPrincipal(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        if (elapsedTime >= LOCK_PERIOD) {
            return _stake.totalPrincipal;
        }

        return 0;
    }

    function stakeRecordsLength() public view returns (uint256){
        return stakeRecords.length;
    }

    function getStakeRecords(uint256 _index) external view returns (StakeInfo memory){
        return stakeRecords[_index];
    }

    function getUserStakeIndexes(address owner) external view returns (uint256[]memory){
        return userStakeIndexes[owner];
    }

    function token() public view override(UniversalToken, IStakeCore) returns (IERC20){
        return _TOKEN;
    }

    function isAdmin(address addr) public view returns (bool){
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function isProvider(address addr) public view returns (bool){
        return hasRole(PROVIDER_ROLE, addr);
    }

    function isStaker(address addr) public view returns (bool){
        return hasRole(STAKER_ROLE, addr);
    }

    function isBeneficiary(address addr) public view returns (bool){
        return hasRole(BENEFICIARY_ROLE, addr);
    }

    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32, address) public pure override {
        revert Forbid();
    }

    function renounceRole(bytes32, address) public pure override {
        revert Forbid();
    }

    function minStakeAmount() external view returns (uint256){
        return MIN_STAKE_AMOUNT;
    }

}
