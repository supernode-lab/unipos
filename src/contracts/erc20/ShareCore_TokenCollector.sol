// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "./interfaces/IStakeCore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract ShareCore_TokenCollector is ReentrancyGuard ,Ownable2Step{
    using SafeERC20 for IERC20;

    error NotAdmin(address caller);
    error NotHolder(address);
    error ShareNotRegistered(uint256 shareID);
    error HolderAlreadyExists();
    error StakeCoreAlreadySet();
    error ZeroAddress();
    error StartTimeOutOfRange(uint256 startTime, uint256 shareStart, uint256 shareEnd);
    error InsufficientUnallocatedPrincipal();
    error InsufficientUnallocatedRewards();
    error AmountExceedsWithdrawable(uint256 amount, uint256 withdrawable);
    error AmountExceedsBalance(uint256 amount, uint256 balance);
    error InsufficientRewards();
    error NoRewards();
    error NoPrincipal();

    struct ShareholderInfo {
        address owner;
        uint256 shareID;
        uint256 startTime;
        uint256 grantedReward;
        uint256 withdrawnReward;
        uint256 grantedPrincipal;
        uint256 withdrawnPrincipal;
    }

    struct ShareHolderKey {
        address owner;
        uint256 shareID;
    }

    struct ShareInfo {
        bool isSet;
        uint256 startTime;
        uint256 endTime;
        uint256 totalReward;
        uint256 claimedReward;
        uint256 withdrawnReward;
        uint256 grantedReward;
        uint256 gatheringReward;
        uint256 principal;
        uint256 claimedPrincipal;
        uint256 grantedPrincipal;
    }

    IStakeCore  public  stakeCore;
    IERC20 public  token;

    uint256[] public shareIDs;
    mapping(uint256 => ShareInfo) public sharesInfo;

    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) public shareholdersInfo;

    // Events
    event ShareholderAdded(address indexed shareholder, uint256 startTime, uint256 grantedReward, uint256 grantedPrincipal);
    event StakeRewardsClaimed(uint256 shareIDs, uint256 amount);
    event StakeRewardsClaimedBatch(uint256[] amount);

    event StakePrincipalClaimed(uint256 shareIDs, uint256 amount);
    event RewardsClaimed(address indexed shareholder, uint256 amount);
    event PrincipalClaimed(address indexed shareholder, uint256 amount);

    event RewardsCollected(uint256 amount);
    event RewardsDistributed(uint256 totalRewards);
    event Gathered();

    constructor(address owner, address _stakeCore)  Ownable(owner){
        if (_stakeCore != address(0)) {
            stakeCore = IStakeCore(_stakeCore);
            token = stakeCore.token();
        }
    }

    function registerStakeCore(address _stakeCore) external onlyOwner nonReentrant {
        if (address(stakeCore) != address(0)) revert StakeCoreAlreadySet();
        if (_stakeCore == address(0)) revert ZeroAddress();

        stakeCore = IStakeCore(_stakeCore);
        token = stakeCore.token();
    }

    function accrueRewards(uint256 _shareID, uint256 gatherT) external onlyOwner nonReentrant {
        ShareInfo memory shareInfo = sharesInfo[_shareID];
        if (!shareInfo.isSet) revert ShareNotRegistered(_shareID);
        if (gatherT <= shareInfo.startTime || gatherT > shareInfo.endTime || gatherT > block.timestamp) revert StartTimeOutOfRange(gatherT, shareInfo.startTime, shareInfo.endTime);

        uint256 ungrantedReward = shareInfo.totalReward - shareInfo.grantedReward;
        uint256 gatheringReward = ungrantedReward * (gatherT - shareInfo.startTime) / (shareInfo.endTime - shareInfo.startTime);

        ShareInfo storage shareInfo_storage = sharesInfo[_shareID];
        shareInfo_storage.grantedReward += gatheringReward;
        shareInfo_storage.gatheringReward += gatheringReward;
        shareInfo_storage.startTime = gatherT;
    }

    function gather(uint256 _shareID, uint256 amount) external onlyOwner nonReentrant {
        ShareInfo memory shareInfo = sharesInfo[_shareID];
        if (!shareInfo.isSet) revert ShareNotRegistered(_shareID);
        if (amount > shareInfo.gatheringReward) revert AmountExceedsWithdrawable(amount, shareInfo.gatheringReward);

        uint256 withdrawableReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (amount > withdrawableReward) revert AmountExceedsBalance(amount, withdrawableReward);
        sharesInfo[_shareID].withdrawnReward += amount;
        sharesInfo[_shareID].gatheringReward -= amount;
        token.safeTransfer(msg.sender, amount);
    }

    function addShareholder(address _owner, uint256 _shareID, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyOwner nonReentrant {
        _addShareholder(_owner, _shareID, sharesInfo[_shareID].startTime, _grantedReward, _grantedPrincipal);
    }

    function addShareholder2(address _owner, uint256 _shareID, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyOwner nonReentrant {
        _addShareholder(_owner, _shareID, _startTime, _grantedReward, _grantedPrincipal);
    }

    function _addShareholder(address _owner, uint256 _shareID, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) private {
        ShareInfo memory shareInfo = sharesInfo[_shareID];
        if (!shareInfo.isSet) revert ShareNotRegistered(_shareID);

        if (shareInfo.grantedPrincipal + _grantedPrincipal > shareInfo.principal) revert InsufficientUnallocatedPrincipal();
        if (_startTime < shareInfo.startTime || _startTime >= shareInfo.endTime || _startTime > block.timestamp) revert StartTimeOutOfRange(_startTime, shareInfo.startTime, shareInfo.endTime);

        uint256 gatheringReward = _grantedReward * (_startTime - shareInfo.startTime) / (shareInfo.endTime - _startTime);
        if (shareInfo.grantedReward + _grantedReward + gatheringReward > shareInfo.totalReward) revert InsufficientUnallocatedRewards();
        if (shareholdersInfo[_getShareHolderKeyHash(_owner, _shareID)].owner != address(0)) revert HolderAlreadyExists();
        shareholders.push(ShareHolderKey({
            owner: _owner,
            shareID: _shareID
        }));

        shareholdersInfo[_getShareHolderKeyHash(_owner, _shareID)] = ShareholderInfo({
            owner: _owner,
            shareID: _shareID,
            startTime: _startTime,
            grantedReward: _grantedReward,
            withdrawnReward: 0,
            grantedPrincipal: _grantedPrincipal,
            withdrawnPrincipal: 0
        });
        sharesInfo[_shareID].gatheringReward += gatheringReward;
        sharesInfo[_shareID].grantedReward += (_grantedReward + gatheringReward);
        sharesInfo[_shareID].grantedPrincipal += _grantedPrincipal;

        emit ShareholderAdded(_owner, _startTime, _grantedReward, _grantedPrincipal);
    }

    function register() external nonReentrant {
        uint256[] memory _shareIDs = stakeCore.getUserStakeIndexes(address(this));
        if (_shareIDs.length == shareIDs.length) {
            return;
        }

        for (uint256 i = shareIDs.length; i < _shareIDs.length; i++) {
            uint256 shareID = _shareIDs[i];
            IStakeCore.StakeInfo memory stakeInfo = stakeCore.getStakeRecords(shareID);

            sharesInfo[shareID] = ShareInfo({
                isSet: true,
                startTime: stakeInfo.startTime,
                endTime: stakeInfo.startTime + stakeInfo.lockPeriod,
                totalReward: stakeInfo.claimedRewards + stakeInfo.lockedRewards,
                claimedReward: 0,
                withdrawnReward: 0,
                grantedReward: 0,
                gatheringReward: 0,
                principal: stakeInfo.amount,
                grantedPrincipal: 0,
                claimedPrincipal: 0
            });

            shareIDs.push(shareID);
        }
    }

    function ClaimStakeRewardsBatch() external nonReentrant {
        uint256 length = shareIDs.length;
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 _shareID = shareIDs[i];
            try stakeCore.claimRewards(_shareID)returns (uint256 amount){
                sharesInfo[_shareID].claimedReward += amount;
                amounts[i] = amount;
            }catch{

            }
        }

        emit StakeRewardsClaimedBatch(amounts);
    }

    function ClaimStakeRewards(uint256 _shareID) external nonReentrant {
        if (!sharesInfo[_shareID].isSet) revert ShareNotRegistered(_shareID);
        uint256 amount = stakeCore.claimRewards(_shareID);
        sharesInfo[_shareID].claimedReward += amount;
        emit StakeRewardsClaimed(_shareID, amount);
    }

    function ClaimStakePrincipal(uint256 _shareID) external nonReentrant {
        if (!sharesInfo[_shareID].isSet) revert ShareNotRegistered(_shareID);
        uint256 amount = stakeCore.unstake(_shareID);
        sharesInfo[_shareID].claimedPrincipal += amount;
        emit StakePrincipalClaimed(_shareID, amount);
    }

    function claimRewards(uint256 _shareID) external nonReentrant {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, _shareID)];
        if (info.owner != msg.sender) revert NotHolder(msg.sender);
        ShareInfo storage shareInfo = sharesInfo[info.shareID];
        uint256 claimableTotalReward = calculateShareholderRewards(info, shareInfo.endTime);
        if (claimableTotalReward <= info.withdrawnReward) revert NoRewards();
        uint256 claimableReward = claimableTotalReward - info.withdrawnReward;
        uint256 withdrawableReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (withdrawableReward == 0) revert InsufficientRewards();
        if (withdrawableReward < claimableReward) {
            claimableReward = withdrawableReward;
        }

        info.withdrawnReward += claimableReward;
        shareInfo.withdrawnReward += claimableReward;
        token.safeTransfer(msg.sender, claimableReward);
        emit RewardsClaimed(msg.sender, claimableReward);
    }

    function claimPrincipal(uint256 _shareID) external nonReentrant {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, _shareID)];
        if (info.owner != msg.sender) revert NotHolder(msg.sender);
        uint256 claimableTotalPrincipal = calculateShareholderPrincipal(info.grantedPrincipal, info.shareID);
        if (claimableTotalPrincipal <= info.withdrawnPrincipal) revert NoPrincipal();
        uint256 claimablePrincipal = claimableTotalPrincipal - info.withdrawnPrincipal;
        info.withdrawnPrincipal = claimableTotalPrincipal;
        token.safeTransfer(msg.sender, claimablePrincipal);
        emit PrincipalClaimed(msg.sender, claimablePrincipal);
    }

    function calculateShareholderRewards(ShareholderInfo memory holderinfo, uint256 shareEndTime) internal view returns (uint256){
        uint256 endTime = block.timestamp < shareEndTime ? block.timestamp : shareEndTime;
        if (endTime <= holderinfo.startTime) {
            return 0;
        }

        uint256 elapsedTime = endTime - holderinfo.startTime;
        return holderinfo.grantedReward * elapsedTime / (shareEndTime - holderinfo.startTime);
    }

    function calculateShareholderPrincipal(uint256 _shareholderGrantedPrincipal, uint256 shareID) internal view returns (uint256){
        return _shareholderGrantedPrincipal * sharesInfo[shareID].claimedPrincipal / sharesInfo[shareID].principal;
    }

    function collect() external onlyOwner nonReentrant returns (uint256) {
        //  withdraw extra token from this contract
        uint256 balance = token.balanceOf(address(this));
        uint256 totalReward;
        uint256 shareIDsLength = shareIDs.length;
        for (uint256 i = 0; i < shareIDsLength; i++) {
            totalReward += (sharesInfo[shareIDs[i]].claimedReward + sharesInfo[shareIDs[i]].claimedPrincipal - sharesInfo[shareIDs[i]].withdrawnReward);
        }

        uint256 shareholdersLength = shareholders.length;
        for (uint256 i = 0; i < shareholdersLength; i++) {
            bytes32 key = _getShareHolderKeyHash(shareholders[i].owner, shareholders[i].shareID);
            totalReward -= (shareholdersInfo[key].withdrawnPrincipal);
        }

        require(balance >= totalReward, "Not enough token");
        token.safeTransfer(owner(), balance - totalReward);
        emit RewardsCollected(balance - totalReward);
        return balance - totalReward;
    }

    function getShareholderInfo(address _shareholder, uint256 shareID) public view returns (ShareholderInfo memory) {
        return shareholdersInfo[_getShareHolderKeyHash(_shareholder, shareID)];
    }

    function _getShareHolderKeyHash(address owner, uint256 shareID) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, shareID));
    }
}
