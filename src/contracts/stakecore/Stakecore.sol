// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract StakeCore is IStakeCore, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PROVIDER_ROLE = keccak256("PROVIDER");
    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable token;
    uint256 public immutable lockPeriod;
    uint256 public immutable apy;
    uint256 public immutable rewardInstallments;
    uint256 public immutable principalInstallments;
    uint256 public immutable minStakeAmount;
    // total user staked amount
    uint256 public totalCollateral;
    uint256 public unstakedCollateral;

    uint256 public totalWithdrawnRewards;
    // total security deposit amount
    uint256 public totalSecurityDeposit;


    IStakeCore.StakeInfo[] private stakeRecords;
    mapping(address => uint256[]) private userStakeIndexes; // 每个用户的质押记录

    constructor(address admin, address[] memory providers, IERC20 _token, uint256 _lockPeriod, uint256 _apy, uint256 _rewardInstallments, uint256 _principalInstallments, uint256 _minStakeAmount) {
        if (admin == address(0)) revert InvalidParameter("admin");
        if (providers.length == 0) revert InvalidParameter("providers");
        if (_rewardInstallments == 0) revert InvalidParameter("rewardInstallments");
        if (_principalInstallments == 0) revert InvalidParameter("principalInstallments");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(PROVIDER_ROLE, PROVIDER_ROLE);
        for (uint256 i = 0; i < providers.length; i++) {
            if (providers[i] == address(0)) revert InvalidParameter("providers");
            _grantRole(PROVIDER_ROLE, providers[i]);
        }
        token = _token;
        lockPeriod = _lockPeriod;
        apy = (_apy * PRECISION) / 100;
        minStakeAmount = _minStakeAmount;
        rewardInstallments = _rewardInstallments;
        principalInstallments = _principalInstallments;
    }


    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }
    modifier onlyProvider() {
        _checkRole(PROVIDER_ROLE);
        _;
    }

    function _sendToken(address account, uint256 amount) private {
        if (isNativeToken()) {
            (bool success,) = payable(account).call{value: amount}("");
            require(success);
        } else {
            token.safeTransfer(account, amount);
        }
    }

    function _receiveToken(uint256 amount) private {
        if (isNativeToken()) {
            if (msg.value != amount) revert IllegalValue();
        } else {
            if (msg.value != 0) revert IllegalValue();
            token.safeTransferFrom(msg.sender, address(this), amount);
        }
    }


    function depositSecurity(uint256 _amount) external payable onlyProvider nonReentrant {
        if (apy == 0) revert Forbid();
        totalSecurityDeposit += _amount;
        _receiveToken(_amount);
        emit SecurityDeposited(_amount, totalSecurityDeposit);
    }


    function withdrawSecurity(uint256 _amount) external onlyProvider nonReentrant {
        if (apy == 0) revert Forbid();
        uint256 tsd = totalSecurityDeposit;
        uint256 requiredDeposit = getSecurityDepositByCollateral(totalCollateral);
        uint256 remainingDeposit = tsd - requiredDeposit;
        if (remainingDeposit < _amount) revert InsufficientBalance(remainingDeposit, _amount);
        tsd -= _amount;
        totalSecurityDeposit = tsd;
        _sendToken(msg.sender, _amount);
        emit SecurityWithdrawn(_amount, tsd);
    }

    /// @notice stakers stake tokens, and can stake multiple times
    function stake(address owner, uint256 _amount) external payable nonReentrant {
        if (owner == address(0)) revert InvalidParameter("owner");
        if (_amount == 0 || _amount < minStakeAmount) revert InvalidParameter("amount");
        uint256 totalRewards = getSecurityDepositByCollateral(_amount);
        uint256 requiredDeposit = getSecurityDepositByCollateral(totalCollateral + _amount);
        if (requiredDeposit > totalSecurityDeposit) revert InsufficientDeposit(totalSecurityDeposit, requiredDeposit);
        totalCollateral += _amount;
        _receiveToken(_amount);
        stakeRecords.push(
            StakeInfo({
                owner: owner,
                startTime: block.timestamp,
                lockPeriod: lockPeriod,
                totalPrincipal: _amount,
                withdrawnPrincipal: 0,
                totalRewards: totalRewards,
                withdrawnRewards: 0
            })
        );

        userStakeIndexes[owner].push(stakeRecords.length - 1);
        emit Staked(owner, _amount, block.timestamp, lockPeriod, stakeRecords.length - 1);
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
        if (_stake.owner != msg.sender) revert UnauthorizedCaller(msg.sender);
        uint256 totalUnlocked = getUnlockedInstallmentRewards(_index);
        if (_stake.withdrawnRewards >= totalUnlocked) revert NoRewards();
        uint256 toBeWithdrawn = totalUnlocked - _stake.withdrawnRewards;
        _stake.withdrawnRewards += toBeWithdrawn;
        totalWithdrawnRewards += toBeWithdrawn;
        _sendToken(_stake.owner, toBeWithdrawn);
        emit RewardsWithdrawn(_stake.owner, toBeWithdrawn, _index);
        return toBeWithdrawn;
    }

    // collect the locked token for admin
    function collect() external onlyAdmin nonReentrant returns (uint256) {
        uint256 _balance = balance();
        if (totalCollateral + totalSecurityDeposit >= _balance + unstakedCollateral + totalWithdrawnRewards) revert NoExcessTokens();
        uint256 extraToken = _balance - (totalCollateral + totalSecurityDeposit - unstakedCollateral - totalWithdrawnRewards);
        _sendToken(msg.sender, extraToken);
        emit ExcessCollected(extraToken);
        return extraToken;
    }

    function getCollateralBySecurityDeposit(uint256 _amount) public view returns (uint256) {
        // (apy * lockPeriod / 360 days) = x days rewards rate
        // collateral * (x days rewards rate) = security deposit
        if (apy == 0) {
            return type(uint256).max;
        }
        return (_amount * PRECISION) / ((apy * lockPeriod) / 360 days);
    }

    function getSecurityDepositByCollateral(uint256 _amount) public view returns (uint256) {
        return (_amount * ((apy * lockPeriod) / 360 days)) / PRECISION;
    }


    function getUnlockedInstallmentRewards(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        if (elapsedTime >= lockPeriod) {
            return _stake.totalRewards;
        }

        uint256 unlockedPhase = (elapsedTime * rewardInstallments) / lockPeriod;
        uint256 unlockedRewardsByInstallment = (_stake.totalRewards / rewardInstallments) * unlockedPhase;
        return unlockedRewardsByInstallment;
    }

    function getUnlockedInstallmentPrincipal(uint256 _index) public view returns (uint256) {
        StakeInfo storage _stake = stakeRecords[_index];
        uint256 elapsedTime = block.timestamp - _stake.startTime;
        if (elapsedTime >= lockPeriod) {
            return _stake.totalPrincipal;
        }

        uint256 unlockedPhase = (elapsedTime * principalInstallments) / lockPeriod;
        uint256 unlockedPrincipalByInstallment = (_stake.totalPrincipal / principalInstallments) * unlockedPhase;
        return unlockedPrincipalByInstallment;
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
        require(start < end, "invalid param");
        require(end <= stakeRecords.length, "End index out of bounds");
        StakeInfo[] memory stakeInfo = new StakeInfo[](end - start);
        for (uint256 i = start; i < end; i++) {
            stakeInfo[i - start] = stakeRecords[i];
        }
        return stakeInfo;
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

    function isNativeToken() public view returns (bool){
        return (address(token) == address(0));
    }

    function balance() public view returns (uint256){
        if (isNativeToken()) {
            return address(this).balance;
        } else {
            return token.balanceOf(address(this));
        }
    }

    function isAdmin(address addr) public view returns (bool){
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function isProvider(address addr) public view returns (bool){
        return hasRole(PROVIDER_ROLE, addr);
    }
}
