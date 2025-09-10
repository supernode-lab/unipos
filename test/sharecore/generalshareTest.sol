// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IGeneralShare} from "../../src/contracts/interfaces/IGeneralShare.sol";
import {IStakeCore} from "../../src/contracts/interfaces/IStakeCore.sol";
import {GeneralShare} from "../../src/contracts/sharecore/generalshare.sol";
import {StakeCore} from "../../src/contracts/stakecore/stakecore.sol";
import {StakeCoreTest} from "../stakecore/stakecoreTest.sol";


contract GeneralShareTest is StakeCoreTest {
    GeneralShare public generalshare;

    function setUp() public override {
        super.setUp();

        generalshare = new  GeneralShare(admin, address(stakecore), token, false,StakeCore.withdrawRewards.selector, StakeCore.withdrawPrincipal.selector);
        init();
    }

    function init() internal {
        initDepositSecurity(provider0, 100 ether);

        uint256 stakeAmount = 36 ether;
        vm.startPrank(staker0);
        token.approve(address(stakecore), stakeAmount);
        stakecore.stake(address(generalshare), stakeAmount);
        vm.stopPrank();
    }

    function initNewShare() public {
        uint256[] memory shareIds = stakecore.getUserStakeIndexes(address(generalshare));
        assert(shareIds.length > 0);
        uint256 shareId = shareIds[0];
        IStakeCore.StakeInfo memory stakeInfo = stakecore.getStakeRecords(shareId);

        vm.startPrank(admin);
        generalshare.newShare(
            abi.encode(shareId),
            abi.encode(shareId),
            stakeInfo.startTime,
            stakeInfo.startTime + stakeInfo.lockPeriod,
            stakeInfo.totalRewards,
            stakeInfo.totalPrincipal
        );
        vm.stopPrank();
    }

    function test_claimStakeRewards() public {
        initNewShare();
        uint256 shareId = 0;

        vm.expectPartialRevert(IStakeCore.NoRewards.selector);
        generalshare.claimStakeRewards(shareId);

        vm.warp(block.timestamp + lockPeriod / 2);
        generalshare.claimStakeRewards(shareId);
        IGeneralShare.ShareInfo memory shareInfo = generalshare.getShareInfo(shareId);
        assertEq(shareInfo.totalReward / 2, shareInfo.claimedReward);

        vm.warp(block.timestamp + lockPeriod / 2);
        generalshare.claimStakeRewards(shareId);
        shareInfo = generalshare.getShareInfo(shareId);
        assertEq(shareInfo.totalReward , shareInfo.claimedReward);
    }

    function test_claimStakePrincipal() public{
        initNewShare();
        uint256 shareId = 0;

        vm.expectPartialRevert(IStakeCore.NoPrincipal.selector);
        generalshare.claimStakePrincipal(shareId);

        vm.warp(block.timestamp + lockPeriod / 2);
        vm.expectPartialRevert(IStakeCore.NoPrincipal.selector);
        generalshare.claimStakePrincipal(shareId);

        vm.warp(block.timestamp + lockPeriod / 2);
        generalshare.claimStakePrincipal(shareId);
        IGeneralShare.ShareInfo memory  shareInfo = generalshare.getShareInfo(shareId);
        assertEq(shareInfo.totalPrincipal , shareInfo.claimedPrincipal);
    }
}