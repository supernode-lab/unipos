// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStakeCore} from "./StakeCore.sol";
import {IERC20} from "./IERC20.sol";
import {SafeERC20} from "./SafeERC20.sol";



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

    struct ShareHolderKey {
        address owner;
        uint256 shareID;
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

    IStakeCore  public  stakeCore;
    IERC20 public  token;
    address public admin;

    uint256[] public shareIDs;
    mapping(uint256 => ShareInfo) public sharesInfo;

    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) public shareholdersInfo;

    // Events
    event ShareholderAdded(address indexed shareholder, uint256 grantedReward, uint256 grantedPrincipal);
    event StakeRewardsClaimed(uint256 shareIDs, uint256 amount);
    event StakeRewardsClaimedBatch(uint256[] amount);

    event StakePrincipalClaimed(uint256 shareIDs, uint256 amount);
    event RewardsClaimed(address indexed shareholder, uint256 amount);
    event PrincipalClaimed(address indexed shareholder, uint256 amount);

    event RewardsCollected(uint256 amount);
    event RewardsDistributed(uint256 totalRewards);

    constructor(address _admin, address _stakeCore) {
        require(_admin != address(0), "Admin address can't be zero");
        //require(_stakeCore != address(0), "StakeCore address can't be zero");

        admin = _admin;
        if (_stakeCore != address(0)) {
            stakeCore = IStakeCore(_stakeCore);
            token = stakeCore.token();
        }
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function registerStakeCore(address _stakeCore) external onlyAdmin{
        require(address(stakeCore) == address(0), "StakeCore address must be zero");
        require(_stakeCore != address(0), "StakeCore parameter can't be zero");

        stakeCore = IStakeCore(_stakeCore);
        token=stakeCore.token();
    }

    function addShareholder(address _owner, uint256 _shareID, uint256 _grantedReward, uint256 _grantedPrincipal) external onlyAdmin {
        ShareInfo storage shareInfo = sharesInfo[_shareID];
        require(shareInfo.isSet, "the shareID has not registered yet");
        require(shareInfo.grantedReward + _grantedReward <= shareInfo.totalReward, "Remaining reward is insufficient");
        require(shareInfo.grantedPrincipal + _grantedPrincipal <= shareInfo.principal, "Remaining principal is insufficient");


        require(shareholdersInfo[_getShareHolderKeyHash(_owner, _shareID)].owner == address(0), "Shareholder already exists");

        shareholders.push(ShareHolderKey({
            owner : _owner,
            shareID : _shareID
        }));

        shareholdersInfo[_getShareHolderKeyHash(_owner, _shareID)] = ShareholderInfo({
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
            try stakeCore.claimRewards(_shareID)returns (uint256 amount){
                sharesInfo[_shareID].claimedReward += amount;
                amounts[i] = amount;
            }catch{

            }
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

    function claimRewards(uint256 _shareID) external {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender,_shareID)];
        require(info.owner == msg.sender, "Not a shareholder");
        //require(info.grantedReward > info.claimedReward, "No rewards");
        uint256 claimableTotalReward = calculateShareholderRewards(info.grantedReward, info.shareID);
        require(claimableTotalReward > info.claimedReward, "No rewards");
        uint256 claimableReward = claimableTotalReward - info.claimedReward;

        info.claimedReward = claimableTotalReward;
        token.safeTransfer(msg.sender, claimableReward);
        emit RewardsClaimed(msg.sender, claimableReward);
    }

    function claimPrincipal(uint256 _shareID) external {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender,_shareID)];
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
        uint256 shareIDsLength = shareIDs.length;
        for (uint256 i = 0; i < shareIDsLength; i++) {
            totalReward += (sharesInfo[shareIDs[i]].claimedReward + sharesInfo[shareIDs[i]].claimedPrincipal);
        }

        uint256 shareholdersLength = shareholders.length;
        for (uint256 i = 0; i < shareholdersLength; i++) {
            bytes32 key=_getShareHolderKeyHash(shareholders[i].owner,shareholders[i].shareID);
            totalReward -= (shareholdersInfo[key].claimedReward + shareholdersInfo[key].claimedPrincipal);
        }


        require(balance >= totalReward, "Not enough token");
        token.safeTransfer(admin, balance - totalReward);
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
