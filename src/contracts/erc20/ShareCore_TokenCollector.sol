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
contract ShareCore_TokenCollector is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    error NotAdmin(address caller);
    error NotHolder(address);
    error ShareNotRegistered(uint256 shareId);
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
        uint256 shareId;
        uint256 startTime;
        uint256 grantedReward;
        uint256 withdrawnReward;
        uint256 grantedPrincipal;
        uint256 withdrawnPrincipal;
    }

    struct ShareHolderKey {
        address owner;
        uint256 shareId;
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

    uint256[] public shareIds;
    mapping(uint256 => ShareInfo) public sharesInfo;

    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) public shareholdersInfo;

    // Events
    event RewardsAccrued(uint256 shareId, uint256 gatherT, uint256 gatheringReward);
    event Registered(uint256[] shareIds);
    event ShareholderAdded(address  shareholder, uint256 shareId, uint256 startTime, uint256 grantedReward, uint256 grantedPrincipal);
    event StakeRewardsClaimed(uint256 shareId, uint256 amount);
    event StakeRewardsClaimedBatch(uint256[] amount);

    event StakePrincipalClaimed(uint256 shareId, uint256 amount);
    event RewardsClaimed(address  shareholder, uint256 shareId, uint256 amount);
    event PrincipalClaimed(address  shareholder,  uint256 shareId, uint256 amount);

    event RewardsCollected(uint256 amount);
    event RewardsDistributed(uint256 totalRewards);
    event Gathered(uint256 shareId, uint256 amount);


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

    function accrueRewards(uint256 _shareId, uint256 gatherT) external onlyOwner nonReentrant {
        ShareInfo memory shareInfo = sharesInfo[_shareId];
        if (!shareInfo.isSet) revert ShareNotRegistered(_shareId);
        if (gatherT <= shareInfo.startTime || gatherT > shareInfo.endTime || gatherT > block.timestamp) revert StartTimeOutOfRange(gatherT, shareInfo.startTime, shareInfo.endTime);

        uint256 ungrantedReward = shareInfo.totalReward - shareInfo.grantedReward;
        uint256 gatheringReward = ungrantedReward * (gatherT - shareInfo.startTime) / (shareInfo.endTime - shareInfo.startTime);

        ShareInfo storage shareInfo_storage = sharesInfo[_shareId];
        shareInfo_storage.grantedReward += gatheringReward;
        shareInfo_storage.gatheringReward += gatheringReward;
        shareInfo_storage.startTime = gatherT;
        emit RewardsAccrued(_shareId, gatherT, gatheringReward);
    }

    function gather(uint256 _shareId, uint256 amount) external onlyOwner nonReentrant {
        ShareInfo memory shareInfo = sharesInfo[_shareId];
        if (!shareInfo.isSet) revert ShareNotRegistered(_shareId);
        if (amount > shareInfo.gatheringReward) revert AmountExceedsWithdrawable(amount, shareInfo.gatheringReward);

        uint256 withdrawableReward = shareInfo.claimedReward - shareInfo.withdrawnReward;
        if (amount > withdrawableReward) revert AmountExceedsBalance(amount, withdrawableReward);
        sharesInfo[_shareId].withdrawnReward += amount;
        sharesInfo[_shareId].gatheringReward -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Gathered(_shareId, amount);
    }

    function addShareholder(address _owner, uint256 _shareId, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyOwner nonReentrant {
        _addShareholder(_owner, _shareId, sharesInfo[_shareId].startTime, _grantedReward, _grantedPrincipal);
    }

    function addShareholder2(address _owner, uint256 _shareId, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyOwner nonReentrant {
        _addShareholder(_owner, _shareId, _startTime, _grantedReward, _grantedPrincipal);
    }

    function _addShareholder(address _owner, uint256 _shareId, uint256 _startTime, uint256 _grantedReward, uint256 _grantedPrincipal) private {
        ShareInfo memory shareInfo = sharesInfo[_shareId];
        if (!shareInfo.isSet) revert ShareNotRegistered(_shareId);

        if (shareInfo.grantedPrincipal + _grantedPrincipal > shareInfo.principal) revert InsufficientUnallocatedPrincipal();
        if (_startTime < shareInfo.startTime || _startTime >= shareInfo.endTime || _startTime > block.timestamp) revert StartTimeOutOfRange(_startTime, shareInfo.startTime, shareInfo.endTime);

        uint256 gatheringReward = _grantedReward * (_startTime - shareInfo.startTime) / (shareInfo.endTime - _startTime);
        if (shareInfo.grantedReward + _grantedReward + gatheringReward > shareInfo.totalReward) revert InsufficientUnallocatedRewards();
        if (shareholdersInfo[_getShareHolderKeyHash(_owner, _shareId)].owner != address(0)) revert HolderAlreadyExists();
        shareholders.push(ShareHolderKey({
            owner: _owner,
            shareId: _shareId
        }));

        shareholdersInfo[_getShareHolderKeyHash(_owner, _shareId)] = ShareholderInfo({
            owner: _owner,
            shareId: _shareId,
            startTime: _startTime,
            grantedReward: _grantedReward,
            withdrawnReward: 0,
            grantedPrincipal: _grantedPrincipal,
            withdrawnPrincipal: 0
        });
        sharesInfo[_shareId].gatheringReward += gatheringReward;
        sharesInfo[_shareId].grantedReward += (_grantedReward + gatheringReward);
        sharesInfo[_shareId].grantedPrincipal += _grantedPrincipal;

        emit ShareholderAdded(_owner, _shareId, _startTime, _grantedReward, _grantedPrincipal);
    }

    function register() external nonReentrant {
        uint256[] memory _shareIds = stakeCore.getUserStakeIndexes(address(this));
        uint256 curShareIdsLen = shareIds.length;
        if (_shareIds.length == curShareIdsLen) {
            return;
        }

        uint256[] memory newShareIds = new uint256[](_shareIds.length - curShareIdsLen);
        for (uint256 i = curShareIdsLen; i < _shareIds.length; i++) {
            uint256 shareId = _shareIds[i];
            IStakeCore.StakeInfo memory stakeInfo = stakeCore.getStakeRecords(shareId);

            sharesInfo[shareId] = ShareInfo({
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

            shareIds.push(shareId);
            newShareIds[i - curShareIdsLen] = shareId;
        }

        emit Registered(newShareIds);
    }

    function claimStakeRewardsBatch() external nonReentrant {
        uint256 length = shareIds.length;
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 _shareId = shareIds[i];
            try stakeCore.claimRewards(_shareId)returns (uint256 amount){
                sharesInfo[_shareId].claimedReward += amount;
                amounts[i] = amount;
            }catch{

            }
        }

        emit StakeRewardsClaimedBatch(amounts);
    }

    function claimStakeRewards(uint256 _shareId) external nonReentrant {
        if (!sharesInfo[_shareId].isSet) revert ShareNotRegistered(_shareId);
        uint256 amount = stakeCore.claimRewards(_shareId);
        sharesInfo[_shareId].claimedReward += amount;
        emit StakeRewardsClaimed(_shareId, amount);
    }

    function claimStakePrincipal(uint256 _shareId) external nonReentrant {
        if (!sharesInfo[_shareId].isSet) revert ShareNotRegistered(_shareId);
        uint256 amount = stakeCore.unstake(_shareId);
        sharesInfo[_shareId].claimedPrincipal += amount;
        emit StakePrincipalClaimed(_shareId, amount);
    }

    function claimRewards(uint256 _shareId) external nonReentrant {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, _shareId)];
        if (info.owner != msg.sender) revert NotHolder(msg.sender);
        ShareInfo storage shareInfo = sharesInfo[info.shareId];
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
        emit RewardsClaimed(msg.sender, _shareId, claimableReward);
    }

    function claimPrincipal(uint256 _shareId) external nonReentrant {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, _shareId)];
        if (info.owner != msg.sender) revert NotHolder(msg.sender);
        uint256 claimableTotalPrincipal = calculateShareholderPrincipal(info.grantedPrincipal, info.shareId);
        if (claimableTotalPrincipal <= info.withdrawnPrincipal) revert NoPrincipal();
        uint256 claimablePrincipal = claimableTotalPrincipal - info.withdrawnPrincipal;
        info.withdrawnPrincipal = claimableTotalPrincipal;
        token.safeTransfer(msg.sender, claimablePrincipal);
        emit PrincipalClaimed(msg.sender, _shareId, claimablePrincipal);
    }

    function calculateShareholderRewards(ShareholderInfo memory holderinfo, uint256 shareEndTime) internal view returns (uint256){
        uint256 endTime = block.timestamp < shareEndTime ? block.timestamp : shareEndTime;
        if (endTime <= holderinfo.startTime) {
            return 0;
        }

        uint256 elapsedTime = endTime - holderinfo.startTime;
        return holderinfo.grantedReward * elapsedTime / (shareEndTime - holderinfo.startTime);
    }

    function calculateShareholderPrincipal(uint256 _shareholderGrantedPrincipal, uint256 shareId) internal view returns (uint256){
        return _shareholderGrantedPrincipal * sharesInfo[shareId].claimedPrincipal / sharesInfo[shareId].principal;
    }

    function collect() external onlyOwner nonReentrant returns (uint256) {
        //  withdraw extra token from this contract
        uint256 balance = token.balanceOf(address(this));
        uint256 totalReward;
        uint256 shareIdsLength = shareIds.length;
        for (uint256 i = 0; i < shareIdsLength; i++) {
            uint256 shareId=shareIds[i];
            totalReward += (sharesInfo[shareId].claimedReward + sharesInfo[shareId].claimedPrincipal - sharesInfo[shareId].withdrawnReward);
        }

        uint256 shareholdersLength = shareholders.length;
        for (uint256 i = 0; i < shareholdersLength; i++) {
            bytes32 key = _getShareHolderKeyHash(shareholders[i].owner, shareholders[i].shareId);
            totalReward -= (shareholdersInfo[key].withdrawnPrincipal);
        }

        require(balance >= totalReward, "Not enough token");
        token.safeTransfer(owner(), balance - totalReward);
        emit RewardsCollected(balance - totalReward);
        return balance - totalReward;
    }

    function getShareholderInfo(address _shareholder, uint256 shareId) public view returns (ShareholderInfo memory) {
        return shareholdersInfo[_getShareHolderKeyHash(_shareholder, shareId)];
    }

    function _getShareHolderKeyHash(address owner, uint256 shareId) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, shareId));
    }
}
