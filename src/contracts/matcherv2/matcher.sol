// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseUniversalToken} from "../../base/baseUniversalToken.sol";
import {LibUniversalToken} from "../../libraries/LibUniversalToken.sol";
import {BaseError} from "../interfaces/BaseError.sol";
import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Matcher is BaseUniversalToken, AccessControl, ReentrancyGuard, BaseError {
    using SafeERC20 for IERC20;

    error InsufficientFunds();
    error InvalidStakeVn();
    error StakeAmountTooLow();
    error InsufficientBalance(uint256 balance, uint256 needed);
    error NoExcessTokens();
    error SecurityLocking();

    event UsdtWithdrawn(uint256 amount);
    event SecurityDeposited(uint256 amount, uint256 totalSecurity);
    event SecurityWithdrawn(uint256 amount, uint256 remainingSecurity);
    event SubscribedByUSDT(uint256 usdtAmount, address[]owners, uint256 exchangedToken, uint256 vn);
    event SubscribedByToken(uint256 tokenAmount, address[]owners, uint256 vn);

    event StakeInfoUpdated(IStakeCore[]  stakecores, uint256[]  ratios, IStakeCore kpiStakecore, uint256 kpiRatio, uint256 idx);
    event PriceUpdated(uint256 price, uint256 decimals);
    event BeneficiaryUpdated(address newBeneficiary);
    event MinSubscribeAmountUpdated(uint256 newMinSubscribeAmount);
    event ExcessCollected(address erc20, uint256 extraToken);
    event SecurityLockPeriodUpdated(uint256 newSecurityLockPeriod);

    struct StakeInfo {
        IStakeCore[] stakes;
        uint256[] ratios;
        IStakeCore kpiStake;
        uint256 kpiRatio;
    }

    struct PriceInfo {
        uint256 price;
        uint8 decimals;
    }

    bytes32 public constant PROVIDER_ROLE = keccak256("PROVIDER");
    uint256 public constant PRECISION = 1e18;
    IERC20 public immutable USDT;

    uint256 public  SECURITY_LOCK_PERIOD;
    uint256 public securityUnlockTime;

    uint256 public totalSecurity;
    uint256 public deposited;
    uint256 public exchanged;

    uint256 public totalUsdt;
    uint256 public withdrawnUsdt;

    address public beneficiary;
    uint256 public minSubscribeAmount;

    PriceInfo public priceInfo;
    StakeInfo[] private stakes;

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }

    modifier  onlyProvider(){
        _checkRole(PROVIDER_ROLE);
        _;
    }


    constructor(address admin, address provider, address _beneficiary, address usdt, address token, uint256 securityLockPeriod, uint256 _minSubscribeAmount, uint256 tokenPrice, uint8 priceDecimals, IStakeCore[] memory stakecores, uint256[]memory ratios, IStakeCore kpiStakecore, uint256 kpiRatio)  BaseUniversalToken(IERC20(token)){
        if (admin == address(0)) revert InvalidParameter("admin");
        if (provider == address(0)) revert InvalidParameter("provider");
        if (_beneficiary == address(0)) revert InvalidParameter("beneficiary");
        if (usdt == address(0)) revert InvalidParameter("usdt");

        _setRoleAdmin(PROVIDER_ROLE, PROVIDER_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROVIDER_ROLE, provider);

        beneficiary = _beneficiary;
        USDT = IERC20(usdt);
        SECURITY_LOCK_PERIOD = securityLockPeriod;
        minSubscribeAmount = _minSubscribeAmount;

        _setPrice(tokenPrice, priceDecimals);
        _setStakeInfo(stakecores, ratios, kpiStakecore, kpiRatio);
    }

    function withdrawUsdt(uint256 amount) external onlyProvider nonReentrant {
        uint256 balance = totalUsdt - withdrawnUsdt;
        if (amount > balance) revert InsufficientBalance(balance, amount);
        USDT.safeTransfer(msg.sender, amount);
        withdrawnUsdt += amount;
        emit UsdtWithdrawn(amount);
    }

    function depositSecurity(uint256 amount) external payable onlyProvider nonReentrant {
        totalSecurity += amount;
        securityUnlockTime = block.timestamp + SECURITY_LOCK_PERIOD;
        _receiveToken(amount);
        emit SecurityDeposited(amount, totalSecurity);
    }

    function withdrawSecurity(uint256 amount) external onlyProvider nonReentrant {
        if (block.timestamp < securityUnlockTime) revert SecurityLocking();
        uint256 ts = totalSecurity;
        uint256 tr = deposited + exchanged;
        if (ts <= tr) revert InsufficientBalance(0, amount);
        uint256 available = ts - tr;
        if (available < amount) revert InsufficientBalance(available, amount);
        ts -= amount;
        totalSecurity = ts;
        _sendToken(msg.sender, amount);
        emit SecurityWithdrawn(amount, ts);
    }

    function subscribeByUsdt(uint256 cost, address[] memory owners) public nonReentrant {
        (uint256 price,uint8 decimals) = getPrice();
        uint256 tokenAmount = cost * (10 ** decimals) / price;
        uint256 needUsdtAmount = tokenAmount * price / (10 ** decimals);
        uint256 beforeBal = USDT.balanceOf(address(this));
        USDT.safeTransferFrom(msg.sender, address(this), needUsdtAmount);
        uint256 afterBal = USDT.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        if (received != needUsdtAmount) revert LibUniversalToken.ERC20ReceiveMismatch(needUsdtAmount, received);

        if (tokenAmount + deposited + exchanged > totalSecurity) revert InsufficientFunds();

        exchanged += tokenAmount;
        totalUsdt += needUsdtAmount;

        uint256 vn = _stake(tokenAmount, owners);
        emit SubscribedByUSDT(needUsdtAmount, owners, tokenAmount, vn);
    }

    function subscribeByToken(uint256 amount, address[] calldata owners) public payable nonReentrant {
        _receiveToken(amount);
        uint256 vn = _stake(amount, owners);
        emit SubscribedByToken(amount, owners, vn);
    }

    function _stake(uint256 amount, address[] memory owners) internal returns (uint256){
        if (amount < minSubscribeAmount) revert StakeAmountTooLow();

        (StakeInfo memory stakeInfo,uint256 vn) = getStakeInfo();
        uint256 stakesLen = stakeInfo.stakes.length;
        if (owners.length != stakesLen) revert InvalidParameter("owner");

        uint256 kpiRewards = amount * stakeInfo.kpiRatio / PRECISION;
        uint256 accPrincipal;
        uint256 accRewards = kpiRewards;
        uint256 []memory principals = new uint256 [](stakesLen);
        uint256[] memory rewards = new uint256[](stakesLen);

        for (uint256 i = 0; i < stakesLen; i++) {
            uint256 principal;
            if (i + 1 == stakesLen) {
                principal = amount - accPrincipal;
            } else {
                principal = amount * stakeInfo.ratios[i] / PRECISION;
            }

            uint256 reward = stakeInfo.stakes[i].getSecurityDepositByCollateral(principal);
            principals[i] = principal;
            accPrincipal += principal;
            rewards[i] = reward;
            accRewards += reward;
        }

        if (accRewards + deposited + exchanged > totalSecurity) revert InsufficientFunds();

        for (uint256 i = 0; i < stakesLen; i++) {
            IStakeCore stake = stakeInfo.stakes[i];
            uint256 reward = rewards[i];
            if (reward != 0) {
                token().forceApprove(address(stake), reward);
                stake.depositSecurity(reward);
            }

            token().forceApprove(address(stake), principals[i]);
            stake.stake(owners[i], principals[i]);
        }

        if (kpiRewards != 0) {
            token().forceApprove(address(stakeInfo.kpiStake), kpiRewards);
            stakeInfo.kpiStake.stake(beneficiary, kpiRewards);
        }

        deposited += accRewards;
        return vn;
    }


    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    function renounceRole(bytes32, address) public pure override {
        revert Forbid();
    }

    function setSecurityLockPeriod(uint256 newSecurityLockPeriod) external onlyAdmin {
        SECURITY_LOCK_PERIOD = newSecurityLockPeriod;
        emit SecurityLockPeriodUpdated(newSecurityLockPeriod);
    }

    function setMinSubscribeAmount(uint256 amount) external onlyAdmin {
        minSubscribeAmount = amount;
        emit MinSubscribeAmountUpdated(amount);
    }

    function setBeneficiary(address newBeneficiary) external onlyAdmin {
        beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(newBeneficiary);
    }

    function setPrice(uint256 price, uint8 decimals) external onlyAdmin {
        _setPrice(price, decimals);
        emit PriceUpdated(price, decimals);
    }

    function _setPrice(uint256 price, uint8 decimals) internal {
        if (price == 0) revert InvalidParameter("price");
        if (decimals > 24) revert InvalidParameter("decimals");
        priceInfo.price = price;
        priceInfo.decimals = decimals;
    }

    function setStakeInfo(IStakeCore[] memory stakecores, uint256[] memory ratios, IStakeCore kpiStakecore, uint256 kpiRatio) external onlyAdmin {
        uint256 stakeInfoIdx = _setStakeInfo(stakecores, ratios, kpiStakecore, kpiRatio);
        emit StakeInfoUpdated(stakecores, ratios, kpiStakecore, kpiRatio, stakeInfoIdx);
    }

    function _setStakeInfo(IStakeCore[] memory stakecores, uint256[] memory ratios, IStakeCore kpiStakecore, uint256 kpiRatio) internal returns (uint256) {
        if (stakecores.length != ratios.length) revert InvalidParameter("stakes&ratios");

        uint256 stakeLen = stakecores.length;
        uint256 totalRatio = 0;
        IERC20 _token = token();
        for (uint256 i = 0; i < stakeLen; i++) {
            if (_token != stakecores[i].token()) revert InvalidParameter("stake");
            totalRatio += ratios[i];
        }

        if (totalRatio != PRECISION) revert InvalidParameter("ratios");

        if (kpiRatio != 0) {
            if (address(kpiStakecore) == address(0)) revert InvalidParameter("stake");
            if (_token != kpiStakecore.token()) revert InvalidParameter("stake");
        }

        stakes.push();
        uint256 stakeInfoIdx = stakes.length - 1;
        stakes[stakeInfoIdx].stakes = stakecores;
        stakes[stakeInfoIdx].ratios = ratios;
        stakes[stakeInfoIdx].kpiStake = kpiStakecore;
        stakes[stakeInfoIdx].kpiRatio = kpiRatio;
        return stakeInfoIdx;
    }


    function getPrice() public view returns (uint256, uint8){
        return (priceInfo.price, priceInfo.decimals);
    }

    function getStakeInfo() public view returns (StakeInfo memory stakeInfo, uint256 vn){
        vn = stakes.length - 1;
        stakeInfo = stakes[vn];
    }

    function getStakeInfoAtVersion(uint256 vn) public view returns (StakeInfo memory){
        if (stakes.length <= vn) revert InvalidStakeVn();
        return stakes[vn];
    }

    function getStakeInfoLength() public view returns (uint256){
        return stakes.length;
    }

    function collect(IERC20 erc20) external onlyAdmin nonReentrant returns (uint256) {
        uint256 bal;
        uint256 heldToken;
        if (erc20 == token()) {
            bal = balance();
            heldToken = totalSecurity - exchanged - deposited;
        } else if (erc20 == USDT) {
            bal = erc20.balanceOf(address(this));
            heldToken = totalUsdt - withdrawnUsdt;
        } else if (address(erc20) == address(0)) {
            bal = address(this).balance;
            heldToken = 0;
        } else {
            bal = erc20.balanceOf(address(this));
            heldToken = 0;
        }

        if (bal <= heldToken) revert NoExcessTokens();
        uint256 extraToken = bal - heldToken;
        if (address(erc20) == address(0)) {
            (bool success,) = payable(msg.sender).call{value: extraToken}("");
            require(success);
        } else {
            erc20.safeTransfer(msg.sender, extraToken);
        }

        emit ExcessCollected(address(erc20), extraToken);
        return extraToken;
    }
}