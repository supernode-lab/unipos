// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ShareCore} from "../../src/contracts/erc20/ShareCore.sol";
import {StakeCore} from "../../src/contracts/erc20/StakeCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {Script} from "forge-std/Script.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address providerAddress = vm.envAddress("PROVIDER_ADDRESS");
        address adminAddress = vm.envAddress("ADMIN_ADDRESS");
        uint256 apy = vm.envUint("APY");
        vm.startBroadcast(deployerPrivateKey);

        uint256 lockDays = 180;
        uint256 stakerShare = 60;
        uint256 installmentCount = 1;

        StakeCore stakecore = new StakeCore(IERC20(tokenAddress), providerAddress, lockDays, stakerShare, apy, installmentCount);
        ShareCore sharecore = new ShareCore( adminAddress, address(stakecore));


        console.log("Stake Core deployed to:", address(stakecore));
        console.log("Share Core deployed to:", address(sharecore));
        vm.stopBroadcast();
    }
}
