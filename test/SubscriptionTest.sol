// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {SignedCredential, VerifiableCredential} from "../src/Types/Structs/Credentials.sol";
import {Subscription} from "../src/contracts/Subscription.sol";
import {DataHasher} from "../src/libraries/Datahasher.sol";
import {BaseTest} from "./BaseTest.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";


contract SubscriptionTest is BaseTest {
    address public user0 = getAddressFromString("subscription_user0");

    function setUp() public override {
        super.setUp();
        vm.startPrank(provider);
        token.approve(address(stakecore), INITIAL_STAKE);
        stakecore.depositSecurity(INITIAL_STAKE);
        vm.stopPrank();

        vm.startPrank(staker1);
        token.approve(address(stakecore), INITIAL_STAKE);
        stakecore.stake(address(subscription), INITIAL_STAKE);
        vm.stopPrank();

        vm.startPrank(admin);
        usdt.mint(user0, 9999 ether);
        token.mint(user0, 9999 ether);
        vm.warp(block.timestamp + 90 days);
        subscription.register();
        subscription.ClaimStakeRewardsBatch();
        vm.stopPrank();
    }


    function test_sharesInfo() public {
        uint256 [] memory shareIDs = stakecore.getUserStakeIndexes(address(subscription));
        (
            bool isSet,
            uint256 totalReward,
            uint256 claimedReward,
            uint256 grantedReward,
            uint256 principal,
            uint256 claimedPrincipal,
            uint256 grantedPrincipal
        ) = subscription.sharesInfo(0);
        assertEq(totalReward, 120 ether);
        assertEq(claimedReward, 48 ether);
        assertEq(grantedReward, 0);
        assertEq(principal, 200 ether);
        assertEq(claimedPrincipal, 0);
        assertEq(grantedPrincipal, 0);
    }

    function test_subscribeByUSDT() public {
        address owner = user0;
        uint256 shareID = 0;
        uint256 usdtAmount0 = 100;
        uint256 grantedReward0 = 118 ether;
        uint256 grantedPrincipal0 = 198 ether;
        vm.startPrank(owner);

        usdt.approve(address(subscription), usdtAmount0);
        SignedCredential memory sc = createSC(owner, subscription.subscribeByUSDT.selector, abi.encode(owner, shareID, usdtAmount0, grantedReward0, grantedPrincipal0));
        subscription.subscribeByUSDT(owner, shareID, usdtAmount0, grantedReward0, grantedPrincipal0, sc);
        vm.stopPrank();

        uint256 balance = usdt.balanceOf(address(subscription));
        assertEq(balance, usdtAmount0);
        Subscription.ShareholderInfo memory shareholder0 = subscription.getShareholderInfo(owner, shareID);
        assertEq(shareholder0.owner, owner);
        assertEq(shareholder0.shareID, shareID);
        assertEq(shareholder0.grantedReward, grantedReward0);
        assertEq(shareholder0.claimedReward, 0);
        assertEq(shareholder0.grantedPrincipal, grantedPrincipal0);
        assertEq(shareholder0.claimedPrincipal, 0);
        assertEq(shareholder0.depositedToken, 0);
        assertEq(shareholder0.depositedUSDT, usdtAmount0);

        uint256 usdtAmount1 = 1;
        uint256 grantedReward1 = 3 ether;
        uint256 grantedPrincipal1 = 2 ether;
        vm.startPrank(owner);
        usdt.approve(address(subscription), usdtAmount1);
        sc = createSC(owner, subscription.subscribeByUSDT.selector, abi.encode(owner, shareID, usdtAmount1, grantedReward1, grantedPrincipal1));
        vm.expectRevert(bytes("Remaining reward is insufficient"));
        subscription.subscribeByUSDT(owner, shareID, usdtAmount1, grantedReward1, grantedPrincipal1, sc);

        grantedReward1 = 2 ether;
        grantedPrincipal1 = 3 ether;
        sc = createSC(owner, subscription.subscribeByUSDT.selector, abi.encode(owner, shareID, usdtAmount1, grantedReward1, grantedPrincipal1));
        vm.expectRevert(bytes("Remaining principal is insufficient"));
        subscription.subscribeByUSDT(owner, shareID, usdtAmount1, grantedReward1, grantedPrincipal1, sc);

        grantedPrincipal1 = 2 ether;
        sc = createSC(owner, subscription.subscribeByUSDT.selector, abi.encode(owner, shareID, usdtAmount1, grantedReward1, grantedPrincipal1));
        subscription.subscribeByUSDT(owner, shareID, usdtAmount1, grantedReward1, grantedPrincipal1, sc);
        vm.stopPrank();

        balance = usdt.balanceOf(address(subscription));
        assertEq(balance, usdtAmount0 + usdtAmount1);
        Subscription.ShareholderInfo memory shareholder1 = subscription.getShareholderInfo(owner, shareID);
        assertEq(shareholder1.owner, owner);
        assertEq(shareholder1.shareID, shareID);
        assertEq(shareholder1.grantedReward, grantedReward0 + grantedReward1);
        assertEq(shareholder1.claimedReward, 0);
        assertEq(shareholder1.grantedPrincipal, grantedPrincipal0 + grantedPrincipal1);
        assertEq(shareholder1.claimedPrincipal, 0);
        assertEq(shareholder1.depositedToken, 0);
        assertEq(shareholder1.depositedUSDT, usdtAmount0 + usdtAmount1);
    }

    function test_subscribeByToken() public {
        (
            bool isSet,
            uint256 totalReward,
            uint256 claimedReward,
            uint256 grantedReward,
            uint256 principal,
            uint256 claimedPrincipal,
            uint256 grantedPrincipal
        ) = subscription.sharesInfo(0);


        address owner = user0;
        uint256 shareID = 0;
        uint256 tokenAmount0 = 100;
        uint256 grantedReward0 = 118 ether;
        uint256 grantedPrincipal0 = 198 ether;
        vm.startPrank(owner);

        token.approve(address(subscription), tokenAmount0);
        SignedCredential memory sc = createSC(owner, subscription.subscribeByToken.selector, abi.encode(owner, shareID, tokenAmount0, grantedReward0, grantedPrincipal0));
        subscription.subscribeByToken(owner, shareID, tokenAmount0, grantedReward0, grantedPrincipal0, sc);
        vm.stopPrank();

        uint256 balance = token.balanceOf(address(subscription));
        assertEq(balance, tokenAmount0 + claimedReward + claimedPrincipal);
        Subscription.ShareholderInfo memory shareholder0 = subscription.getShareholderInfo(owner, shareID);
        assertEq(shareholder0.owner, owner);
        assertEq(shareholder0.shareID, shareID);
        assertEq(shareholder0.grantedReward, grantedReward0);
        assertEq(shareholder0.claimedReward, 0);
        assertEq(shareholder0.grantedPrincipal, grantedPrincipal0);
        assertEq(shareholder0.claimedPrincipal, 0);
        assertEq(shareholder0.depositedToken, tokenAmount0);
        assertEq(shareholder0.depositedUSDT, 0);

        uint256 tokenAmount1 = 1;
        uint256 grantedReward1 = 3 ether;
        uint256 grantedPrincipal1 = 2 ether;
        vm.startPrank(owner);
        token.approve(address(subscription), tokenAmount1);
        sc = createSC(owner, subscription.subscribeByToken.selector, abi.encode(owner, shareID, tokenAmount1, grantedReward1, grantedPrincipal1));
        vm.expectRevert(bytes("Remaining reward is insufficient"));
        subscription.subscribeByToken(owner, shareID, tokenAmount1, grantedReward1, grantedPrincipal1, sc);

        grantedReward1 = 2 ether;
        grantedPrincipal1 = 3 ether;
        sc = createSC(owner, subscription.subscribeByToken.selector, abi.encode(owner, shareID, tokenAmount1, grantedReward1, grantedPrincipal1));
        vm.expectRevert(bytes("Remaining principal is insufficient"));
        subscription.subscribeByToken(owner, shareID, tokenAmount1, grantedReward1, grantedPrincipal1, sc);

        grantedPrincipal1 = 2 ether;
        sc = createSC(owner, subscription.subscribeByToken.selector, abi.encode(owner, shareID, tokenAmount1, grantedReward1, grantedPrincipal1));
        subscription.subscribeByToken(owner, shareID, tokenAmount1, grantedReward1, grantedPrincipal1, sc);
        vm.stopPrank();

        balance = token.balanceOf(address(subscription));
        assertEq(balance, tokenAmount0 + tokenAmount1 + claimedReward + claimedPrincipal);

        Subscription.ShareholderInfo memory shareholder1 = subscription.getShareholderInfo(owner, shareID);
        assertEq(shareholder1.owner, owner);
        assertEq(shareholder1.shareID, shareID);
        assertEq(shareholder1.grantedReward, grantedReward0 + grantedReward1);
        assertEq(shareholder1.claimedReward, 0);
        assertEq(shareholder1.grantedPrincipal, grantedPrincipal0 + grantedPrincipal1);
        assertEq(shareholder1.claimedPrincipal, 0);
        assertEq(shareholder1.depositedToken, tokenAmount0 + tokenAmount1);
        assertEq(shareholder1.depositedUSDT, 0);
    }


    function createVC(address sender, bytes4 action) public view returns (VerifiableCredential memory){
        VerifiableCredential memory vc;
        vc.nonce = uint64(subscription.user2nonce(sender)) + 1;
        vc.epochIssued = uint64(block.number);
        vc.epochValidUntil = uint64(block.number);
        vc.action = action;
        return vc;
    }

    function createSC(address sender, bytes4 action, bytes memory params) public returns (SignedCredential memory){
        VerifiableCredential memory vc = createVC(sender, action);
        bytes32 datahash = DataHasher.gethashAt(sender, params, vc);

        bytes memory signature = signByAdmin(datahash);
        return SignedCredential({
            vc: vc,
            signature: signature
        });
    }
}