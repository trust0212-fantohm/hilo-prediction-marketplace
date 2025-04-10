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
    const buildDir = path.join(__dirname, "build");
    const deploymentFile = path.join(buildDir, "deployment.json");
    deploymentConfig = JSON.parse(fs.readFileSync(deploymentFile, 'utf8'));
    console.log("Loaded deployment configuration");
  } catch (error) {
    console.error("Failed to load deployment configuration. Make sure you've run the deployment script first:", error);
    process.exit(1);
  }

  // Get the HiloBonding contract address
  const hiloBondingAddress = deploymentConfig.contracts.HiloBonding;
  if (!hiloBondingAddress) {
    console.error("HiloBonding address not found in deployment configuration");
    process.exit(1);
  }
  console.log("HiloBonding contract address:", hiloBondingAddress);

  // Create contract instance
  const HiloBonding = await ethers.getContractFactory("HiloBonding", deployer);
  const hiloBonding = HiloBonding.attach(hiloBondingAddress);
  console.log("Connected to HiloBonding contract");

  // Get current config values
  
  // Create new config array with updated option voting duration (7 hours)
  const SEVEN_HOURS_IN_SECONDS = 7 * 60 * 60; // 7 hours = 25200 seconds
  // Define durations (shorter for testing)
  const EVALUATION_DURATION = 1.5 * 60; // 10- minutes
  const OPTION_VOTING_DURATION = (60*60) * 7; // 7 hrs  
  const DISPUTE_DURATION = 0.2 * 60; // 2 minute
  const AUTO_UNFREEZE_DELAY = 30; // 30 seconds

  const FALSE_EVAL_PENALTY = ethers.parseEther("0.1");
  const TRUE_EVAL_REWARD = ethers.parseEther("0.05");
  const TRUE_DISPUTE_REWARD = ethers.parseEther("0.1");
  const FALSE_DISPUTE_PENALTY = ethers.parseEther("0.15");
  const GOOD_POOL_REWARD = ethers.parseEther("0.2");
  const BAD_POOL_PENALTY = ethers.parseEther("0.3");
  const MIN_VOTES_REQUIRED = 1; // Reduced for testing
  const POOL_CREATION_FEE = ethers.parseEther("0");
  const INITIAL_PER_OPTION_CAP = 5;
  const MAX_VOTE_DIFFERENCE = 3;

  const newConfigValues = [
    EVALUATION_DURATION,
    OPTION_VOTING_DURATION,
    DISPUTE_DURATION,
    AUTO_UNFREEZE_DELAY,
    FALSE_EVAL_PENALTY,
    TRUE_EVAL_REWARD,
    TRUE_DISPUTE_REWARD,
    FALSE_DISPUTE_PENALTY,
    GOOD_POOL_REWARD,
    BAD_POOL_PENALTY,
    MIN_VOTES_REQUIRED,
    POOL_CREATION_FEE,
    INITIAL_PER_OPTION_CAP,
    MAX_VOTE_DIFFERENCE
  ];

  

  console.log("\nUpdating configuration...");
  console.log("New Option Voting Duration:", SEVEN_HOURS_IN_SECONDS, "seconds (7 hours)");

  // Update the configuration
  try {
    const tx = await hiloBonding.updateConfig(newConfigValues);
    const receipt = await tx.wait();
    console.log("Configuration updated successfully!");
    console.log("Transaction hash:", receipt.hash);
    
    // Verify the update
   
    console.log("\nVerification:");
    console.log("Updated Option Voting Duration:", Number(updatedDuration), "seconds");
    
    if(Number(updatedDuration) === SEVEN_HOURS_IN_SECONDS) {
      console.log("✅ Configuration successfully updated to 7 hours!");
    } else {
      console.log("❌ Configuration update verification failed");
    }
  } catch (error) {
    console.error("Failed to update configuration:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error in update script:", error);
    process.exit(1);
  });