// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "./interfaces/IStakeCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakeCoreMatcher is ReentrancyGuard{
    using SafeERC20 for IERC20;

    struct Deal {
        address beneficiary;
        uint256 targetTokenAmount;
        uint256 paidUsdt;
        DealStatus Status;
    }

    enum DealStatus {
        __,
        Pending,
        Success,
        Abort
    }

    event DealCreated(uint256 dealId, address beneficiary, uint256 targetTokenAmount, uint256 paidUsdt);
    event DealPaid(uint256 dealId, uint256 amount);
    event DealAborted(uint256 dealId, uint256 amount);
    event UsdtWithdrawn(uint256 amount);

    IERC20 public immutable usdt;
    IERC20 public immutable token;

    IStakeCore public immutable stakecore;

    address public staker;
    address public provider;

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

    constructor(address _staker, address _provider, address _usdt, address _stakeCore){
        require(_staker != address(0), "Staker can't be zero");
        require(_provider != address(0), "Provider can't be zero");
        require(_usdt != address(0), "Usdt can't be zero");
        require(_stakeCore != address(0), "StakeCore can't be zero");

        staker = _staker;
        provider = _provider;
        usdt = IERC20(_usdt);
        stakecore = IStakeCore(_stakeCore);
        token = stakecore.token();
    }

    function newDeal(address beneficiary, uint256 targetTokenAmount, uint256 usdtAmount) external onlyStaker nonReentrant {
        require(beneficiary != address(0), "beneficiary=0");
        require(targetTokenAmount > 0, "targetTokenAmount=0");
        require(usdtAmount > 0, "usdtAmount=0");

        Deals.push(
            Deal({
                beneficiary: beneficiary,
                targetTokenAmount: targetTokenAmount,
                paidUsdt: usdtAmount,
                Status: DealStatus.Pending
            })
        );

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        emit DealCreated(Deals.length - 1, beneficiary, targetTokenAmount, usdtAmount);
    }


    function pay(uint256 dealId) external onlyProvider nonReentrant {
        require(dealId < Deals.length, "Invalid dealId");
        Deal storage deal = Deals[dealId];
        require(deal.Status == DealStatus.Pending, "illegal status");
        token.safeTransferFrom(msg.sender, address(this), deal.targetTokenAmount);
        _stake(deal);
        emit DealPaid(dealId, deal.targetTokenAmount);
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
        usdt.safeTransfer(msg.sender, deal.paidUsdt);
        emit DealAborted(dealId, deal.paidUsdt);
    }

    function _stake(Deal storage deal) internal {
        address spender = address(stakecore);
        uint256 curr = token.allowance(address(this), spender);
        if (curr != 0) {
            token.approve(spender, 0);
        }
        token.approve(spender, deal.targetTokenAmount);
        deal.Status = DealStatus.Success;
        withdrawableUsdt += deal.paidUsdt;
        stakecore.stake(deal.beneficiary, deal.targetTokenAmount);
    }

    function dealsLength() external view returns (uint256) {return Deals.length;}

    function getDeal(uint256 id) external view returns (Deal memory) {return Deals[id];}
}