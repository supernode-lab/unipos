// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignedCredential} from "../Types/Structs/Credentials.sol";
import {BaseCredential} from "../base/baseCredential.sol";
import {IStakeCore} from "./StakeCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract Subscription is BaseCredential {
    using SafeERC20 for IERC20;

    struct ShareholderInfo {
        address owner;
        uint256 shareID;
        uint256 grantedReward;
        uint256 claimedReward;
        uint256 grantedPrincipal;
        uint256 claimedPrincipal;
        uint256 depositedToken;
        uint256 depositedUSDT;
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

    uint256 private constant PRECISION = 1e18;
    IStakeCore  public immutable stakeCore;
    IERC20 public immutable token;
    IERC20 public immutable usdt;

    uint256[] public shareIDs;
    mapping(uint256 => ShareInfo) public sharesInfo;

    ShareHolderKey[] public shareholders;
    mapping(bytes32 => ShareholderInfo) public shareholdersInfo;

    uint256 public depositedUsdt;
    uint256 public withdrawnUsdt;

    uint256 public depositedToken;
    uint256 public withdrawnToken;

    // Events
    event SubscribedByUSDT(address  shareholder, uint256 shareID, uint256 grantedReward, uint256 grantedPrincipal, uint256 amount);
    event SubscribedByToken(address  shareholder, uint256 shareID, uint256 grantedReward, uint256 grantedPrincipal, uint256 amount);
    event StakeRewardsClaimed(uint256 shareID, uint256 amount);
    event StakeRewardsClaimedBatch(uint256[] amounts);

    event USDTWithdrawn(address  account, uint256 amount);
    event TokenWithdrawn(address  account, uint256 amount);

    event StakePrincipalClaimed(uint256 shareID, uint256 amount);
    event RewardsClaimed(address  shareholder, uint256 shareID, uint256 amount);
    event PrincipalClaimed(address  shareholder, uint256 shareID, uint256 amount);

    event Registered(uint256[]shareIDs, uint256[]totalRewards, uint256[]principals);
    event RewardsCollected(uint256 amount);

    constructor(address _admin, address _stakeCore, address usdtContAddr) BaseCredential(_admin){
        stakeCore = IStakeCore(_stakeCore);
        token = stakeCore.token();
        usdt = IERC20(usdtContAddr);
    }

    function withdrawUSDT(uint256 amount) external onlyAdmin {
        require(amount + withdrawnUsdt <= depositedUsdt, "Remaining USDT is insufficient");
        withdrawnUsdt += amount;
        usdt.safeTransfer(msg.sender, amount);
        emit USDTWithdrawn(msg.sender, amount);
    }

    function withdrawToken(uint256 amount) external onlyAdmin {
        require(amount + withdrawnToken <= depositedToken, "Remaining Token is insufficient");
        withdrawnToken += amount;
        token.safeTransfer(msg.sender, amount);
        emit TokenWithdrawn(msg.sender, amount);
    }


    modifier onlyAdmin() {
        requireAdmin(msg.sender);
        _;
    }


    function subscribeByUSDT(
        address _owner,
        uint256 _shareID,
        uint256 amount,
        uint256 _grantedReward,
        uint256 _grantedPrincipal,
        SignedCredential calldata sc
    )
    validateAndBurnCred(sc, abi.encode(_owner, _shareID, amount, _grantedReward, _grantedPrincipal)) external {
        require(sharesInfo[_shareID].isSet, "the shareID has not registered yet");

        depositedUsdt += amount;
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        _addShareholder(_owner, _shareID, _grantedReward, _grantedPrincipal, 0, amount);
        emit SubscribedByUSDT(_owner, _shareID, _grantedReward, _grantedPrincipal, amount);
    }

    function subscribeByToken(
        address _owner,
        uint256 _shareID,
        uint256 amount,
        uint256 _grantedReward,
        uint256 _grantedPrincipal,
        SignedCredential calldata sc
    )
    validateAndBurnCred(sc, abi.encode(_owner, _shareID, amount, _grantedReward, _grantedPrincipal)) external {
        require(sharesInfo[_shareID].isSet, "the shareID has not registered yet");

        depositedToken += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        _addShareholder(_owner, _shareID, _grantedReward, _grantedPrincipal, amount, 0);
        emit SubscribedByToken(_owner, _shareID, _grantedReward, _grantedPrincipal, amount);
    }


    function _addShareholder(
        address _owner,
        uint256 _shareID,
        uint256 _grantedReward,
        uint256 _grantedPrincipal,
        uint256 _depositedToken,
        uint256 _depositedUSDT) internal {
        ShareInfo storage shareInfo = sharesInfo[_shareID];
        require(shareInfo.grantedReward + _grantedReward <= shareInfo.totalReward, "Remaining reward is insufficient");
        require(shareInfo.grantedPrincipal + _grantedPrincipal <= shareInfo.principal, "Remaining principal is insufficient");

        bytes32 holderkey = _getShareHolderKeyHash(_owner, _shareID);
        ShareholderInfo storage shareholder = shareholdersInfo[holderkey];
        if (shareholder.owner == address(0)) {
            shareholders.push(ShareHolderKey({
                owner: _owner,
                shareID: _shareID
            }));

            shareholdersInfo[holderkey] = ShareholderInfo({
                owner: _owner,
                shareID: _shareID,
                grantedReward: _grantedReward,
                claimedReward: 0,
                grantedPrincipal: _grantedPrincipal,
                claimedPrincipal: 0,
                depositedToken: _depositedToken,
                depositedUSDT: _depositedUSDT
            });
        } else {
            shareholder.grantedReward += _grantedReward;
            shareholder.grantedPrincipal += _grantedPrincipal;
            shareholder.depositedToken += _depositedToken;
            shareholder.depositedUSDT += _depositedUSDT;
        }


        shareInfo.grantedReward += _grantedReward;
        shareInfo.grantedPrincipal += _grantedPrincipal;
    }

    function register() external {
        uint256[] memory _shareIDs = stakeCore.getUserStakeIndexes(address(this));
        uint256 curShareLen = shareIDs.length;
        uint256 newShareLen = _shareIDs.length - curShareLen;
        if (newShareLen == 0) {
            return;
        }

        uint256[] memory newShareIDs = new uint256[](newShareLen);
        uint256[] memory totalRewards = new uint256[](newShareLen);
        uint256[] memory principals = new uint256[](newShareLen);
        for (uint256 i = curShareLen; i < _shareIDs.length; i++) {
            uint256 shareID = _shareIDs[i];
            IStakeCore.StakeInfo memory stakeInfo = stakeCore.getStakeRecords(shareID);

            newShareIDs[i - curShareLen] = shareID;
            totalRewards[i - curShareLen] = stakeInfo.claimedRewards + stakeInfo.lockedRewards;
            principals[i - curShareLen] = stakeInfo.amount;

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

        emit Registered(newShareIDs,totalRewards,principals);
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
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, _shareID)];
        require(info.owner == msg.sender, "Not a shareholder");
//require(info.grantedReward > info.claimedReward, "No rewards");
        uint256 claimableTotalReward = calculateShareholderRewards(info.grantedReward, info.shareID);
        require(claimableTotalReward > info.claimedReward, "No rewards");
        uint256 claimableReward = claimableTotalReward - info.claimedReward;

        info.claimedReward = claimableTotalReward;
        token.safeTransfer(msg.sender, claimableReward);
        emit RewardsClaimed(msg.sender, _shareID, claimableReward);
    }

    function claimPrincipal(uint256 _shareID) external {
        ShareholderInfo storage info = shareholdersInfo[_getShareHolderKeyHash(msg.sender, _shareID)];
        require(info.owner == msg.sender, "Not a shareholder");
//require(info.grantedReward > info.claimedReward, "No rewards");
        uint256 claimableTotalPrincipal = calculateShareholderPrincipal(info.grantedPrincipal, info.shareID);
        require(claimableTotalPrincipal > info.claimedPrincipal, "No Principal");
        uint256 claimablePrincipal = claimableTotalPrincipal - info.claimedPrincipal;

        info.claimedPrincipal = claimableTotalPrincipal;
        token.safeTransfer(msg.sender, claimablePrincipal);
        emit PrincipalClaimed(msg.sender, _shareID, claimablePrincipal);
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
            bytes32 key = _getShareHolderKeyHash(shareholders[i].owner, shareholders[i].shareID);
            totalReward -= (shareholdersInfo[key].claimedReward + shareholdersInfo[key].claimedPrincipal);
        }
        totalReward += (depositedToken - withdrawnToken);

        require(balance >= totalReward, "Not enough token");
        token.safeTransfer(msg.sender, balance - totalReward);
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
