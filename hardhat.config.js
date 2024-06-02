require('dotenv').config();
require('@nomiclabs/hardhat-waffle')
require('@nomiclabs/hardhat-ethers')
require("@nomiclabs/hardhat-web3")
require('@openzeppelin/hardhat-upgrades')


/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    networks: {
        local: {
            url: 'http://127.0.0.1:8545',
            accounts: [process.env.DEPLOYER_PRIVATE_KEY]
        },
        sepolia: {
            url: 'https://sepolia.drpc.org',
            accounts: [process.env.PRIVATE_KEY]
        },
    },
    solidity: {
        version: "0.6.12",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
        compilers: [
            {
                version: "0.6.7",
            },
            {
                version: "0.6.12",
            },
        ],
    },
};
