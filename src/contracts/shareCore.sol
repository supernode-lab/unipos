// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "./StakeCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract ShareCore {
    using SafeERC20 for IERC20;

    struct ShareholderInfo {
        address owner;
        uint256 grantedReward;
        uint256 claimedReward;
        uint256 grantedPrincipal;
        uint256 claimedPrincipal;
    }

    IStakeCore  public immutable stakeCore;
    IERC20 public immutable token;

    uint256[] public shareIDs;
    mapping(uint256 => bool) registeredSharedIDs;

    uint256 public totalReward;
    uint256 public claimedReward;
    uint256 public grantedReward;


    uint256 public principal;
    uint256 public grantedPrincipal;
    uint256 public claimedPrincipal;

    address[] public shareholders;
    mapping(address => ShareholderInfo) public shareholdersInfo;

    address public admin;

    // Events
    event ShareholderAdded(address indexed shareholder, uint256 grantedReward, uint256 grantedPrincipal);
    event StakeRewardsClaimed(uint256 shareIDs, uint256 amount);
    event StakePrincipalClaimed(uint256 shareIDs, uint256 amount);
    event RewardsClaimed(address indexed shareholder, uint256 amount);
    event PrincipalClaimed(address indexed shareholder, uint256 amount);

    event RewardsCollected(uint256 amount);
    event RewardsDistributed(uint256 totalRewards);

    constructor(IERC20 _token, address _admin, address _stakeCore) {
        require(_admin != address(0), "Admin address can't be zero");
        require(_stakeCore != address(0), "StakeCore address can't be zero");

        token = _token;
        admin = _admin;
        stakeCore = IStakeCore(_stakeCore);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function addShareholder(address _owner, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyAdmin {
        require(grantedReward + _grantedReward <= totalReward, "Remaining reward is insufficient");
        require(grantedPrincipal + _grantedPrincipal <= principal, "Remaining principal is insufficient");
        require(shareholdersInfo[_owner].owner == address(0), "Shareholder already exists");

        shareholders.push(_owner);
        shareholdersInfo[_owner] = ShareholderInfo({
            owner: _owner,
            grantedReward: _grantedReward,
            claimedReward: 0,
            grantedPrincipal: _grantedPrincipal,
            claimedPrincipal: 0
        });
        grantedReward += _grantedReward;
        grantedPrincipal += _grantedPrincipal;

        emit ShareholderAdded(_owner, _grantedReward, _grantedPrincipal);
    }

    function register() external {
        uint256[] memory _shareIDs = stakeCore.getUserStakeIndexes(address(this));
        if (_shareIDs.length == shareIDs.length) {
            return;
        }

        uint256 newAmount = 0;
        uint256 newReward = 0;
        for (uint256 i = shareIDs.length; i < _shareIDs.length; i++) {
            IStakeCore.StakeInfo memory stakeInfo = stakeCore.getStakeRecords(_shareIDs[i]);
            newAmount += stakeInfo.amount;
            newReward += (stakeInfo.claimedRewards + stakeInfo.lockedRewards);
            shareIDs.push(_shareIDs[i]);
            registeredSharedIDs[_shareIDs[i]] = true;
        }

        principal += newAmount;
        totalReward += newReward;
    }

    function ClaimStakeRewards(uint256 _sharedID) external {
        require(registeredSharedIDs[_sharedID], "the sharedID has not registered yet");
        uint256 amount = stakeCore.claimRewards(_sharedID);
        claimedReward += amount;
        emit StakeRewardsClaimed(_sharedID, amount);
    }

    function ClaimStakePrincipal(uint256 _sharedID) external {
        require(registeredSharedIDs[_sharedID], "the sharedID has not registered yet");
        uint256 amount = stakeCore.unstake(_sharedID);
        claimedPrincipal += amount;
        emit StakePrincipalClaimed(_sharedID, amount);
    }

    function claimRewards() external {
        ShareholderInfo storage info = shareholdersInfo[msg.sender];
        require(info.owner == msg.sender, "Not a shareholder");
        //require(info.grantedReward > info.claimedReward, "No rewards");
        uint256 claimableTotalReward = calculateShareholderRewards(info.grantedReward);
        require(claimableTotalReward > info.claimedReward, "No rewards");
        uint256 claimableReward = claimableTotalReward - info.claimedReward;

        info.claimedReward = claimableTotalReward;
        token.safeTransfer(msg.sender, claimableReward);
        emit RewardsClaimed(msg.sender, claimableReward);
    }

    function claimPrincipal() external {
        ShareholderInfo storage info = shareholdersInfo[msg.sender];
        require(info.owner == msg.sender, "Not a shareholder");
        //require(info.grantedReward > info.claimedReward, "No rewards");
        uint256 claimableTotalPrincipal = calculateShareholderPrincipal(info.grantedPrincipal);
        require(claimableTotalPrincipal > info.claimedPrincipal, "No Principal");
        uint256 claimablePrincipal = claimableTotalPrincipal - info.claimedPrincipal;

        info.claimedPrincipal = claimableTotalPrincipal;
        token.safeTransfer(msg.sender, claimablePrincipal);
        emit PrincipalClaimed(msg.sender, claimablePrincipal);
    }

    function calculateShareholderRewards(uint256 _shareholderGrantedReward) internal returns (uint256){
        return _shareholderGrantedReward * claimedReward / totalReward;
    }

    function calculateShareholderPrincipal(uint256 _shareholderGrantedPrincipal) internal returns (uint256){
        return _shareholderGrantedPrincipal * claimedPrincipal / principal;
    }

    function collect() external onlyAdmin returns (uint256) {
        //  withdraw extra token from this contract
        uint256 balance = token.balanceOf(address(this));
        require(balance >= totalReward, "Not enough token");
        token.safeTransfer(admin, balance - totalReward);
        emit RewardsCollected(balance - totalReward);
        return balance - totalReward;
    }

    function getShareholderInfo(address _shareholder) external view returns (ShareholderInfo memory) {
        return shareholdersInfo[_shareholder];
    }
}
