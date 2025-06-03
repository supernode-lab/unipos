// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ShareCore} from "../../src/contracts/ShareCore.sol";
import {StakeCore} from "../../src/contracts/StakeCore.sol";
import {CommonBase} from "forge-std/Base.sol";
import {Script} from "forge-std/Script.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {RewardPayout} from "../../src/contracts/RewardPayout.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakeAddress = vm.envAddress("STAKE_ADDRESS");
        address providerAddress = vm.envAddress("PROVIDER_ADDRESS");
        address beneficiaryAddress = vm.envAddress("BENEFICIARY_ADDRESS");
        address adminAddress = vm.envAddress("ADMIN_ADDRESS");
        address tokenAddress=vm.envAddress("TOKEN_ADDRESS");
        uint256 apy = vm.envUint("APY");
        vm.startBroadcast(deployerPrivateKey);

        ShareCore shareCore=new ShareCore(IERC20(tokenAddress),adminAddress,address(0));
        beneficiaryAddress=address(shareCore);
        RewardPayout rewardPayout = new RewardPayout(StakeCore(stakeAddress), apy,providerAddress, beneficiaryAddress,adminAddress);
        shareCore.registerStakeCore(address(rewardPayout));

        console.log("shareCore deployed to:", address(shareCore));
        console.log("rewardPayout deployed to:", address(rewardPayout));
        vm.stopBroadcast();
    }
}
