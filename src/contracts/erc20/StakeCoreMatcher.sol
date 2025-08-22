// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "./interfaces/IStakeCore.sol";
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
    error InvalidDealId();
    error IllegalDealStatus(DealStatus);
    error InvalidAmount();
    error TooMuchAmount();

    struct StakeParam {
        IStakeCore stakecore;
        address owner;
        uint256 amount;
    }

    enum DealStatus {
        __,
        Pending,
        Partial,
        Success,
        Abort
    }

    struct Deal {
        uint256 targetUsdt;
        uint256 targetToken;
        uint256 paidUsdt;
        uint256 paidToken;
        StakeParam[] params;
        DealStatus status;
    }

    struct VestingParam {
        uint256 amount;
        uint256 expiration;
    }

    event DealCreated(uint256 dealId, uint256 targetUsdt, uint256 targetToken);
    event DealUsdtPaid(uint256 dealId, uint256 amount);
    event DealTokenPaid(uint256 dealId, uint256 amount);
    event DealAborted(uint256 dealId, uint256 usdtAmount, uint256 tokenAmount);
    event UsdtWithdrawn(uint256 released, uint256 amount);
    event DealSettled(uint256 dealId, uint256 usedToken, uint256 trimmedUsdt, DealStatus status);

    IERC20 public immutable usdt;
    IERC20 public immutable token;
    uint256 public immutable lockPeriod;

    address public staker;
    address public provider;

    uint256 public lockedToken;
    uint256 public lockedUsdt;
    Deal[] private deals;

    VestingParam[]  private vestingSchedule;
    uint256 public nextVesting;
    uint256 private withdrawableUsdt;




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



    constructor(address owner, address _staker, address _provider, address _usdt, address _token, uint256 _lockPeriod) Ownable(owner){
        if (owner == address(0)) revert ZeroAddress();
        if (_staker == address(0)) revert ZeroAddress();
        if (_provider == address(0)) revert ZeroAddress();
        if (_usdt == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();

        staker = _staker;
        provider = _provider;
        usdt = IERC20(_usdt);
        token = IERC20(_token);
        lockPeriod = _lockPeriod;
    }

    function newDeal(uint256 targetUsdt, StakeParam[] calldata stakeParams) external nonReentrant onlyStakerOrProvider {
        uint256 targetToken;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            if (stakeParams[i].owner == address(0)) revert ZeroAddress();
            if (address(stakeParams[i].stakecore) == address(0)) revert ZeroAddress();
            IERC20 _token = stakeParams[i].stakecore.token();
            if (_token != token) revert IllegalStake();

            uint256 minStakeAmount = stakeParams[i].stakecore.minStakeAmount();
            uint256 stakeAmount = stakeParams[i].amount;
            if (minStakeAmount > stakeAmount) revert StakeAmountInsufficient(address(stakeParams[i].stakecore), stakeAmount);

            targetToken += stakeAmount;
        }
        require(targetToken > 0, "targetTokenAmount=0");
        require(targetUsdt > 0, "targetUsdt=0");

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

    function payToken(uint256 dealId, uint256 amount, bool todo) external onlyProvider nonReentrant {
        if (dealId >= deals.length) revert InvalidDealId();
        if (amount == 0) revert InvalidAmount();
        Deal storage deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        if (deal.paidToken + amount > deal.targetToken) revert TooMuchAmount();
        deal.paidToken += amount;
        lockedToken += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit DealTokenPaid(dealId, amount);

        if (todo && deal.paidUsdt != 0) {
            _stake(dealId);
        }
    }

    function payUsdt(uint256 dealId, uint256 amount, bool todo) external onlyStaker nonReentrant {
        if (dealId >= deals.length) revert InvalidDealId();
        if (amount == 0) revert InvalidAmount();
        Deal storage deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        if (deal.paidUsdt + amount > deal.targetUsdt) revert TooMuchAmount();

        deal.paidUsdt += amount;
        lockedUsdt += amount;
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        emit DealUsdtPaid(dealId, amount);

        if (todo && deal.paidToken != 0) {
            _stake(dealId);
        }
    }

    function stake(uint256 dealId) external onlyStakerOrProvider nonReentrant {
        _stake(dealId);
    }

    function withdraw(uint256 amount) external onlyProvider nonReentrant returns (bool){
        if (amount == 0) revert InvalidAmount();

        (uint256 releasableUsdt,uint256 nextIdx) = calcReleasableUsdt();
        if (releasableUsdt != 0) {
            nextVesting = nextIdx;
            lockedUsdt -= releasableUsdt;
            withdrawableUsdt += releasableUsdt;
        }

        if (amount > withdrawableUsdt) {
            emit UsdtWithdrawn(releasableUsdt, 0);
            return false;
        }

        withdrawableUsdt -= amount;
        usdt.safeTransfer(msg.sender, amount);
        emit UsdtWithdrawn(releasableUsdt, amount);
        return true;
    }

    function abort(uint256 dealId) external onlyStakerOrProvider nonReentrant {
        if (dealId >= deals.length) revert InvalidDealId();
        Deal storage deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        deal.status = DealStatus.Abort;
        lockedUsdt -= deal.paidUsdt;
        lockedToken -= deal.paidToken;
        usdt.safeTransfer(staker, deal.paidUsdt);
        token.safeTransfer(provider, deal.paidToken);
        emit DealAborted(dealId, deal.paidUsdt, deal.paidToken);
    }

    function _stake(uint256 dealId) private {
        if (dealId >= deals.length) revert InvalidDealId();
        Deal memory deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        require(deal.paidUsdt > 0, "unpaid usdt");
        require(deal.paidToken > 0, "unpaid token");

        uint256 trimmedToken;
        uint256 trimmedUsdt;
        if (deal.targetUsdt * deal.paidToken >= deal.targetToken * deal.paidUsdt) {
            trimmedUsdt = deal.paidUsdt;
            trimmedToken = deal.targetToken * deal.paidUsdt / deal.targetUsdt;
        } else {
            trimmedToken = deal.paidToken;
            trimmedUsdt = deal.targetUsdt * deal.paidToken / deal.targetToken;
        }


        lockedToken -= deal.paidToken;

        uint256 paramsLen = deal.params.length;
        uint256 usedToken = 0;
        for (uint256 i = 0; i < paramsLen; i++) {
            uint256 paidAmount = trimmedToken * deal.params[i].amount / deal.targetToken;
            address spender = address(deal.params[i].stakecore);
            bool ok0 = token.approve(spender, 0);
            bool ok1 = token.approve(spender, paidAmount);
            require(ok0 && ok1, "approve fail");
            deal.params[i].stakecore.stake(deal.params[i].owner, paidAmount);
            usedToken += paidAmount;
        }


        if (deal.paidToken > usedToken) {
            token.safeTransfer(provider, deal.paidToken - usedToken);
            deals[dealId].paidToken = usedToken;
        }


        uint256 leftUsdt = deal.paidUsdt - trimmedUsdt;
        if (leftUsdt > 0) {
            usdt.safeTransfer(staker, leftUsdt);
            deals[dealId].paidUsdt = trimmedUsdt;
            lockedUsdt -= leftUsdt;
        }


        DealStatus status;
        if (deal.targetUsdt == trimmedUsdt && deal.targetToken == usedToken) {
            status = DealStatus.Success;
        } else {
            status = DealStatus.Partial;
        }
        deals[dealId].status = status;

        if (lockPeriod == 0) {
            lockedUsdt -= trimmedUsdt;
            withdrawableUsdt += trimmedUsdt;
        } else {
            vestingSchedule.push(
                VestingParam({
                    amount: trimmedUsdt,
                    expiration: block.timestamp + lockPeriod
                }
                )
            );
        }

        emit DealSettled(dealId, usedToken, trimmedUsdt, status);
    }

    function collectUSDT(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = usdt.balanceOf(address(this));
        uint256 required = withdrawableUsdt + lockedUsdt;

        require(bal > required, "no surplus usdt");
        usdt.safeTransfer(to, bal - required);
    }

    function collectToken(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = token.balanceOf(address(this));
        uint256 required = lockedToken;

        require(bal > required, "no surplus token");
        token.safeTransfer(to, bal - required);
    }

    function dealsLength() external view returns (uint256) {return deals.length;}

    function getDeal(uint256 id) external view returns (Deal memory) {return deals[id];}

    function calcWithdrawableUsdt() external view returns (uint256){
        (uint256 releasableUsdt, uint256 __) = calcReleasableUsdt();
        return withdrawableUsdt + releasableUsdt;
    }

    function calcReleasableUsdt() private view returns (uint256, uint256){
        uint256 _nextVesting = nextVesting;
        uint256 vestingLen = vestingSchedule.length;
        uint256 cap = _nextVesting + 8;
        if (vestingLen > cap) vestingLen = cap;

        uint256 releasableUsdt = 0;
        for (; _nextVesting < vestingLen; _nextVesting++) {
            if (block.timestamp < vestingSchedule[_nextVesting].expiration) {
                break;
            }

            releasableUsdt += vestingSchedule[_nextVesting].amount;
        }

        return (releasableUsdt, _nextVesting);
    }

    function vestingLength() public view returns (uint256){
        return vestingSchedule.length;
    }

    function vestingAt(uint256 i) public view returns (VestingParam memory){
        return vestingSchedule[i];
    }
}