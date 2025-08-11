// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ShareCore} from "../src/contracts/ShareCore.sol";
import {StakeCore, IStakeCore} from "../src/contracts/StakeCore.sol";
import {Token} from "./SetUp.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract Token is ERC20 {
    constructor() ERC20("Mock Token", "MT") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract SetUp is Test {
    StakeCore public core;
    ShareCore public share;
    Token public token;
    address public owner = address(this);
    address public admin = getAddressFromString("setup_Admin");
    address public provider = getAddressFromString("setup_Provider");
    address public holder1 = getAddressFromString("setup_Holder1");
    address public holder2 = getAddressFromString("setup_Holder2");
    address public staker1 = getAddressFromString("setup_Staker1");
    address public staker2 = getAddressFromString("setup_Staker2");
    address[] public holders = [holder1, holder2, admin];
    uint256[] public shares = [25, 25, 50];

    uint256 public constant INITIAL_STAKE = 200 ether;
    uint256 constant PRICE_PRECISION = 1e18;

    function getAddressFromString(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
    }

    function setUp() public virtual {
        token = new Token();
        // Deploy contracts
        vm.startPrank(admin);
        core = new StakeCore(180 days, 180);
        share = new ShareCore(token, admin, address(core));
        token.mint(admin, 1000 ether);
        token.mint(staker1, 1000 ether);
        token.mint(staker2, 1000 ether);
        token.mint(provider, 1000 ether);
        vm.stopPrank();

        vm.startPrank(staker1);
        uint256 stakeAmount = 180 ether;
        token.approve(address(core), stakeAmount);
        core.stake(address(share), stakeAmount);
        vm.stopPrank();
        vm.startPrank(staker2);
        token.approve(address(core), stakeAmount);
        core.stake(address(share), stakeAmount);
        vm.stopPrank();
    }


    function test_stake() public {
        StakeCore.StakeInfo memory info1 = core.getStakeInfo(0);
        assertEq(info1.owner, address(share));
        assertEq(info1.amount, 0);
        assertEq(info1.lockedRewards, 180 ether);
        // go to 90 days later
        vm.warp(block.timestamp + 100 days); // release 2/5
        uint256 rewards1 = core.getUnlockedInstallmentRewards(0);
        console.log("rewards1 100D: ", rewards1);
        assertEq(rewards1, 100 ether);
        vm.startPrank(address(share));
        vm.expectRevert(bytes("Lock period not ended"));
        core.unstake(0);
        core.claimRewards(0);
        assertEq(core.getStakeInfo(0).claimedRewards, 100 ether);
        assertEq(core.getStakeInfo(0).lockedRewards, 80 ether);
        vm.stopPrank();
        // go to 185 days later
        vm.warp(block.timestamp + 88 days); // release 5/5
        uint256 rewards1_2 = core.getUnlockedInstallmentRewards(0);
        console.log("rewards1 185D: ", rewards1_2);
        assertEq(rewards1_2, 180 ether);
        vm.prank(address(share));
        core.claimRewards(0);
        assertEq(core.getUnlockedInstallmentRewards(1), 180 ether, "unlocked rewards 180");
        vm.prank(staker2);
        vm.expectRevert(bytes("Not owner"));
        core.claimRewards(1);
    }


    function test_unstake() public {
        vm.startPrank(staker1);
        vm.expectRevert(bytes("Not owner"));
        core.unstake(0);
        vm.stopPrank();

        vm.startPrank(address(share));
        vm.expectRevert(bytes("Lock period not ended"));
        uint256 amount = core.unstake(0);
        assertEq(amount, 0);
        vm.warp(block.timestamp + 180 days);
        core.unstake(0);
        vm.expectRevert(bytes("Already claimed"));
        core.unstake(0);
        vm.stopPrank();
    }


    function test_claimRewards() public {
        vm.startPrank(staker1);
        vm.expectRevert(bytes("Not owner"));
        core.claimRewards(0);
        vm.stopPrank();

        vm.startPrank(address(share));
        vm.expectRevert(bytes("Can't claim"));
        core.claimRewards(0);

        vm.warp(block.timestamp + 1 days);
        uint256 amount = core.claimRewards(0);
        assertEq(amount, 1 ether);
        IStakeCore.StakeInfo memory stakeInfo = core.getStakeRecords(0);
        assertEq(stakeInfo.claimedRewards, 1 ether);
        assertEq(stakeInfo.lockedRewards, 179 ether);
        vm.expectRevert(bytes("Can't claim"));
        core.claimRewards(0);

        vm.warp(block.timestamp + 10 days);
        amount = core.claimRewards(0);
        assertEq(amount, 10 ether);
        stakeInfo = core.getStakeRecords(0);
        assertEq(stakeInfo.claimedRewards, 11 ether);
        assertEq(stakeInfo.lockedRewards, 169 ether);
        vm.expectRevert(bytes("Can't claim"));
        core.claimRewards(0);
        vm.stopPrank();
    }
}
