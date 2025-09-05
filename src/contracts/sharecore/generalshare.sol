// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniversalToken} from "../../base/UniversalToken.sol";
import {BaseShareCore} from "./basesharecore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract GeneralShare is BaseShareCore {
    // Events
    event ShareCreated(uint256 shareId, uint256 startT, uint256 endT, uint256 totalReward, uint256 totalPrincipal);

    struct ShareArgs {
        bytes claimRewardArgs;
        bytes claimPrincipalArgs;
    }

    bytes4 immutable public CLAIM_REWARDS_SELECTOR;
    bytes4 immutable public CLAIM_PRINCIPAL_SELECTOR;
    mapping(uint256 => ShareArgs) private shareArgs;


    constructor(address owner, address _stakecore, IERC20 token, bytes4 claimRewardsSelector, bytes4 claimPrincipalSelector) UniversalToken(token) Ownable(owner){
        stakecore = _stakecore;
        CLAIM_REWARDS_SELECTOR = claimRewardsSelector;
        CLAIM_PRINCIPAL_SELECTOR = claimPrincipalSelector;
    }

    function initStakeCore(address _stakecore) external override onlyOwner nonReentrant {
        if (address(stakecore) != address(0)) revert StakeCoreAlreadySet();
        if (_stakecore == address(0)) revert InvalidParameter("stakecore");

        stakecore = _stakecore;
    }

    function newShare(bytes calldata claimRewardArgs, bytes calldata claimPrincipalArgs, uint256 startT, uint256 endT, uint256 totalReward, uint256 totalPrincipal) external onlyOwner nonReentrant {
        if (startT >= endT) revert InvalidParameter("time");
        if (totalReward + totalPrincipal == 0) revert InvalidParameter("totals");

        uint256 shareId = shareIds.length;
        shareIds.push(shareId);
        shareInfos[shareId] = ShareInfo({
            isSet: true,
            startTime: startT,
            recycledTime: startT,
            endTime: endT,

            totalReward: totalReward,
            claimedReward: 0,
            withdrawnReward: 0,
            grantedReward: 0,

            totalRecycledReward: 0,
            withdrawnRecycledReward: 0,

            totalPrincipal: totalPrincipal,
            claimedPrincipal: 0,
            withdrawnPrincipal: 0,
            grantedPrincipal: 0
        });

        shareArgs[shareId] = ShareArgs({
            claimRewardArgs: claimRewardArgs,
            claimPrincipalArgs: claimPrincipalArgs
        });

        emit ShareCreated(shareId, startT, endT, totalReward, totalPrincipal);
    }

    function allocateFunds(uint256 shareId, uint256 allocatedReward, uint256 allocatedPrincipal) external onlyOwner nonReentrant {
        ShareInfo storage shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);
        uint256 freeFunds = balance() - heldFunds;
        if (allocatedReward + allocatedPrincipal > freeFunds) revert AmountExceedsBalance();
        if (allocatedReward + shareInfo.claimedReward > shareInfo.totalReward) revert InvalidParameter("allocatedReward");
        if (allocatedPrincipal + shareInfo.claimedPrincipal > shareInfo.totalPrincipal) revert InvalidParameter("allocatedPrincipal");
        shareInfo.claimedReward += allocatedReward;
        shareInfo.claimedPrincipal += allocatedPrincipal;
        heldFunds += (allocatedReward + allocatedPrincipal);
        emit FundsAllocated(shareId, allocatedReward, allocatedPrincipal);
    }

    function claimStakeRewards(uint256 shareId) external override nonReentrant {
        ShareInfo storage shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);

        uint256 _before = balance();
        _claimStakeRewards(shareArgs[shareId].claimRewardArgs);
        uint256 _after = balance();

        uint256 amount = _after - _before;
        uint256 maxAmount = shareInfo.totalReward - shareInfo.claimedReward;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        shareInfo.claimedReward += amount;
        heldFunds += amount;
        emit StakeRewardsClaimed(shareId, amount);
    }

    function claimStakePrincipal(uint256 shareId) external override nonReentrant {
        ShareInfo storage shareInfo = shareInfos[shareId];
        if (!shareInfo.isSet) revert InvalidShareId(shareId);

        uint256 _before = balance();
        _claimStakePrincipal(shareArgs[shareId].claimPrincipalArgs);
        uint256 _after = balance();

        uint256 amount = _after - _before;
        uint256 maxAmount = shareInfo.totalPrincipal - shareInfo.claimedPrincipal;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        shareInfo.claimedPrincipal += amount;
        heldFunds += amount;
        emit StakePrincipalClaimed(shareId, amount);
    }


    function _claimStakeRewards(bytes memory args) private {
        (bool ok, bytes memory retData) = stakecore.call(abi.encodePacked(CLAIM_REWARDS_SELECTOR, args));
        if (!ok) {
            if (retData.length > 0) {
                assembly ("memory-safe"){
                    revert(add(retData, 0x20), mload(retData))
                }
            } else {
                revert("DynamicCall: call failed");
            }
        }
    }

    function _claimStakePrincipal(bytes memory args) private {
        (bool ok, bytes memory retData) = stakecore.call(abi.encodePacked(CLAIM_PRINCIPAL_SELECTOR, args));
        if (!ok) {
            if (retData.length > 0) {
                assembly ("memory-safe"){
                    revert(add(retData, 0x20), mload(retData))
                }
            } else {
                revert("DynamicCall: call failed");
            }
        }
    }


    function getShareArgs(uint256 shareId) public view returns (ShareArgs memory){
        return shareArgs[shareId];
    }
}
