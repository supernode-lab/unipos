// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../../base/UniversalToken.sol";
import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Matcher is UniversalToken, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidDealId();
    error InsufficientToken();
    error InsufficientUsdt();
    error DealLocking();
    error StakerAlreadyInited();
    error ProviderAlreadyInited();
    error StakeAmountInsufficient(address, uint256);
    error IllegalStakecore();
    error IllegalDealStatus(DealStatus);
    error TooMuchAmount();
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    struct StakeParam {
        IStakeCore stakecore;
        address beneficiary;
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


    event StakerInited(address);
    event ProviderInited(address, address[]);
    event DealCreated(uint256 dealId, uint256 targetUsdt, uint256 targetToken);
    event DealUsdtPaid(uint256 dealId, uint256 amount);
    event DealTokenPaid(uint256 dealId, uint256 amount);
    event DealAborted(uint256 dealId, uint256 usdtAmount, uint256 tokenAmount);
    event UsdtWithdrawn(uint256 amount);
    event DealSettled(uint256 dealId, uint256 usedToken, uint256 usedUsdt, DealStatus status);

    error ForbidRevokeMainProvider();
    error OnlyStaker(address caller);
    error OnlyProvider(address caller);
    error OnlyStakerOrProvider(address caller);
    error OnlyAdmin(address caller);

    bytes32 public constant PROVIDER_ROLE = keccak256("PROVIDER");
    IERC20 public immutable USDT;
    uint256 public immutable LOCK_PERIOD;

    address public staker;
    address public provider;

    uint256 public lockedToken;
    uint256 public lockedUsdt;
    Deal[] private deals;

    uint256 public withdrawableUsdt;


    modifier onlyStaker(){
        if (msg.sender != staker) revert OnlyStaker(msg.sender);
        _;
    }

    modifier onlyProvider(){
        if (msg.sender != provider && !hasRole(PROVIDER_ROLE, msg.sender)) revert OnlyProvider(msg.sender);
        _;
    }

    modifier onlyStakerOrProvider(){
        if (msg .sender != staker &&
            msg.sender != provider &&
            !hasRole(PROVIDER_ROLE, msg.sender)
        ) revert OnlyStakerOrProvider(msg.sender);
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert OnlyAdmin(msg.sender);
        _;
    }


    constructor(address admin, address _usdt, address token, uint256 _lockPeriod)  UniversalToken(IERC20(token)){
        if (admin == address(0)) revert InvalidParameter("admin");
        if (_usdt == address(0)) revert InvalidParameter("usdt");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(PROVIDER_ROLE, PROVIDER_ROLE);
        USDT = IERC20(_usdt);
        LOCK_PERIOD = _lockPeriod;
    }

    function initStaker(address _staker) external onlyAdmin {
        if (_staker == address(0)) revert InvalidParameter("staker");
        if (staker != (address(0))) revert StakerAlreadyInited();
        staker = _staker;
        emit StakerInited(_staker);
    }

    function initProvider(address mainProvider, address[] memory providers) external onlyAdmin {
        if (mainProvider == address(0)) revert InvalidParameter("mainProvider");
        if (provider != (address(0))) revert ProviderAlreadyInited();

        for (uint256 i = 0; i < providers.length; i++) {
            if (providers[i] == address(0)) revert InvalidParameter("providers");
            _grantRole(PROVIDER_ROLE, providers[i]);
        }

        provider = mainProvider;
        _grantRole(PROVIDER_ROLE, mainProvider);

        emit ProviderInited(mainProvider, providers);
    }


    function newDeal(uint256 targetUsdt, StakeParam[] calldata stakeParams) external nonReentrant onlyStakerOrProvider {
        if (targetUsdt == 0) revert InvalidParameter("targetUsdt");
        uint256 targetToken;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            if (stakeParams[i].beneficiary == address(0)) revert InvalidParameter("stakeParams.beneficiary");
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
        lockedToken += amount;
        if (deal.firstPaid == 0) {
            deal.firstPaid = block.timestamp;
        }
        _receiveToken(amount);
        emit DealTokenPaid(dealId, amount);

        if (autoMatch && deal.paidUsdt > deal.usedUsdt) {
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

        if (autoMatch && deal.paidToken > deal.usedToken) {
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
        if (availableToken <= availableUsdt * deal.targetToken / deal.targetUsdt) {
            trimmedToken = availableToken;
        } else {
            trimmedToken = availableUsdt * deal.targetToken / deal.targetUsdt;
        }

        uint256 paramsLen = deal.params.length;
        uint256 usedToken = 0;
        for (uint256 i = 0; i < paramsLen; i++) {
            uint256 apyAmount = deal.params[i].apyAmount;
            uint256 stakeAmount = deal.params[i].stakeAmount;
            IStakeCore stakecore = deal.params[i].stakecore;
            address owner = deal.params[i].beneficiary;
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
        uint256 usedUsdt = usedToken * deal.targetUsdt / deal.targetToken;

        DealStatus status = DealStatus.Pending;
        if (deal.targetUsdt <= deal.paidUsdt && deal.targetToken <= deal.paidToken) {
            status = DealStatus.Success;
            deals[dealId].status = DealStatus.Success;

            uint256 remainingToken = availableToken - usedToken;
            uint256 remainingUsdt = availableUsdt - usedUsdt;

            if (remainingToken > 0) {
                _sendToken(provider, remainingToken);
                deals[dealId].paidToken -= remainingToken;
                lockedToken -= remainingToken;
            }

            if (remainingUsdt > 0) {
                USDT.safeTransfer(staker, remainingUsdt);
                deals[dealId].paidUsdt -= remainingUsdt;
                lockedUsdt -= remainingUsdt;
            }
        }

        deals[dealId].usedUsdt += usedUsdt;
        deals[dealId].usedToken += usedToken;
        lockedUsdt -= usedUsdt;
        lockedToken -= usedToken;
        withdrawableUsdt += usedUsdt;

        emit DealSettled(dealId, usedToken, usedUsdt, status);
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

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (role == PROVIDER_ROLE && account == provider) revert ForbidRevokeMainProvider();
        _revokeRole(role, account);
    }


    function renounceRole(bytes32 role, address account) public override {
        if (role == PROVIDER_ROLE && account == provider) revert ForbidRevokeMainProvider();
        super.renounceRole(role, account);
    }

    function dealsLength() external view returns (uint256) {return deals.length;}

    function getDeal(uint256 dealId) external view returns (Deal memory) {
        if (dealId >= deals.length) revert InvalidDealId();
        return deals[dealId];
    }
}