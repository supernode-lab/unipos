import "@nomicfoundation/hardhat-toolbox"
import "@openzeppelin/hardhat-upgrades"
import "hardhat-gas-reporter"
import { HardhatUserConfig } from "hardhat/config"
import "solidity-coverage"
require("dotenv").config()

const { PRIVATE_KEY } = process.env

const config: HardhatUserConfig = {
    solidity: {
        version: "0.8.20",
        settings: {
            viaIR: true,
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
    },
    networks: {
        hardhat: {},
        ethereum: {
            chainId: 1,
            url: "https://mainnet.infura.io/v3/your-infura-key",
            accounts: [PRIVATE_KEY!],
            allowUnlimitedContractSize: true,
        },
        goerli: {
            chainId: 5,
            url: "https://goerli.infura.io/v3/your-infura-key",
            accounts: [PRIVATE_KEY!],
        },
        sepolia: {
            chainId: 11155111,
            url: "https://1rpc.io/sepolia",
            accounts: [PRIVATE_KEY!],
        }
    },
    gasReporter: {
        enabled: false,
    },
    paths: {
        artifacts: "build/artifacts",
        cache: "build/cache",
        sources: "src",
    },
}

export default config
