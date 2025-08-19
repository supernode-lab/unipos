// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "./interfaces/IStakeCore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakeCoreMatcher is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error StakeAmountInsufficient(address, uint256);
    error IllegalStake();

    struct StakeParam {
        IStakeCore stakecore;
        address owner;
        uint256 amount;
    }

    struct Deal {
        uint256 targetTokenAmount;
        uint256 paidUsdt;
        StakeParam[] params;
        DealStatus Status;
    }

    enum DealStatus {
        __,
        Pending,
        Partial,
        Success,
        Abort
    }

    event DealCreated(uint256 dealId, uint256 targetTokenAmount, uint256 paidUsdt, StakeParam[] stakeParams);
    event DealPaid(uint256 dealId, uint256 amount);
    event DealAborted(uint256 dealId, uint256 amount);
    event UsdtWithdrawn(uint256 amount);

    IERC20 public immutable usdt;
    IERC20 public immutable token;


    address public staker;
    address public provider;

    uint256 public lockedUsdt;
    uint256 public withdrawableUsdt;
    Deal[] public Deals;


    modifier onlyStaker(){
        require(msg.sender == staker, "Only staker");
        _;
    }

    modifier onlyProvider(){
        require(msg.sender == provider, "Only provider");
        _;
    }

    constructor(address owner, address _staker, address _provider, address _usdt, address _token) Ownable(owner){
        if (owner == address(0)) revert ZeroAddress();
        if (_staker == address(0)) revert ZeroAddress();
        if (_provider == address(0)) revert ZeroAddress();
        if (_usdt == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();

        staker = _staker;
        provider = _provider;
        usdt = IERC20(_usdt);
        token = IERC20(_token);
    }

    function newDeal(uint256 usdtAmount, StakeParam[] calldata stakeParams) external onlyStaker nonReentrant {
        uint256 targetTokenAmount;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            if (stakeParams[i].owner == address(0)) revert ZeroAddress();
            if (address(stakeParams[i].stakecore) == address(0)) revert ZeroAddress();
            IERC20 _token = stakeParams[i].stakecore.token();
            if (_token != token) revert IllegalStake();

            uint256 minStakeAmount = stakeParams[i].stakecore.minStakeAmount();
            uint256 stakeMount = stakeParams[i].amount;
            if (minStakeAmount > stakeMount) revert StakeAmountInsufficient(address(stakeParams[i].stakecore), stakeMount);

            targetTokenAmount += stakeMount;
        }
        require(targetTokenAmount > 0, "targetTokenAmount=0");
        require(usdtAmount > 0, "usdtAmount=0");

        Deals.push();
        uint256 dealId = Deals.length - 1;
        Deal storage deal = Deals[dealId];
        deal.targetTokenAmount = targetTokenAmount;
        deal.paidUsdt = usdtAmount;
        deal.Status = DealStatus.Pending;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            deal.params.push(
                stakeParams[i]
            );
        }

        lockedUsdt += usdtAmount;
        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        emit DealCreated(dealId, targetTokenAmount, usdtAmount, stakeParams);
    }

    function pay(uint256 dealId, uint256 amount) external onlyProvider nonReentrant {
        require(dealId < Deals.length, "Invalid dealId");
        require(amount > 0, "Invalid amount");
        Deal storage deal = Deals[dealId];
        require(deal.Status == DealStatus.Pending, "illegal status");
        require(amount <= deal.targetTokenAmount, "too much amount");

        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 usedTokenAmount = _stake(deal, amount);
        if (usedTokenAmount != amount) {
            token.safeTransfer(provider, amount - usedTokenAmount);
        }

        emit DealPaid(dealId, usedTokenAmount);
    }

    function withdraw(uint256 amount) external onlyProvider nonReentrant {
        require(amount > 0, "amount=0");
        require(amount <= withdrawableUsdt, "No enough balance");
        withdrawableUsdt -= amount;
        usdt.safeTransfer(msg.sender, amount);
        emit UsdtWithdrawn(amount);
    }

    function abort(uint256 dealId) external onlyStaker nonReentrant {
        require(dealId < Deals.length, "Invalid dealId");
        Deal storage deal = Deals[dealId];
        require(deal.Status == DealStatus.Pending, "illegal status");
        deal.Status = DealStatus.Abort;
        lockedUsdt -= deal.paidUsdt;
        usdt.safeTransfer(msg.sender, deal.paidUsdt);
        emit DealAborted(dealId, deal.paidUsdt);
    }

    function _stake(Deal storage deal, uint256 totalPaidAmount) internal returns (uint256){
        uint256 paramsLen = deal.params.length;
        uint256 targetTokenAmount = deal.targetTokenAmount;
        uint256 usedAmount = 0;
        for (uint256 i = 0; i < paramsLen; i++) {
            uint256 paidAmount = totalPaidAmount * deal.params[i].amount / targetTokenAmount;
            address spender = address(deal.params[i].stakecore);
            token.approve(spender, 0);
            token.approve(spender, paidAmount);
            deal.params[i].stakecore.stake(deal.params[i].owner, paidAmount);
            usedAmount += paidAmount;
        }

        uint256 shouldPayUsdt = deal.paidUsdt * usedAmount / targetTokenAmount;
        lockedUsdt -= deal.paidUsdt;
        withdrawableUsdt += shouldPayUsdt;
        if (shouldPayUsdt == deal.paidUsdt) {
            deal.Status = DealStatus.Success;
        } else {
            deal.Status = DealStatus.Partial;
            usdt.safeTransfer(staker, deal.paidUsdt - shouldPayUsdt);
        }

        return usedAmount;
    }

    function collectUSDT(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = usdt.balanceOf(address(this));
        uint256 required = withdrawableUsdt + lockedUsdt;

        require(bal > required, "no surplus usdt");
        uint256 surplus = bal - required;
        usdt.safeTransfer(to, surplus);
    }

    function collectToken(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "no surplus token");
        token.safeTransfer(to, bal);
    }

    function dealsLength() external view returns (uint256) {return Deals.length;}

    function getDeal(uint256 id) external view returns (Deal memory) {return Deals[id];}
}