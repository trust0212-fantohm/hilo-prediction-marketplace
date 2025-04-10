const hre = require("hardhat");
const { ethers } = hre;
const fs = require("fs");
const path = require("path");
require("dotenv").config();

async function main() {
  // Set up the custom RPC provider.
  const rpcUrl = "https://erc20.hiloscan.io:8448";
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Load deployer's private key from the environment.
  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!deployerPrivateKey) {
    throw new Error("DEPLOYER_PRIVATE_KEY is not set in your .env file.");
  }
  const deployer = new ethers.Wallet(deployerPrivateKey, provider);
  console.log("Deployer address:", deployer.address);

  // Load the deployment configuration to get the contract addresses
  let deploymentConfig;
  try {
    const buildDir = path.join(__dirname, "../build");
    const deploymentFile = path.join(buildDir, "deployment.json");
    deploymentConfig = JSON.parse(fs.readFileSync(deploymentFile, 'utf8'));
    console.log("Loaded deployment configuration");
  } catch (error) {
    console.error("Failed to load deployment configuration. Make sure you've run the deployment script first:", error);
    process.exit(1);
  }

  // Get contract addresses
  const hiloBondingAddress = deploymentConfig.contracts.HiloBonding;
  const hiloPredictionMarketAddress = deploymentConfig.contracts.HiloPredictionMarket;
  
  console.log("HiloBonding contract address:", hiloBondingAddress);
  console.log("HiloPredictionMarket contract address:", hiloPredictionMarketAddress);

  // Create contract instances
  const HiloBonding = await ethers.getContractFactory("HiloBonding", deployer);
  const hiloBonding = HiloBonding.attach(hiloBondingAddress);
  
  const HiloPredictionMarket = await ethers.getContractFactory("HiloPredictionMarket", deployer);
  const hiloPredictionMarket = HiloPredictionMarket.attach(hiloPredictionMarketAddress);
  
  console.log("Connected to contracts");
  
  // ==========================================
  // CONFIGURATION - MODIFY THESE VALUES
  // ==========================================
  
  // Specify the pool and user address you want to check
  const optionGroupId = 117; // Replace with your option group ID
  const userAddress = "0x69e8ec8608f1579ec724c71824b054e8e7006485"; // Replace with the user's address
  
  // ==========================================
  // GET POOL INFORMATION
  // ==========================================
  
  // Get basic pool information
  console.log(`\n=== Checking Pool ${optionGroupId} ===`);
  
  // Get pool details from the bonding contract
  try {
    const poolId = await hiloPredictionMarket.optionGroups(optionGroupId);
    // Get pool status from bonding contract
    const poolStatus = await hiloBonding.getPoolStatus(poolId);
    
    console.log("Pool Status:");
    console.log(`- Processed: ${poolStatus[0]}`);
    console.log(`- Processed Time: ${Number(poolStatus[1])}`);
    console.log(`- Final Approval: ${poolStatus[2]}`);
    console.log(`- Dispute Round: ${poolStatus[3]}`);
    console.log(`- Winning Option Index: ${Number(poolStatus[4])}`);
    
    // Get pool timelines
    const timelines = await hiloBonding.getPoolTimelines(poolId);
    const currentTime = (await provider.getBlock("latest")).timestamp;
    
    console.log("\nPool Timelines:");
    console.log(`- Current Time: ${currentTime}`);
    console.log(`- Evaluation Phase: ${Number(timelines[0])} - ${Number(timelines[1])}`);
    console.log(`- Option Voting Phase: ${Number(timelines[2])} - ${Number(timelines[3])}`);
    console.log(`- Dispute End: ${Number(timelines[4])}`);
    
    // Determine current phase
    let currentPhase = "Unknown";
    if (currentTime < Number(timelines[0])) {
      currentPhase = "Pre-Evaluation";
    } else if (currentTime >= Number(timelines[0]) && currentTime <= Number(timelines[1])) {
      currentPhase = "Evaluation";
    } else if (currentTime > Number(timelines[1]) && currentTime < Number(timelines[2])) {
      currentPhase = "Between Evaluation and Option Voting";
    } else if (currentTime >= Number(timelines[2]) && currentTime <= Number(timelines[3])) {
      currentPhase = "Option Voting";
    } else if (currentTime > Number(timelines[3]) && currentTime <= Number(timelines[4])) {
      currentPhase = "Dispute";
    } else if (currentTime > Number(timelines[4])) {
      currentPhase = "Post-Dispute";
    }
    console.log(`- Current Phase: ${currentPhase}`);
  } catch (error) {
    console.log("Failed to get pool details:", error.message);
  }
  
  // Get option names
  try {
    const optionNames = await hiloPredictionMarket.getOptionNames(optionGroupId);
    console.log("\nPool Options:");
    for (let i = 0; i < optionNames.length; i++) {
      console.log(`- Option ${i}: ${optionNames[i]}`);
    }
  } catch (error) {
    console.log("Failed to get option names:", error.message);
  }
  
  // ==========================================
  // GET USER POSITION
  // ==========================================
  
  console.log(`\n=== Checking User Position for ${userAddress} ===`);
  
  try {
    // Get general position results
    const positionResults = await hiloPredictionMarket.GetPoolPositionResults(
      optionGroupId, 
      userAddress
    );
    
    console.log("Position Results:");
    console.log(`- Pool Settled: ${positionResults[0]}`);
    console.log(`- Pool Canceled: ${positionResults[1]}`);
    console.log(`- Winning Option Index: ${Number(positionResults[2])}`);
    
    console.log("\nUser Bets:");
    const hasBets = positionResults[3].some(bet => bet > 0n);
    
    if (!hasBets) {
      console.log("❌ USER HAS NO BETS IN THIS POOL");
    } else {
      for (let i = 0; i < positionResults[3].length; i++) {
        const betAmount = positionResults[3][i];
        if (betAmount > 0) {
          console.log(`- Option ${i}: ${ethers.formatEther(betAmount)} tokens`);
          
          // Get potential return
          const potentialReturn = positionResults[4][i];
          console.log(`  Potential Return: ${ethers.formatEther(potentialReturn)} tokens`);
          
          // Check if user can claim winnings
          if (positionResults[0] && Number(positionResults[2]) === i) {
            console.log(`  ✅ WINNINGS AVAILABLE: ${ethers.formatEther(positionResults[5])} tokens`);
          }
          
          // Detailed diagnosis of early exit
          console.log(`\n=== Early Exit Details for Option ${i} ===`);
          await diagnoseEarlyExitIssue(optionGroupId, userAddress, i, hiloPredictionMarket);
        }
      }
    }
    
    // If pool is settled, show claimable amount
    if (positionResults[0] || positionResults[1]) {
      console.log(`\nClaimable Amount: ${ethers.formatEther(positionResults[5])} tokens`);
    }
    
  } catch (error) {
    console.log("Failed to get position results:", error.message);
  }
}

// Diagnostic function to troubleshoot why getEarlyExitDetails returns zeros
async function diagnoseEarlyExitIssue(optionGroupId, userAddress, optionIndex, hiloPredictionMarket) {
  try {
    // 1. Check user bet
    const userBet = await hiloPredictionMarket.getUserBet(optionGroupId, userAddress, optionIndex);
    console.log(`User Bet: ${ethers.formatEther(userBet)} tokens`);
    
    if (userBet == 0) {
      console.log("⚠️ USER HAS NO BET on this option - this explains the zeros");
      return;
    }
    
    // 2. Check pool status
    const poolPosition = await hiloPredictionMarket.GetPoolPositionResults(optionGroupId, userAddress);
    console.log(`Pool Settled: ${poolPosition[0]}`);
    console.log(`Pool Canceled: ${poolPosition[1]}`);
    
    if (poolPosition[0] || poolPosition[1]) {
      console.log("⚠️ POOL IS SETTLED OR CANCELED - early exit not available");
      return;
    }
    
    // 3. Check liquidity conditions
    try {
      const currentLiquidity = await hiloPredictionMarket.getCurrentLiquidity(optionGroupId);
      console.log(`Option ${optionIndex} Liquidity: ${ethers.formatEther(currentLiquidity[optionIndex])} tokens`);
      
      if (currentLiquidity[optionIndex] == 0) {
        console.log("⚠️ ZERO LIQUIDITY for this option - this explains the zeros");
        return;
      }
      
      console.log(`User bet is ${(Number(userBet) * 100 / Number(currentLiquidity[optionIndex])).toFixed(2)}% of option liquidity`);
      
      const totalLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(optionGroupId);
      console.log(`Total Pool Liquidity: ${ethers.formatEther(totalLiquidity)} tokens`);
    } catch (error) {
      console.log("Failed to check liquidity:", error.message);
    }
    
    // 4. Get early exit details
    try {
      console.log("\nEarly Exit Details:");
      const exitDetails = await hiloPredictionMarket.getEarlyExitDetails(optionGroupId, optionIndex);
      console.log(`- Bet Amount: ${ethers.formatEther(exitDetails[0])} tokens`);
      console.log(`- Exit Value (before fees): ${ethers.formatEther(exitDetails[1])} tokens`);
      console.log(`- Exit Value (after fees): ${ethers.formatEther(exitDetails[2])} tokens`);
      
      if (exitDetails[0] > 0 && exitDetails[1] == 0) {
        console.log("⚠️ EXIT VALUE IS ZERO - may be an issue with the AMM formula");
      }
      
      // 5. Try direct calculation as well
      const exitValue = await hiloPredictionMarket.calculateEarlyExitValue(
        optionGroupId, 
        optionIndex, 
        userBet
      );
      console.log(`\nDirect Exit Value Calculation: ${ethers.formatEther(exitValue)} tokens`);
      
      const earlyExitFee = await hiloPredictionMarket.earlyExitFee();
      console.log(`Early Exit Fee: ${Number(earlyExitFee)/100}%`);
      
      const fee = (exitValue * earlyExitFee) / 10000n;
      const afterFees = exitValue - fee;
      console.log(`Calculated After Fees: ${ethers.formatEther(afterFees)} tokens`);
      
      if (exitValue == 0) {
        console.log("⚠️ CALCULATED EXIT VALUE IS ZERO - issue is in the calculateEarlyExitValue function");
      }
    } catch (error) {
      console.log("Failed to get exit details:", error.message);
    }
  } catch (error) {
    console.log("Error in diagnose function:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error in script:", error);
    process.exit(1);
  });