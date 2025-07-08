// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ShareCore} from "../src/contracts/ShareCore.sol";
import {StakeCore} from "../src/contracts/StakeCore.sol";
import {Subscription} from "../src/contracts/Subscription.sol";
import {Token, USDT} from "./BaseTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract Token is ERC20 {
    constructor() ERC20("Mock Token", "MT") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract USDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract BaseTest is Test {
    VmSafe.Wallet public adminWallet;
    address public admin;


    StakeCore public stakecore;
    ShareCore public sharecore;
    Subscription public subscription;

    Token public token;
    USDT public usdt;

    address public provider = getAddressFromString("setup_Provider");
    address public staker1 = getAddressFromString("setup_Staker1");
    address public staker2 = getAddressFromString("setup_Staker2");

    uint256 public constant INITIAL_STAKE = 200 ether;
    uint256 constant PRICE_PRECISION = 1e18;

    function getAddressFromString(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
    }

    function setUp() public virtual {
        adminWallet = vm.createWallet("systemAdmin");
        admin = adminWallet.addr;

        token = new Token();
        usdt = new USDT();
        // Deploy contracts
        vm.startPrank(admin);
        stakecore = new StakeCore(token, provider, 180 days, 60, 200, 5);
        sharecore = new ShareCore(admin, address(stakecore));
        subscription = new Subscription(admin, address(stakecore), address(usdt));

        token.mint(admin, 1000 ether);
        token.mint(staker1, 1000 ether);
        token.mint(staker2, 1000 ether);
        token.mint(provider, 1000 ether);

        usdt.mint(admin, 1000 ether);
        usdt.mint(staker1, 1000 ether);
        usdt.mint(staker2, 1000 ether);
        usdt.mint(provider, 1000 ether);
        vm.stopPrank();
    }

    function signByAdmin(bytes32 dataHash) public returns (bytes memory){
        bytes memory signature = new bytes(65);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminWallet, dataHash);

        assembly{
            mstore(add(signature, 32), r)
        }

        assembly{
            mstore(add(signature, 64), s)
        }

        signature[64] = bytes1(v);
        return signature;
    }

}
