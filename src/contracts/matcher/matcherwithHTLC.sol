// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../../base/UniversalToken.sol";
import {IStakeCore} from "../interfaces/IStakeCore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MatcherWithHtlc is UniversalToken, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error InvalidDealId();
    error StakerAlreadyInited();
    error ProviderAlreadyInited();
    error StakeAmountInsufficient(address, uint256);
    error IllegalStakecore();
    error IllegalDealStatus(DealStatus);
    error AlreadyExists();
    error NotFound();
    error AlreadyClaimed();
    error AlreadyRefunded();
    error HashlockMismatch();
    error NotBeforeExpiry(); // for claim
    error NotAfterExpiry();  // for refund
    error ForbidRevokeMainProvider();
    error OnlyStaker(address caller);
    error OnlyProvider(address caller);
    error OnlyStakerOrProvider(address caller);
    error OnlyAdmin(address caller);
    error NoExcessTokens();

    event Locked(
        bytes32 dealId,
        address sender,
        address recipient,
        address token,
        uint256 amount,
        uint64  timelock,
        bytes32 hashlock
    );
    event Claimed(bytes32 dealId, bytes32 preimage);
    event Refunded(bytes32 dealId);
    event StakerInited(address);
    event ProviderInited(address, address[]);
    event DealCreated(uint256 dealId, uint256 targetToken);
    event DealSettled(uint256 dealId, uint256 usedToken);
    event DealFailed(uint256 dealId);
    event ExcessCollected(address erc20, uint256 extraToken);

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

    struct Swap {
        uint256 dealId;
        address sender;       // who locked the funds
        uint256 amount;       // actual amount escrowed
        uint64 timelock;     // unix timestamp (seconds)
        bytes32 hashlock;     // keccak256(preimage)
        bool claimed;
        bool refunded;
        bytes32 preimage;     // revealed on claim
    }

    struct Deal {
        uint256 targetToken;
        StakeParam[] params;
        DealStatus status;
    }

    bytes32 public constant STAKECORE_ROLE = keccak256("STAKECORE");
    bytes32 public constant BENEFICIARY_ROLE = keccak256("BENEFICIARY");
    bytes32 public constant PROVIDER_ROLE = keccak256("PROVIDER");

    address public staker;
    address public provider;

    uint256 public lockedToken;
    Deal[] private deals;

// dealId => Swap
    mapping(bytes32 => Swap) public swaps;


    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyStaker(){
        _onlyStaker();
        _;
    }

    modifier onlyProvider(){
        _onlyProvider();
        _;
    }

    modifier onlyStakerOrProvider(){
        _onlyStakerOrProvider();
        _;
    }



    constructor(address admin, address token)  UniversalToken(IERC20(token)){
        if (admin == address(0)) revert InvalidParameter("admin");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(PROVIDER_ROLE, PROVIDER_ROLE);
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

    function newDeal(StakeParam[] calldata stakeParams) external nonReentrant onlyStakerOrProvider {
        uint256 targetToken;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            if (!isBeneficiary(stakeParams[i].beneficiary)) revert InvalidParameter("stakeParams.beneficiary");
            if (!isStakecore(address(stakeParams[i].stakecore))) revert InvalidParameter("stakeParams.stakecore");

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
        deal.targetToken = targetToken;
        deal.status = DealStatus.Pending;
        for (uint256 i = 0; i < stakeParams.length; i++) {
            deal.params.push(
                stakeParams[i]
            );
        }

        emit DealCreated(dealId, targetToken);
    }

/// @notice Lock native (token==address(0)) or ERC20 with a hashlock+timelock (pulls tokens via transferFrom)
/// @return dealId deterministic ID including sender nonce
    function lockToken(
        uint256 dealId,
        uint256 amount,
        bytes32 hashlock,
        uint64 periodlock
    ) external payable onlyProvider nonReentrant returns (bytes32) {
        if (dealId >= deals.length) revert InvalidDealId();
        if (hashlock == bytes32(0)) revert InvalidParameter("hashlock");
        if (periodlock == 0) revert InvalidParameter("periodlock");

        Deal storage deal = deals[dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        if (deal.targetToken != amount) revert InvalidParameter("amount");

        bytes32 swapId = bytes32(dealId);
        if (swaps[swapId].sender != address(0)) revert AlreadyExists();

        _receiveToken(amount);

        uint64 timelock = periodlock + uint64(block.timestamp);
        swaps[swapId] = Swap({
            dealId: dealId,
            sender: msg.sender,
            amount: amount,
            timelock: timelock,
            hashlock: hashlock,
            claimed: false,
            refunded: false,
            preimage: 0x0
        });
        lockedToken += amount;

        emit Locked(swapId, msg.sender, staker, address(token()), amount, timelock, hashlock);
        return swapId;
    }

/// @notice Claim funds by providing the correct preimage before timelock
    function stake(bytes32 dealId, bytes32 preimage) external onlyStaker nonReentrant {
        Swap storage s = swaps[dealId];
        if (s.sender == address(0)) revert NotFound();
        if (s.claimed) revert AlreadyClaimed();
        if (s.refunded) revert AlreadyRefunded();
        if (block.timestamp > s.timelock) revert NotBeforeExpiry();
        if (keccak256(abi.encodePacked(preimage)) != s.hashlock) revert HashlockMismatch();
        uint256 _dealId = s.dealId;
        if (_dealId >= deals.length) revert InvalidDealId();
        Deal storage deal = deals[_dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        try  this._stake(_dealId) {}catch{
            deal.status = DealStatus.Abort;
            lockedToken -= deal.targetToken;
            emit DealFailed(_dealId);
            _sendToken(msg.sender, deal.targetToken);
        }

        s.claimed = true;
        s.preimage = preimage;

        emit Claimed(dealId, preimage);
    }

/// @notice Refund to sender after timelock passes if not claimed
    function abort(bytes32 dealId) external onlyProvider nonReentrant {
        Swap storage s = swaps[dealId];
        if (s.sender == address(0)) revert NotFound();
        if (s.refunded) revert AlreadyRefunded();
        if (s.claimed) revert AlreadyClaimed();
        if (msg.sender != s.sender) revert UnauthorizedCaller(msg.sender);
        if (block.timestamp <= s.timelock) revert NotAfterExpiry();
        uint256 _dealId = s.dealId;
        if (_dealId >= deals.length) revert InvalidDealId();
        Deal storage deal = deals[_dealId];
        if (deal.status != DealStatus.Pending) revert IllegalDealStatus(deal.status);
        s.refunded = true;
        deal.status = DealStatus.Abort;
        lockedToken -= deal.targetToken;
        _sendToken(s.sender, s.amount);
        emit Refunded(dealId);
    }

/// @notice View helper
    function getSwap(bytes32 dealId) external view returns (Swap memory) {
        if (swaps[dealId].sender == address(0)) revert NotFound();
        return swaps[dealId];
    }

// ======= internal payout =======
    function _stake(uint256 dealId) external {
        require(msg.sender == address(this), "only self");
        Deal storage deal = deals[dealId];
        uint256 paramsLen = deal.params.length;
        for (uint256 i = 0; i < paramsLen; i++) {
            StakeParam memory p = deal.params[i];
            if (p.apyAmount != 0) {
                _callStakecoreDepositSecurity(p.stakecore, p.apyAmount);
            }

            if (p.stakeAmount != 0) {
                _callStakecoreStake(p.stakecore, p.beneficiary, p.stakeAmount);
            }
        }

        deal.status = DealStatus.Success;
        lockedToken -= deal.targetToken;
        emit DealSettled(dealId, deal.targetToken);
    }


    function _callStakecoreStake(IStakeCore stakecore, address owner, uint256 amount) private {
        address spender = address(stakecore);
        if (isNativeToken()) {
            stakecore.stake{value: amount}(owner, amount);
        } else {
            _TOKEN.forceApprove(spender, amount);
            stakecore.stake(owner, amount);
        }
    }

    function _callStakecoreDepositSecurity(IStakeCore stakecore, uint256 amount) private {
        address spender = address(stakecore);
        if (isNativeToken()) {
            stakecore.depositSecurity{value: amount}(amount);
        } else {
            _TOKEN.forceApprove(spender, amount);
            stakecore.depositSecurity(amount);
        }
    }

    function dealsLength() external view returns (uint256) {return deals.length;}

    function getDeal(uint256 dealId) external view returns (Deal memory) {
        if (dealId >= deals.length) revert InvalidDealId();
        return deals[dealId];
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (role == PROVIDER_ROLE && account == provider) revert ForbidRevokeMainProvider();
        _revokeRole(role, account);
    }


    function renounceRole(bytes32 role, address account) public override {
        if (role == PROVIDER_ROLE && account == provider) revert ForbidRevokeMainProvider();
        super.renounceRole(role, account);
    }

    function isStakecore(address addr) public view returns (bool){
        return hasRole(STAKECORE_ROLE, addr);
    }

    function isBeneficiary(address addr) public view returns (bool){
        return hasRole(BENEFICIARY_ROLE, addr);
    }

    function _onlyAdmin() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert OnlyAdmin(msg.sender);
    }

    function _onlyStaker() internal view {
        if (msg.sender != staker) revert OnlyStaker(msg.sender);
    }

    function _onlyProvider() internal view {
        if (msg.sender != provider && !hasRole(PROVIDER_ROLE, msg.sender)) revert OnlyProvider(msg.sender);
    }

    function _onlyStakerOrProvider() internal view {
        if (msg .sender != staker &&
        msg.sender != provider &&
            !hasRole(PROVIDER_ROLE, msg.sender)
        ) revert OnlyStakerOrProvider(msg.sender);
    }

    function collect(IERC20 erc20) external onlyAdmin nonReentrant returns (uint256) {
        uint256 bal;
        uint256 heldToken;
        if (erc20 == token()) {
            bal = balance();
            heldToken = lockedToken;
        }else if (address(erc20) == address(0)) {
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