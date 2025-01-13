// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {StakeCore} from "../../src/contracts/StakeCore.sol";
import {BeneficiaryCore} from "../../src/contracts/BeneficiaryCore.sol";
import "forge-std/console.sol";

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        vm.startBroadcast(deployerPrivateKey);

        uint256 lockDays = 180;
        uint256 stakerShare = 60;
        uint256 installmentCount = 1;

        StakeCore core = new StakeCore(IERC20(tokenAddress), lockDays, stakerShare, installmentCount);
        BeneficiaryCore bfc = new BeneficiaryCore(IERC20(tokenAddress), msg.sender, address(core));

        console.log("Stake Core deployed to:", address(core));
        console.log("BeneficiaryCore deployed to:", address(bfc));

        vm.stopBroadcast();
    }
}
