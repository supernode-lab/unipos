// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseError} from "../../src/contracts/interfaces/BaseError.sol";
import {IStakeCore} from "../../src/contracts/interfaces/IStakeCore.sol";
import {StakeCore} from "../../src/contracts/stakecore/stakecore.sol";
import {BaseTest} from "../base/base.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";

contract StakeCoreTest is BaseTest {
    address public provider0 = getAddressFromString("stakecore_provider0");
    address public staker0 = getAddressFromString("stakecore_staker0");
    uint256 public lockPeriod = 86400 * 360;
    uint256 public cliffPeriod = 0;
    uint256 public apy = 100;
    uint256 public installmentNum = 360;
    uint256 public minStakeAmount = 1e18;

    StakeCore public stakecore;

    function setUp() public virtual override {
        super.setUp();
        address[] memory providers = new address[](1);
        providers[0] = provider0;
        stakecore = new StakeCore(admin, providers, token, lockPeriod, cliffPeriod, apy, installmentNum, minStakeAmount);
        token.mint(provider0, 1000 ether);
        token.mint(staker0, 1000 ether);
    }


    function test_depositSecurity() public {
        init_depositSecurity(provider0, 100 ether);
    }


    function test_stake() public {
        uint256 depositAmount = 100 ether;
        init_depositSecurity(provider0, depositAmount);
        uint256 stakeAmount=10 ether;
        vm.startPrank(staker0);
        token.approve(address(stakecore), stakeAmount);
        stakecore.stake(staker0, stakeAmount);
    }

    function test_stake_InsufficientDeposit() public {
        uint256 depositAmount = 100 ether;
        init_depositSecurity(provider0, depositAmount);
        uint256 stakeAmount;
        vm.startPrank(staker0);
        stakeAmount = stakecore.getCollateralBySecurityDeposit(depositAmount) + 1;
        token.approve(address(stakecore), stakeAmount);
        vm.expectPartialRevert(IStakeCore.InsufficientDeposit.selector);
        stakecore.stake(staker0, stakeAmount);
    }

    function test_stake_minStakeAmount() public {
        uint256 depositAmount = 100 ether;
        init_depositSecurity(provider0, depositAmount);
        uint256 stakeAmount;
        vm.startPrank(staker0);
        stakeAmount = minStakeAmount - 1;
        token.approve(address(stakecore), stakeAmount);
        vm.expectPartialRevert(BaseError.InvalidParameter.selector);
        stakecore.stake(staker0, stakeAmount);
    }


    function init_depositSecurity(address provider, uint256 depositAmount) internal {
        vm.startPrank(provider);
        uint256 befAmount = stakecore.totalSecurityDeposit();
        token.approve(address(stakecore), depositAmount);
        stakecore.depositSecurity(depositAmount);
        assertEq(stakecore.totalSecurityDeposit() - befAmount, depositAmount);
        vm.stopPrank();
    }
}