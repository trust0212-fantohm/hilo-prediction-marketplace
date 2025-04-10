const { ethers } = require("ethers");

// Import contract ABIs - replace these paths with your actual ABI paths
const MockERC20_ABI = require("../build2/contracts/MockERC20.json");
const HiloStaking_ABI = require("../build2/contracts/HiloStaking.json");
const HiloBonding_ABI = require("../build2/contracts/HiloBonding.json");
const HiloPredictionMarket_ABI = require("../build2/contracts/HiloPredictionMarket.json");

async function main() {
  try {
    // Your network RPC endpoint
    const provider = new ethers.JsonRpcProvider("https://erc20.hiloscan.io:8448");
    
    // Your private key
    const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
    if (!DEPLOYER_PRIVATE_KEY) {
      throw new Error("DEPLOYER_PRIVATE_KEY is not set in your .env file.");
    }
    const wallet = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);
    console.log("Using address:", wallet.address);
    
    // Contract addresses
    const contractAddresses = {
      "MockERC20": "0xe2B92290E490143C89D9a38a77b58a7856254eBB",
    "HiloStaking": "0x1057dC6371A8F8caf8c393b8a18D8C2ba26EE592",
    "HiloBonding": "0x4581a1021e551e9d34940b795EcEfDFBc0F3E67F",
    "HiloPredictionMarket": "0xE4A3Be49d670e83e72804F34f8CEc210731EbDa4"
    };
    
    // Connect to contracts
    const mockToken = new ethers.Contract(contractAddresses.MockERC20, MockERC20_ABI, wallet);
    const hiloStaking = new ethers.Contract(contractAddresses.HiloStaking, HiloStaking_ABI, wallet);
    const hiloBonding = new ethers.Contract(contractAddresses.HiloBonding, HiloBonding_ABI, wallet);
    const hiloPredict = new ethers.Contract(contractAddresses.HiloPredictionMarket, HiloPredictionMarket_ABI, wallet);
    
    console.log("Connected to contracts as deployer:", wallet.address);
    
    // Mint tokens to the deployer
    console.log("Minting tokens to deployer...");
    try {
      const mintAmount = ethers.parseUnits("1000", 18);
      await mockToken.mint(wallet.address, mintAmount);
      
      const balance = await mockToken.balanceOf(wallet.address);
      console.log("Token balance:", ethers.formatUnits(balance, 18));
    } catch (error) {
      console.log("Error minting tokens:", error.message);
      console.log("Continuing anyway - you may already have tokens");
    }
    
    // Create a pool and option group
    console.log("Creating a new prediction pool...");
    const poolId = Math.floor(Math.random() * 1000000);
    const optionGroupId = poolId;
    
    // Get current block timestamp
    const block = await provider.getBlock("latest");
    const currentTime = block.timestamp;
    
    // Based on your config, we're setting appropriate timeframes
    const startTime = currentTime + 60; // Start in 1 minute
    const settleTime = currentTime + (60 * 4); // 4 minutes from now (short for testing)
    const poolTitle = "Test Pool";
    const data = "Test pool data";
    const optionNames = ["Option A", "Option B"]; // Two options as requested
    
    // Create pool and option group in a single step
    console.log(`Creating pool with ID: ${poolId} and option group with ID: ${optionGroupId}`);
    await hiloPredict.createPoolAndOptionGroup(
      poolId,
      optionGroupId,
      poolTitle,
      startTime,
      settleTime,
      data,
      optionNames
    );
    console.log("Pool and option group created");
    
    // Validate the pool (vote in evaluation phase)
    console.log("Voting in evaluation phase...");
    await hiloBonding.voteEvaluation(poolId, true); // true = approve
    console.log("Evaluation vote submitted");
    
    // Attempt to complete evaluation phase
    try {
      await hiloBonding.completeEvaluationPhase(poolId);
      console.log("Evaluation phase completed");
    } catch (error) {
      console.log("Could not complete evaluation phase yet:", error.message);
    }
    
    // Wait for start time
    console.log(`Pool betting will start at timestamp ${startTime} (in about 1 minute)`);
    console.log("Current timestamp:", currentTime);
    console.log("Waiting for start time to place bets...");
    
    while ((await provider.getBlock("latest")).timestamp < startTime) {
      console.log("Waiting for start time...");
      await new Promise(resolve => setTimeout(resolve, 5000)); // Wait 5 seconds
    }
    
    // Place bets directly without adding liquidity
    console.log("Start time reached, placing bets...");
    const betAmount = ethers.parseUnits("10", 18); // 10 tokens
    const minOdds = 1; // Minimum acceptable odds
    
    // Approve token spending for bets
    await mockToken.approve(contractAddresses.HiloPredictionMarket, ethers.parseUnits("100", 18));
    console.log("Approved tokens for betting");
    
    // Place bet on first option
    try {
      await hiloPredict.placeBet(optionGroupId, 0, betAmount, minOdds);
      console.log(`Placed bet of ${ethers.formatUnits(betAmount, 18)} tokens on ${optionNames[0]}`);
    } catch (error) {
      console.log(`Error placing bet on ${optionNames[0]}:`, error.message);
    }
    
    // Place bet on second option
    try {
      await hiloPredict.placeBet(optionGroupId, 1, betAmount, minOdds);
      console.log(`Placed bet of ${ethers.formatUnits(betAmount, 18)} tokens on ${optionNames[1]}`);
    } catch (error) {
      console.log(`Error placing bet on ${optionNames[1]}:`, error.message);
    }
    
    // Get and display odds after bets
    console.log("\nOdds after betting:");
    const PRECISION = 10000; // From contract
    
    try {
      for (let i = 0; i < optionNames.length; i++) {
        const oddsAfter = await hiloPredict.getOdds(optionGroupId, i);
        const decimalOddsAfter = Number(oddsAfter) / PRECISION;
        console.log(`${optionNames[i]}: ${decimalOddsAfter.toFixed(2)}`);
      }
    } catch (error) {
      console.log("Error getting odds after betting:", error.message);
    }
    
    // Display potential returns
    console.log("\nPotential returns:");
    try {
      for (let i = 0; i < optionNames.length; i++) {
        const [potentialReturn, lockedOdds] = await hiloPredict.calculatePotentialReturn(
          optionGroupId, i, betAmount
        );
        
        console.log(`If ${optionNames[i]} wins:`);
        console.log(`  Potential return: ${ethers.formatUnits(potentialReturn, 18)} tokens`);
        console.log(`  Locked odds: ${Number(lockedOdds) / PRECISION}`);
      }
    } catch (error) {
      console.log("Error calculating potential returns:", error.message);
    }
    
    console.log("\nPool setup and betting complete!");
    console.log(`Pool ID: ${poolId}`);
    console.log(`Option Group ID: ${optionGroupId}`);
    console.log(`Settle time: ${new Date(settleTime * 1000).toLocaleString()}`);
    
    return {
      poolId,
      optionGroupId,
      options: optionNames
    };
  } catch (error) {
    console.error("Top-level error:", error);
    throw error;
  }
}

main()
  .then((result) => {
    console.log("Script executed successfully!");
    console.log("Results:", result);
    process.exit(0);
  })
  .catch((error) => {
    console.error("Error executing script:", error);
    process.exit(1);
  });