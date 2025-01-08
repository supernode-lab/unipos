import fs, { writeFileSync } from "fs"
import hre, { ethers, upgrades } from "hardhat"
import { Contract } from "ethers"
import { formatEther, parseEther } from "ethers/lib/utils"

async function deployAll() {
    console.log("\x1b[4m%s\x1b[0m", "\nDeployment Information")
    const NETWORK_NAME = hre.network.name
    const NETWORK = hre.network.config.chainId
    const [deployer] = await ethers.getSigners()
    const protocolOwner = await deployer.getAddress()

    if (NETWORK == undefined) {
        console.log("No network id found")
        return
    }
    console.log("Network Name:", NETWORK_NAME)
    console.log("Chain ID:", NETWORK)
    console.log("Deployer:", await deployer.getAddress())

    // ============== Deploy All ==================
    
    const Core = await ethers.getContractFactory("StakeCore")
    const BeneficiaryCore = await ethers.getContractFactory("BeneficiaryCore")
    const tokenAddress = '0x46bEE5F8aF3dcff4D6C97993b815785E27cAE80c'
    const lockDays = 180
    const stakerShare = 60
    const installmentCount = 1
    const core = await Core.deploy(tokenAddress,lockDays, stakerShare, installmentCount )
    await core.deployed()
    const bfc = await BeneficiaryCore.deploy(tokenAddress, deployer.address, core.address)
    await bfc.deployed()
    console.log("Stake Core deployed to:", core.address);
    console.log("BeneficiaryCore deployed to:", bfc.address);
}
deployAll().catch((error) => {
    console.error(error)
    process.exitCode = 1
})
