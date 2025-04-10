const hre = require("hardhat");
const { ethers } = hre;
const fs = require("fs");
const path = require("path");
require("dotenv").config();

async function main() {
  // Configuration - MODIFY THESE VALUES
  const POOL_OPTION_GROUP_ID = 46; // Replace with your target option group ID
  const LIQUIDITY_AMOUNT = ethers.parseEther("100"); // Amount of tokens to add as liquidity
  
  // Set up the custom RPC provider.
  const rpcUrl = "https://erc20.hiloscan.io:8448"; // Update this if needed
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Load deployer's private key from the environment.
  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!deployerPrivateKey) {
    throw new Error("DEPLOYER_PRIVATE_KEY is not set in your .env file.");
  }
  const deployer = new ethers.Wallet(deployerPrivateKey, provider);
  console.log("Deployer address:", deployer.address);

  // Load contract addresses and ABIs from the build directory
  
  
 

  
  // Get contract addresses
  const mockTokenAddress = "0x5ADd24cD0c13C1A09CB22247913450024eEacA3c";
  const hiloPredictionMarketAddress = "0x620FD615EF1764acF05d854c4AB04150436734Fd";
  
  console.log("Using MockERC20 at:", mockTokenAddress);
  console.log("Using HiloPredictionMarket at:", hiloPredictionMarketAddress);
  
  // Load contract ABIs
  const mockTokenAbi = JSON.parse(fs.readFileSync(path.join(buildDir, "MockERC20.json"), 'utf8'));
  const hiloPredictionMarketAbi = JSON.parse(fs.readFileSync(path.join(buildDir, "HiloPredictionMarket.json"), 'utf8'));
  
  // Create contract instances
  const mockToken = new ethers.Contract(mockTokenAddress, mockTokenAbi, deployer);
  const hiloPredictionMarket = new ethers.Contract(hiloPredictionMarketAddress, hiloPredictionMarketAbi, deployer);
  
  // Check token balance before minting
  const initialBalance = await mockToken.balanceOf(deployer.address);
  console.log(`Initial token balance: ${ethers.formatEther(initialBalance)} HTT`);
  
  // Mint tokens if needed
  if (initialBalance < LIQUIDITY_AMOUNT) {
    console.log(`Minting ${ethers.formatEther(LIQUIDITY_AMOUNT)} tokens...`);
    
    // Check if the deployer has the minter role
    const MINTER_ROLE = await mockToken.MINTER_ROLE();
    const hasMinterRole = await mockToken.hasRole(MINTER_ROLE, deployer.address);
    
    if (!hasMinterRole) {
      console.log("Deployer doesn't have minter role. Attempting to mint anyway...");
    }
    
    try {
      const mintTx = await mockToken.mint(deployer.address, LIQUIDITY_AMOUNT);
      await mintTx.wait();
      console.log(`Successfully minted ${ethers.formatEther(LIQUIDITY_AMOUNT)} tokens`);
    } catch (error) {
      console.error("Error minting tokens:", error.message);
      console.log("Attempting to continue with existing balance...");
    }
  }
  
  // Check token balance after minting
  const currentBalance = await mockToken.balanceOf(deployer.address);
  console.log(`Current token balance: ${ethers.formatEther(currentBalance)} HTT`);
  
  if (currentBalance < LIQUIDITY_AMOUNT) {
    console.warn(`Warning: Token balance (${ethers.formatEther(currentBalance)}) is less than requested liquidity amount (${ethers.formatEther(LIQUIDITY_AMOUNT)})`);
    console.log(`Will proceed with maximum available balance: ${ethers.formatEther(currentBalance)}`);
  }
  
  // Get pool information
  try {
    console.log(`Getting information for option group ID: ${POOL_OPTION_GROUP_ID}`);
    const optionNames = await hiloPredictionMarket.getOptionNames(POOL_OPTION_GROUP_ID);
    console.log(`Pool has ${optionNames.length} options:`, optionNames);
    
    // Get current liquidity
    const currentLiquidity = await hiloPredictionMarket.getCurrentLiquidity(POOL_OPTION_GROUP_ID);
    console.log("Current liquidity per option:", currentLiquidity.map(l => ethers.formatEther(l)));
    
    // Calculate total liquidity
    const totalLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(POOL_OPTION_GROUP_ID);
    console.log(`Total liquidity in pool: ${ethers.formatEther(totalLiquidity)}`);
  } catch (error) {
    console.warn("Error getting pool information:", error.message);
    console.log("Continuing with liquidity addition anyway...");
  }
  
  // Approve tokens for the prediction market
  const liquidityToAdd = currentBalance < LIQUIDITY_AMOUNT ? currentBalance : LIQUIDITY_AMOUNT;
  console.log(`Approving ${ethers.formatEther(liquidityToAdd)} tokens for the prediction market...`);
  
  try {
    const approveTx = await mockToken.approve(hiloPredictionMarketAddress, liquidityToAdd);
    await approveTx.wait();
    console.log("Token approval successful");
  } catch (error) {
    console.error("Error approving tokens:", error.message);
    process.exit(1);
  }
  
  // Add liquidity to the pool
  console.log(`Adding ${ethers.formatEther(liquidityToAdd)} tokens as liquidity to pool ${POOL_OPTION_GROUP_ID}...`);
  
  try {
    const addLiquidityTx = await hiloPredictionMarket.addLiquidity(POOL_OPTION_GROUP_ID, liquidityToAdd);
    const receipt = await addLiquidityTx.wait();
    
    // Check if the transaction was successful
    if (receipt && receipt.status === 1) {
      console.log("✅ Successfully added liquidity!");
      
      // Get updated liquidity information
      const updatedCurrentLiquidity = await hiloPredictionMarket.getCurrentLiquidity(POOL_OPTION_GROUP_ID);
      console.log("Updated liquidity per option:", updatedCurrentLiquidity.map(l => ethers.formatEther(l)));
      
      const updatedTotalLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(POOL_OPTION_GROUP_ID);
      console.log(`Updated total liquidity in pool: ${ethers.formatEther(updatedTotalLiquidity)}`);
    } else {
      console.error("Transaction failed");
    }
  } catch (error) {
    console.error("Error adding liquidity:", error.message);
    
    // Try to provide helpful error interpretation
    if (error.message.includes("Pool already started")) {
      console.log("This pool has already started. You can only add liquidity before the pool starts.");
    } else if (error.message.includes("Option group does not exist")) {
      console.log(`Option group ID ${POOL_OPTION_GROUP_ID} doesn't exist. Please check the ID.`);
    } else if (error.message.includes("Option group settled")) {
      console.log("This pool has already been settled. You cannot add liquidity to a settled pool.");
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error in script:", error);
    process.exit(1);
  });