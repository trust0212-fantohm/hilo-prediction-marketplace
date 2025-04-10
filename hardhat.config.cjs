require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.26",
    settings: {
      // We need viaIR for this complex contract
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 1  // Most aggressive optimization to reduce code size
      },
    }
  },
  networks: {
    hardhat: {
      accounts: {
        count: 25, // Provide 25 accounts for testing
      },
    },
  },
};
