// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IStakeCore,StakeCore} from "../src/contracts/StakeCore.sol";
import {BaseTest} from "./BaseTest.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";


contract StakeCoreTest is BaseTest {
    function setUp() public override {
        super.setUp();
        vm.startPrank(provider);
        token.approve(address(stakecore), INITIAL_STAKE);
        stakecore.depositSecurity(INITIAL_STAKE);
        vm.stopPrank();
    }


    function test_Stake() public {
        vm.startPrank(staker1);
        uint256 stakeAmount = stakecore.getCollateralBySecurityDeposit(INITIAL_STAKE / 2);
        console.log("required Collateral: ", stakecore.requiredCollateral());
        console.log("totalSecurityDeposit: ", stakecore.totalSecurityDeposit());
        console.log("stakeAmount: ", stakeAmount);
        token.approve(address(stakecore), stakeAmount);
        stakecore.stake(staker1, stakeAmount);
        vm.stopPrank();
        vm.startPrank(staker2);
        token.approve(address(stakecore), stakeAmount);
        stakecore.stake(staker2, stakeAmount);
        vm.stopPrank();
        StakeCore.StakeInfo memory info1 = stakecore.getStakeInfo(0);
        assertEq(info1.owner, staker1);
        assertEq(info1.amount, stakeAmount);
        assertEq(info1.lockedRewards, 60 ether);
        // go to 90 days later
        vm.warp(block.timestamp + 100 days); // release 2/5
        uint256 rewards1 = stakecore.getUnlockedInstallmentRewards(0);
        console.log("rewards1 100D: ", rewards1);
        assertEq(rewards1, 24 ether);
        vm.startPrank(staker1);
        vm.expectRevert(bytes("Lock period not ended"));
        stakecore.unstake(0);
        stakecore.claimRewards(0);
        assertEq(stakecore.getStakeInfo(0).claimedRewards, 24 ether);
        assertEq(stakecore.getStakeInfo(0).lockedRewards, 36 ether);
        vm.stopPrank();
        // go to 185 days later
        vm.warp(block.timestamp + 88 days); // release 5/5
        uint256 rewards1_2 = stakecore.getUnlockedInstallmentRewards(0);
        console.log("rewards1 185D: ", rewards1_2);
        assertEq(rewards1_2, 60 ether);
        vm.prank(staker1);
        stakecore.claimRewards(0);
        assertEq(stakecore.getUnlockedInstallmentRewards(1), 60 ether, "unlocked rewards 60");
        vm.prank(staker2);
        stakecore.claimRewards(1);
    }
}