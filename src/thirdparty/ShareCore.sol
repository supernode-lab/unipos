// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIncentiveStaking} from "./IncentiveStaking.sol";
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
    }

    struct ShareInfo {
        uint256 nextIndex;
        uint256 totalReward;
        uint256 claimedReward;
        uint256 grantedReward;
    }

    uint256 private constant SYNC_BATCH = 8;

    IIncentiveStaking  public  incentiveStaking;
    IERC20 public  token;
    address public admin;
    ShareInfo public shareInfo;
    address[] public shareholders;
    mapping(address => ShareholderInfo) public shareholdersInfo;

    // Events
    event ShareholderAdded(address indexed shareholder, uint256 grantedReward);
    event StakeRewardsClaimedBatch(uint256 amount);

    event RewardsClaimed(address indexed shareholder, uint256 amount);

    event RewardsCollected(uint256 amount);

    constructor(address _admin, address _incentiveStaking) {
        require(_admin != address(0), "Admin address can't be zero");
        require(_incentiveStaking != address(0), "IncentiveStaking address can't be zero");

        admin = _admin;
        incentiveStaking = IIncentiveStaking(_incentiveStaking);
        IERC20 _token = incentiveStaking.praiToken();
        require(address(_token) != address(0), "token address is illegal");
        token = _token;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }


    function addShareholder(address _owner, uint256 _grantedReward) external onlyAdmin {
        require(shareInfo.grantedReward + _grantedReward <= shareInfo.totalReward, "Remaining reward is insufficient");
        require(shareholdersInfo[_owner].owner == address(0), "Shareholder already exists");

        shareholders.push(_owner);
        shareholdersInfo[_owner] = ShareholderInfo({
            owner: _owner,
            grantedReward: _grantedReward,
            claimedReward: 0
        });
        shareInfo.grantedReward += _grantedReward;
        emit ShareholderAdded(_owner, _grantedReward);
    }

    function register() external {
        uint256 syncedReward = 0;
        uint256 start = shareInfo.nextIndex;
        uint256 end = start + SYNC_BATCH;

        uint256 i = start;
        for (; i < end; i++) {
            try  incentiveStaking.withdrawalStakes(address(this), i) returns (IIncentiveStaking.StakeInfo memory stakeInfo){
                syncedReward += (stakeInfo.amount + stakeInfo.totalInterest);
            }catch{
                break;
            }
        }

        if (i == start) {
            return;
        }

        shareInfo.nextIndex = i;
        shareInfo.totalReward += syncedReward;
        return;
    }

    function ClaimStakeRewardsBatch() external {
        uint256 totalWithdrawal = incentiveStaking.withdraw();
        shareInfo.claimedReward += totalWithdrawal;

        emit StakeRewardsClaimedBatch(totalWithdrawal);
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


    function calculateShareholderRewards(uint256 _shareholderGrantedReward) internal view returns (uint256){
        if (shareInfo.claimedReward >= shareInfo.totalReward) {
            return _shareholderGrantedReward;
        } else {
            return _shareholderGrantedReward * shareInfo.claimedReward / shareInfo.totalReward;
        }
    }


    function collect() external onlyAdmin returns (uint256) {
        //  withdraw extra token from this contract
        uint256 balance = token.balanceOf(address(this));
        uint256 totalReward = shareInfo.claimedReward;


        uint256 shareholdersLength = shareholders.length;
        for (uint256 i = 0; i < shareholdersLength; i++) {
            totalReward -= (shareholdersInfo[shareholders[i]].claimedReward);
        }


        require(balance >= totalReward, "Not enough token");
        uint256 residue = balance - totalReward;
        token.safeTransfer(admin, residue);
        emit RewardsCollected(residue);
        return residue;
    }


}
