// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakeCore} from "src/contracts/StakeCore.sol";
import {BeneficiaryCore} from "src/contracts/BeneficiaryCore.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
    constructor() ERC20("Mock Token", "MT") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract SetUp is Test {
    StakeCore public core;
    BeneficiaryCore public beneficiary;
    Token public token;
    address public owner = address(this);
    address public admin = getAddressFromString("setup_Admin");
    address public provider = getAddressFromString("setup_Provider");
    address public holder1 = getAddressFromString("setup_Holder1");
    address public holder2 = getAddressFromString("setup_Holder2");
    address public staker1 = getAddressFromString("setup_Staker1");
    address public staker2 = getAddressFromString("setup_Staker2");
    address[] public holders = [holder1, holder2, admin];
    uint256[] public shares = [25,25, 50];

    uint256 public constant INITIAL_STAKE = 200 ether;
    uint256 constant PRICE_PRECISION = 1e18;

    function getAddressFromString(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
    }

    function setUp() public virtual {
        token = new Token();
        // Deploy contracts
        vm.startPrank(admin);
        core = new StakeCore(token, provider, 180 days, 60, 200, 5);
        beneficiary = new BeneficiaryCore(token, admin, address(core));
        core.initBeneficiary(address(beneficiary));
        token.mint(admin, 1000 ether);
        token.mint(staker1, 1000 ether);
        token.mint(staker2, 1000 ether);
        token.mint(provider, 1000 ether);
        vm.stopPrank();
    }

    function testRead() public {
        assertEq(core.admin(), admin);
        assertEq(core.apy(), (200 * PRICE_PRECISION) / 100);
    }

    function _testDeposit() public {
        vm.startPrank(provider);
        token.approve(address(core), INITIAL_STAKE);
        core.depositSecurity(INITIAL_STAKE);
        vm.stopPrank();
    }
    function _testStake() public {
        _testDeposit();
        vm.startPrank(staker1);
        uint256 stakeAmount = core.getCollateralBySecurityDeposit(INITIAL_STAKE / 2);
        console.log("required Collateral: ", core.requiredCollateral());
        console.log("totalSecurityDeposit: ", core.totalSecurityDeposit());
        console.log("stakeAmount: ", stakeAmount);
        token.approve(address(core), stakeAmount);
        core.stake(stakeAmount);
        vm.stopPrank();
        vm.startPrank(staker2);
        token.approve(address(core), stakeAmount);
        core.stake(stakeAmount);
        vm.stopPrank();
        StakeCore.StakeInfo memory info1 = core.getStakeInfo(0);
        assertEq(info1.owner, staker1);
        assertEq(info1.amount, stakeAmount);
        assertEq(info1.lockedRewards, 60 ether);
        // go to 90 days later
        vm.warp(block.timestamp + 100 days); // release 2/5
        uint256 rewards1 = core.getUnlockedInstallmentRewards(0);
        console.log("rewards1 100D: ", rewards1);
        assertEq(rewards1, 24 ether);
        vm.startPrank(staker1);
        vm.expectRevert(bytes("Lock period not ended"));
        core.unstake(0);
        core.claimRewards(0);
        assertEq(core.getStakeInfo(0).claimedRewards, 24 ether);
        assertEq(core.getStakeInfo(0).lockedRewards, 36 ether);
        vm.stopPrank();
        // go to 185 days later
        vm.warp(block.timestamp + 88 days); // release 5/5
        uint256 rewards1_2 = core.getUnlockedInstallmentRewards(0);
        console.log("rewards1 185D: ", rewards1_2);
        assertEq(rewards1_2, 60 ether);
        vm.prank(staker1);
        core.claimRewards(0);
        assertEq(core.getUnlockedInstallmentRewards(1), 60 ether, "unlocked rewards 60");
        vm.prank(staker2);
        core.claimRewards(1);
    }

    function _testBeneficiary() public {
        _testStake();
        vm.startPrank(admin);
        beneficiary.addShareholder(holder1, 10 ether);
        beneficiary.addShareholder(holder2, 30 ether);
        beneficiary.setShares(holders,shares);
        uint256 received = beneficiary.withdrawRewards();
        console.log("received", received / 1e18);
        assertEq(received, 80 ether, "receive 80");
        console.log("grantedAmount1:", beneficiary.getShareholderInfo(holder1).grantedAmount);
        console.log("grantedAmount2:", beneficiary.getShareholderInfo(holder2).grantedAmount);
        uint256 preBalance = token.balanceOf(holder1);
        vm.stopPrank();
        vm.prank(holder1);
        beneficiary.claimRewards();
        vm.assertEq(token.balanceOf(holder1) - preBalance, 10 ether);
    }

    function testAll() public {
        _testBeneficiary();
    }

}
