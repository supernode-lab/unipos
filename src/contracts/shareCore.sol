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
        uint256 shareID;
        uint256 grantedReward;
        uint256 claimedReward;
        uint256 grantedPrincipal;
        uint256 claimedPrincipal;
    }

    struct ShareInfo {
        bool isSet;
        uint256 totalReward;
        uint256 claimedReward;
        uint256 grantedReward;
        uint256 principal;
        uint256 claimedPrincipal;
        uint256 grantedPrincipal;
    }

    IStakeCore  public immutable stakeCore;
    IERC20 public immutable token;
    address public admin;

    uint256[] public shareIDs;
    mapping(uint256 => ShareInfo) public sharesInfo;

    address[] public shareholders;
    mapping(address => ShareholderInfo) public shareholdersInfo;

    // Events
    event ShareholderAdded(address indexed shareholder, uint256 grantedReward, uint256 grantedPrincipal);
    event StakeRewardsClaimed(uint256 shareIDs, uint256 amount);
    event StakeRewardsClaimedBatch(uint256[] amount);

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

    function addShareholder(address _owner, uint256 _shareID, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyAdmin {
        ShareInfo storage shareInfo = sharesInfo[_shareID];
        require(shareInfo.isSet, "the shareID has not registered yet");
        require(shareInfo.grantedReward + _grantedReward <= shareInfo.totalReward, "Remaining reward is insufficient");
        require(shareInfo.grantedPrincipal + _grantedPrincipal <= shareInfo.principal, "Remaining principal is insufficient");
        require(shareholdersInfo[_owner].owner == address(0), "Shareholder already exists");

        shareholders.push(_owner);
        shareholdersInfo[_owner] = ShareholderInfo({
            owner: _owner,
            shareID: _shareID,
            grantedReward: _grantedReward,
            claimedReward: 0,
            grantedPrincipal: _grantedPrincipal,
            claimedPrincipal: 0
        });
        shareInfo.grantedReward += _grantedReward;
        shareInfo.grantedPrincipal += _grantedPrincipal;

        emit ShareholderAdded(_owner, _grantedReward, _grantedPrincipal);
    }

    function register() external {
        uint256[] memory _shareIDs = stakeCore.getUserStakeIndexes(address(this));
        if (_shareIDs.length == shareIDs.length) {
            return;
        }

        for (uint256 i = shareIDs.length; i < _shareIDs.length; i++) {
            uint256 shareID = _shareIDs[i];
            IStakeCore.StakeInfo memory stakeInfo = stakeCore.getStakeRecords(shareID);

            sharesInfo[shareID] = ShareInfo({
                isSet: true,
                totalReward: stakeInfo.claimedRewards + stakeInfo.lockedRewards,
                claimedReward: 0,
                grantedReward: 0,
                principal: stakeInfo.amount,
                grantedPrincipal: 0,
                claimedPrincipal: 0
            });

            shareIDs.push(shareID);
        }
    }

    function ClaimStakeRewardsBatch() external {
        uint256 length = shareIDs.length;
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 _shareID = shareIDs[i];
            uint256 amount = stakeCore.claimRewards(_shareID);
            sharesInfo[_shareID].claimedReward += amount;
            amounts[i] = amount;
        }

        emit StakeRewardsClaimedBatch(amounts);
    }

    function ClaimStakeRewards(uint256 _shareID) external {
        require(sharesInfo[_shareID].isSet, "the shareID has not registered yet");
        uint256 amount = stakeCore.claimRewards(_shareID);
        sharesInfo[_shareID].claimedReward += amount;
        emit StakeRewardsClaimed(_shareID, amount);
    }

    function ClaimStakePrincipal(uint256 _shareID) external {
        require(sharesInfo[_shareID].isSet, "the shareID has not registered yet");
        uint256 amount = stakeCore.unstake(_shareID);
        sharesInfo[_shareID].claimedPrincipal += amount;
        emit StakePrincipalClaimed(_shareID, amount);
    }

    function claimRewards() external {
        ShareholderInfo storage info = shareholdersInfo[msg.sender];
        require(info.owner == msg.sender, "Not a shareholder");
        //require(info.grantedReward > info.claimedReward, "No rewards");
        uint256 claimableTotalReward = calculateShareholderRewards(info.grantedReward, info.shareID);
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
        uint256 claimableTotalPrincipal = calculateShareholderPrincipal(info.grantedPrincipal, info.shareID);
        require(claimableTotalPrincipal > info.claimedPrincipal, "No Principal");
        uint256 claimablePrincipal = claimableTotalPrincipal - info.claimedPrincipal;

        info.claimedPrincipal = claimableTotalPrincipal;
        token.safeTransfer(msg.sender, claimablePrincipal);
        emit PrincipalClaimed(msg.sender, claimablePrincipal);
    }

    function calculateShareholderRewards(uint256 _shareholderGrantedReward, uint256 shareID) internal view returns (uint256){
        return _shareholderGrantedReward * sharesInfo[shareID].claimedReward / sharesInfo[shareID].totalReward;
    }

    function calculateShareholderPrincipal(uint256 _shareholderGrantedPrincipal, uint256 shareID) internal view returns (uint256){
        return _shareholderGrantedPrincipal * sharesInfo[shareID].claimedPrincipal / sharesInfo[shareID].principal;
    }

    function collect() external onlyAdmin returns (uint256) {
        //  withdraw extra token from this contract
        uint256 balance = token.balanceOf(address(this));
        uint256 totalReward;
        uint256 length = shareIDs.length;
        for (uint256 i = 0; i < length; i++) {
            totalReward += (sharesInfo[shareIDs[i]].claimedReward + sharesInfo[shareIDs[i]].claimedPrincipal);
        }
        require(balance >= totalReward, "Not enough token");
        token.safeTransfer(admin, balance - totalReward);
        emit RewardsCollected(balance - totalReward);
        return balance - totalReward;
    }

    function getShareholderInfo(address _shareholder) external view returns (ShareholderInfo memory) {
        return shareholdersInfo[_shareholder];
    }
}
