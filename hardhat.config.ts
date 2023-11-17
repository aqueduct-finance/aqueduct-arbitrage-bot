import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-preprocessor";
import fs from "fs";
import * as dotenv from "dotenv";

dotenv.config();

function getRemappings() {
    return fs
        .readFileSync("remappings.txt", "utf8")
        .split("\n")
        .filter(Boolean) // remove empty lines
        .map((line) => line.trim().split("="));
}

const config: HardhatUserConfig = {
    networks: {
        hardhat: {
            forking: {
                url: process.env.POLYGON_URL ?? '',
                blockNumber: 49948000 // fork from same block number every time for testing consistency
            },
            blockGasLimit: 30000000,
        },
    },
    solidity: {
        compilers: [
            {
                version: "0.8.19",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    metadata: {
                        bytecodeHash: "none",
                    },
                },
            },
            {
                version: "0.7.6",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    metadata: {
                        bytecodeHash: "none",
                    },
                },
            },
        ]
    },
    gasReporter: {
        enabled: process.env.REPORT_GAS !== undefined,
        currency: "USD",
    },
    typechain: {
        outDir: "typechain-types",
        target: "ethers-v5",
    },
    preprocess: {
        eachLine: (hre) => ({
            transform: (line: string) => {
                if (line.match(/^\s*import /i)) {
                    for (const [from, to] of getRemappings()) {
                        if (line.includes(from)) {
                            line = line.replace(from, to);
                            break;
                        }
                    }
                }
                return line;
            },
        }),
    },
    paths: {
        sources: "./src",
        cache: "./cache_hardhat",
    },
    mocha: {
        timeout: 100000000
    },
};

export default config;
