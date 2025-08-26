// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../../base/UniversalToken.sol";
import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakeCoreMatcher is UniversalToken, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidDealId();
    error InsufficientToken();
    error InsufficientUsdt();
    error DealLocking();

    error StakeAmountInsufficient(address, uint256);
    error IllegalStakecore();
    error IllegalDealStatus(DealStatus);
    error TooMuchAmount();
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    struct StakeParam {
        IStakeCore stakecore;
        address owner;
        uint256 apyAmount;
        uint256 stakeAmount;
    }

    enum DealStatus {
        __,
        Pending,
        Success,
        Abort
    }

    struct Deal {
        uint256 targetUsdt;
        uint256 targetToken;
        uint256 paidUsdt;
        uint256 paidToken;
        uint256 usedUsdt;
        uint256 usedToken;
        uint256 firstPaid;
        StakeParam[] params;
        DealStatus status;
    }


    event DealCreated(uint256 dealId, uint256 targetUsdt, uint256 targetToken);
    event DealUsdtPaid(uint256 dealId, uint256 amount);
    event DealTokenPaid(uint256 dealId, uint256 amount);
    event DealAborted(uint256 dealId, uint256 usdtAmount, uint256 tokenAmount);
    event UsdtWithdrawn(uint256 amount);
    event DealSettled(uint256 dealId, uint256 usedToken, uint256 trimmedUsdt, DealStatus status);

    IERC20 public immutable USDT;
    uint256 public immutable LOCK_PERIOD;

    address public staker;
    address public provider;

    uint256 public lockedToken;
    uint256 public lockedUsdt;
    Deal[] private deals;

    uint256 public withdrawableUsdt;


    modifier onlyStaker(){
        require(msg.sender == staker, "Only staker");
        _;
    }

    modifier onlyProvider(){
        require(msg.sender == provider, "Only provider");
        _;
    }

    modifier onlyStakerOrProvider(){
        require((msg.sender == staker || msg.sender == provider), "Only staker or provider");
        _;
    }


    constructor(address _staker, address _provider, address _usdt, address token, uint256 _lockPeriod) UniversalToken(IERC20(token)){
        if (_staker == address(0)) revert InvalidParameter("staker");
        if (_provider == address(0)) revert InvalidParameter("provider");
        if (_usdt == address(0)) revert InvalidParameter("usdt");

        staker = _staker;
        provider = _provider;
        USDT = IERC20(_usdt);
        LOCK_PERIOD = _lockPeriod;
    }

    function newDeal(uint256 targetUsdt, StakeParam[] calldata stakeParams) external nonReentrant onlyStakerOrProvider {
        if (targetUsdt == 0) revert InvalidParameter("targetUsdt");
        uint256 targetToken;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            if (stakeParams[i].owner == address(0)) revert InvalidParameter("stakeParams.owner");
            if (address(stakeParams[i].stakecore) == address(0)) revert InvalidParameter("stakeParams.stakecore");
            uint256 stakeAmount = stakeParams[i].stakeAmount;
            uint256 apyAmount = stakeParams[i].apyAmount;
            if (stakeAmount + apyAmount == 0) revert InvalidParameter("stakeParams.stakeAmount/apyAmount");
            IERC20 _token = stakeParams[i].stakecore.token();
            if (_token != token()) revert IllegalStakecore();

            if (stakeAmount != 0) {
                uint256 minStakeAmount = stakeParams[i].stakecore.minStakeAmount();
                if (minStakeAmount > stakeAmount) revert StakeAmountInsufficient(address(stakeParams[i].stakecore), stakeAmount);
            }
            targetToken += (stakeAmount + apyAmount);
        }


        deals.push();
        uint256 dealId = deals.length - 1;
        Deal storage deal = deals[dealId];
        deal.targetUsdt = targetUsdt;
        deal.targetToken = targetToken;
        deal.status = DealStatus.Pending;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            deal.params.push(
                stakeParams[i]
            );
        }

        emit DealCreated(dealId, targetUsdt, targetToken);
    }

    function payToken(uint256 dealId, uint256 amount, bool autoMatch) external payable onlyProvider nonReentrant {
        if (dealId >= deals.length) revert InvalidDealId();
        if (amount == 0) revert InvalidParameter("amount");
        Deal storage deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        if (deal.paidToken + amount > deal.targetToken) revert TooMuchAmount();
        deal.paidToken += amount;
        deal.paidUsdt += amount;
        lockedToken += amount;
        if (deal.firstPaid == 0) {
            deal.firstPaid = block.timestamp;
        }
        _receiveToken(amount);
        emit DealTokenPaid(dealId, amount);

        if (autoMatch && deal.paidUsdt != 0) {
            _stake(dealId);
        }
    }

    function payUsdt(uint256 dealId, uint256 amount, bool autoMatch) external onlyStaker nonReentrant {
        if (dealId >= deals.length) revert InvalidDealId();
        if (amount == 0) revert InvalidParameter("amount");
        Deal storage deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        if (deal.paidUsdt + amount > deal.targetUsdt) revert TooMuchAmount();
        deal.paidUsdt += amount;
        lockedUsdt += amount;
        if (deal.firstPaid == 0) {
            deal.firstPaid = block.timestamp;
        }
        USDT.safeTransferFrom(msg.sender, address(this), amount);
        emit DealUsdtPaid(dealId, amount);

        if (autoMatch && deal.paidToken != 0) {
            _stake(dealId);
        }
    }

    function stake(uint256 dealId) external onlyStakerOrProvider nonReentrant {
        _stake(dealId);
    }

    function withdraw(uint256 amount) external onlyProvider nonReentrant {
        if (amount > withdrawableUsdt) revert InsufficientBalance(msg.sender, withdrawableUsdt, amount);
        withdrawableUsdt -= amount;
        USDT.safeTransfer(msg.sender, amount);
        emit UsdtWithdrawn(amount);
    }

    function abort(uint256 dealId) external onlyStakerOrProvider nonReentrant {
        if (dealId >= deals.length) revert InvalidDealId();
        Deal storage deal = deals[dealId];
        if (block.timestamp < deal.firstPaid + LOCK_PERIOD) revert DealLocking();
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        uint256 availableUsdt = deal.paidUsdt - deal.usedUsdt;
        uint256 availableToken = deal.paidToken - deal.usedToken;
        deal.status = DealStatus.Abort;
        lockedUsdt -= availableUsdt;
        lockedToken -= availableToken;
        USDT.safeTransfer(staker, availableUsdt);
        _sendToken(provider, availableToken);
        emit DealAborted(dealId, availableUsdt, availableToken);
    }

    function _stake(uint256 dealId) private {
        if (dealId >= deals.length) revert InvalidDealId();
        Deal memory deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);

        uint256 availableUsdt = deal.paidUsdt - deal.usedUsdt;
        uint256 availableToken = deal.paidToken - deal.usedToken;

        if (availableUsdt == 0) revert InsufficientUsdt();
        if (availableToken == 0) revert InsufficientToken();

        uint256 trimmedToken;
        uint256 trimmedUsdt;
        if (deal.targetUsdt * availableToken >= deal.targetToken * availableUsdt) {
            trimmedUsdt = availableUsdt;
            trimmedToken = deal.targetToken * availableUsdt / deal.targetUsdt;
        } else {
            trimmedToken = availableToken;
            trimmedUsdt = deal.targetUsdt * availableToken / deal.targetToken;
        }


        uint256 paramsLen = deal.params.length;
        uint256 usedToken = 0;
        for (uint256 i = 0; i < paramsLen; i++) {
            uint256 apyAmount = deal.params[i].apyAmount;
            uint256 stakeAmount = deal.params[i].stakeAmount;
            IStakeCore stakecore = deal.params[i].stakecore;
            address owner = deal.params[i].owner;
            uint256 amount = apyAmount + stakeAmount;
            uint256 paidAmount = trimmedToken * amount / deal.targetToken;
            uint256 paidStakeAmount = paidAmount * stakeAmount / amount;
            uint256 paidDepositAmount = paidAmount - paidStakeAmount;
            if (paidDepositAmount != 0) {
                _callStakecoreDepositSecurity(stakecore, paidDepositAmount);
            }

            if (paidStakeAmount != 0) {
                _callStakecoreStake(stakecore, owner, paidStakeAmount);
            }

            usedToken += paidAmount;
        }


        DealStatus status = DealStatus.Pending;
        if (deal.targetUsdt == deal.paidUsdt && deal.targetToken == deal.paidToken) {
            status = DealStatus.Success;
            deals[dealId].status = DealStatus.Success;

            uint256 leftToken = availableToken - usedToken;
            if (leftToken > 0) {
                _sendToken(provider, leftToken);
                deals[dealId].paidToken -= leftToken;
                lockedToken -= leftToken;
            }


            uint256 leftUsdt = availableUsdt - trimmedUsdt;
            if (leftUsdt > 0) {
                USDT.safeTransfer(staker, leftUsdt);
                deals[dealId].paidUsdt -= leftUsdt;
                lockedUsdt -= leftUsdt;
            }
        }

        deals[dealId].usedUsdt += trimmedUsdt;
        deals[dealId].usedToken += usedToken;
        lockedUsdt -= trimmedUsdt;
        lockedToken -= usedToken;
        withdrawableUsdt += trimmedUsdt;

        emit DealSettled(dealId, usedToken, trimmedUsdt, status);
    }


    function _callStakecoreStake(IStakeCore stakecore, address owner, uint256 amount) private {
        address spender = address(stakecore);
        if (isNativeToken()) {
            stakecore.stake{value: amount}(owner, amount);
        } else {
            bool ok0 = _TOKEN.approve(spender, 0);
            bool ok1 = _TOKEN.approve(spender, amount);
            require(ok0 && ok1, "approve fail");
            stakecore.stake(owner, amount);
        }
    }

    function _callStakecoreDepositSecurity(IStakeCore stakecore, uint256 amount) private {
        address spender = address(stakecore);
        if (isNativeToken()) {
            stakecore.depositSecurity{value: amount}(amount);
        } else {
            bool ok0 = _TOKEN.approve(spender, 0);
            bool ok1 = _TOKEN.approve(spender, amount);
            require(ok0 && ok1, "approve fail");
            stakecore.depositSecurity(amount);
        }
    }


    function dealsLength() external view returns (uint256) {return deals.length;}

    function getDeal(uint256 id) external view returns (Deal memory) {return deals[id];}
}