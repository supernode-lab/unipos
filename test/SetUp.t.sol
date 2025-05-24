// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakeCore} from "src/contracts/StakeCore.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
    constructor() ERC20("Mock Token", "MT") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract SetUp is Test {
    StakeCore public core;
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
        core = new StakeCore(token, provider, 180 days, 180);
        //beneficiary = new BeneficiaryCore(token, admin, address(core));
        //core.initBeneficiary(address(beneficiary));
        token.mint(admin, 1000 ether);
        token.mint(staker1, 1000 ether);
        token.mint(staker2, 1000 ether);
        token.mint(provider, 1000 ether);
        vm.stopPrank();
    }



}
