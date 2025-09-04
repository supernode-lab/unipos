// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Token, USDT} from "./base.sol";
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

abstract contract BaseTest is Test {
    VmSafe.Wallet public adminWallet;
    address public admin;
    Token public token;
    USDT public usdt;


    function setUp() public virtual {
        adminWallet = vm.createWallet("systemAdmin");
        admin = adminWallet.addr;
        token = new Token();
        usdt = new USDT();
        // Deploy contracts
        vm.startPrank(admin);
        token.mint(admin, 1000 ether);
        usdt.mint(admin, 1000 ether);
        vm.stopPrank();
    }

    function getAddressFromString(string memory s) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
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
