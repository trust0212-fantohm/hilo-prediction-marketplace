const hre = require("hardhat");
const { ethers, network } = hre;
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

  // Create new random wallets for validators and fund them
  const validator1 = deployer; // Use deployer as the first validator
  const validator2 = ethers.Wallet.createRandom().connect(provider);
  const validator3 = ethers.Wallet.createRandom().connect(provider);

  console.log("Validator 1 address (deployer):", validator1.address);
  console.log("Validator 2 address:", validator2.address);
  console.log("Validator 3 address:", validator3.address);

  // Fund the validators with ETH
  const fundingAmount = ethers.parseEther("3");
  console.log("Funding validator 2 with 3 ETH...");
  await deployer.sendTransaction({ to: validator2.address, value: fundingAmount });
  console.log("Funding validator 3 with 3 ETH...");
  await deployer.sendTransaction({ to: validator3.address, value: fundingAmount });

  const poolCreator = deployer;

  // ----------------------
  // DEPLOYMENT PHASE
  // ----------------------

  // Deploy MockERC20 token
  const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
  const INITIAL_TOKEN_SUPPLY = ethers.parseEther("10000000"); // 10 million tokens
  const mockToken = await MockERC20.deploy("Hilo Test Token", "HTT", INITIAL_TOKEN_SUPPLY);
  await mockToken.waitForDeployment();
  console.log("MockERC20 deployed at:", mockToken.target);

  // Deploy HiloStaking
  const HiloStaking = await ethers.getContractFactory("HiloStaking", deployer);
  const validatorThreshold = ethers.parseEther("1");
  const poolCreatorThreshold = ethers.parseEther("2");
  const evaluatorThreshold = ethers.parseEther("0.5");
  const hiloStaking = await HiloStaking.deploy(validatorThreshold, poolCreatorThreshold, evaluatorThreshold);
  await hiloStaking.waitForDeployment();
  console.log("HiloStaking deployed at:", hiloStaking.target);

  // Stake roles
  let tx = await hiloStaking.connect(poolCreator).buyPoolCreator({ value: poolCreatorThreshold });
  await tx.wait();
  console.log("PoolCreator role acquired by:", poolCreator.address);

  tx = await hiloStaking.connect(validator1).buyValidator({ value: validatorThreshold });
  await tx.wait();
  console.log("Validator role acquired by validator 1:", validator1.address);

  tx = await hiloStaking.connect(validator2).buyValidator({ value: validatorThreshold });
  await tx.wait();
  console.log("Validator role acquired by validator 2:", validator2.address);

  tx = await hiloStaking.connect(validator3).buyValidator({ value: validatorThreshold });
  await tx.wait();
  console.log("Validator role acquired by validator 3:", validator3.address);

  // Deploy HiloBonding with custom durations
  const HiloBonding = await ethers.getContractFactory("HiloBonding", deployer);

  // Define durations (shorter for testing)
  const EVALUATION_DURATION = 60 * 60 * 24; // 1 day
  const OPTION_VOTING_DURATION = 60 * 60 * 24; // 1 day
  const DISPUTE_DURATION = 60 * 60 * 12; // 12 hours
  const AUTO_UNFREEZE_DELAY = 60 * 60 * 6; // 6 hours

  const FALSE_EVAL_PENALTY = ethers.parseEther("0.1");
  const TRUE_EVAL_REWARD = ethers.parseEther("0.05");
  const TRUE_DISPUTE_REWARD = ethers.parseEther("0.1");
  const FALSE_DISPUTE_PENALTY = ethers.parseEther("0.15");
  const GOOD_POOL_REWARD = ethers.parseEther("0.2");
  const BAD_POOL_PENALTY = ethers.parseEther("0.3");
  const MIN_VOTES_REQUIRED = 2; // Standard requirement
  const POOL_CREATION_FEE = ethers.parseEther("0");
  const INITIAL_PER_OPTION_CAP = 5;
  const MAX_VOTE_DIFFERENCE = 5;

  const configValues = [
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

  const hiloBonding = await HiloBonding.deploy(await hiloStaking.getAddress(), configValues);
  await hiloBonding.waitForDeployment();
  console.log("HiloBonding deployed at:", hiloBonding.target);
  console.log("Configured with evaluation duration:", EVALUATION_DURATION, "seconds");
  console.log("Configured with option voting duration:", OPTION_VOTING_DURATION, "seconds");
  console.log("Configured with dispute duration:", DISPUTE_DURATION, "seconds");

  // Deploy HiloPredictionMarket
  const HiloPredictionMarket = await ethers.getContractFactory("HiloPredictionMarket", deployer);
  const hiloPredictionMarket = await HiloPredictionMarket.deploy(
    hiloBonding.target,
    hiloStaking.target,
    mockToken.target
  );
  await hiloPredictionMarket.waitForDeployment();
  console.log("HiloPredictionMarket deployed at:", hiloPredictionMarket.target);
  
  // Configure default liquidity
  // Set default liquidity amount (100 tokens per pool)
  const DEFAULT_LIQUIDITY = ethers.parseEther("150");
  
  // Fund prediction market with tokens for default liquidity
  const LIQUIDITY_FUND = ethers.parseEther("1000000");
  tx = await mockToken.transfer(hiloPredictionMarket.target, LIQUIDITY_FUND);
  await tx.wait();
  console.log(`Transferred ${ethers.formatEther(LIQUIDITY_FUND)} tokens to prediction market contract`);
  
  // Enable default liquidity in prediction market
  tx = await hiloPredictionMarket.configureDefaultLiquidity(true, DEFAULT_LIQUIDITY);
  await tx.wait();
  console.log(`Configured default liquidity: Enabled with ${ethers.formatEther(DEFAULT_LIQUIDITY)} tokens per pool`);
  
  // Update platform fee in prediction market
  tx = await hiloPredictionMarket.connect(deployer).updatePlatformFee(300); // 3%
  await tx.wait(); 
  console.log("Updated platform fee to 3%");
  
  // Save deployment artifacts
  const buildDir = path.join(__dirname, "build");
  
  // Create build directory if it doesn't exist
  if (!fs.existsSync(buildDir)) {
    fs.mkdirSync(buildDir, { recursive: true });
  }
  
  // Save contract addresses
  const deploymentConfig = {
    network: network.name,
    timestamp: new Date().toISOString(),
    contracts: {
      MockERC20: mockToken.target,
      HiloStaking: hiloStaking.target,
      HiloBonding: hiloBonding.target,
      HiloPredictionMarket: hiloPredictionMarket.target
    }
  };
  
  fs.writeFileSync(
    path.join(buildDir, "deployment.json"),
    JSON.stringify(deploymentConfig, null, 2)
  );
  console.log("Saved deployment configuration to build/deployment.json");

  // Authorize contracts
  tx = await hiloStaking.updateAuthorizedAddress(hiloBonding.target, true);
  await tx.wait();
  tx = await hiloStaking.updateAuthorizedAddress(hiloPredictionMarket.target, true);
  await tx.wait();
  tx = await hiloStaking.updateAuthorizedAddress(poolCreator.address, true);
  await tx.wait();
  console.log("Authorized HiloBonding, HiloPredictionMarket, and poolCreator in HiloStaking");

  tx = await hiloBonding.updateAuthorizedAddress(hiloPredictionMarket.target, true);
  await tx.wait();
  tx = await hiloBonding.updateAuthorizedAddress(deployer.address, true);
  await tx.wait();
  console.log("Authorized HiloPredictionMarket and deployer in HiloBonding");

  // Fund staking contract
  await deployer.sendTransaction({ to: hiloStaking.target, value: ethers.parseEther("10") });
  console.log("Added 10 ETH to staking contract for rewards");
  
  // Save ABIs and contract configuration to build directory
  try {
    // Get ABIs from contract factories
    const mockTokenABI = MockERC20.interface.formatJson();
    const hiloStakingABI = HiloStaking.interface.formatJson();
    const hiloBondingABI = HiloBonding.interface.formatJson();
    const hiloPredictionMarketABI = HiloPredictionMarket.interface.formatJson();
    
    // Save ABIs
    fs.writeFileSync(path.join(buildDir, "MockERC20.json"), mockTokenABI);
    fs.writeFileSync(path.join(buildDir, "HiloStaking.json"), hiloStakingABI);
    fs.writeFileSync(path.join(buildDir, "HiloBonding.json"), hiloBondingABI);
    fs.writeFileSync(path.join(buildDir, "HiloPredictionMarket.json"), hiloPredictionMarketABI);
    
    // Save contract configurations
    const contractConfig = {
      staking: {
        validatorThreshold: ethers.formatEther(validatorThreshold),
        poolCreatorThreshold: ethers.formatEther(poolCreatorThreshold),
        evaluatorThreshold: ethers.formatEther(evaluatorThreshold)
      },
      bonding: {
        evaluationDuration: EVALUATION_DURATION,
        optionVotingDuration: OPTION_VOTING_DURATION,
        disputeDuration: DISPUTE_DURATION,
        autoUnfreezeDelay: AUTO_UNFREEZE_DELAY,
        falseEvalPenalty: ethers.formatEther(FALSE_EVAL_PENALTY),
        trueEvalReward: ethers.formatEther(TRUE_EVAL_REWARD),
        trueDisputeReward: ethers.formatEther(TRUE_DISPUTE_REWARD),
        falseDisputePenalty: ethers.formatEther(FALSE_DISPUTE_PENALTY),
        goodPoolReward: ethers.formatEther(GOOD_POOL_REWARD),
        badPoolPenalty: ethers.formatEther(BAD_POOL_PENALTY),
        minVotesRequired: MIN_VOTES_REQUIRED,
        poolCreationFee: ethers.formatEther(POOL_CREATION_FEE),
        initialPerOptionCap: INITIAL_PER_OPTION_CAP,
        maxVoteDifference: MAX_VOTE_DIFFERENCE
      },
      predictionMarket: {
        defaultLiquidity: ethers.formatEther(DEFAULT_LIQUIDITY),
        defaultLiquidityEnabled: true,
        initialFund: ethers.formatEther(LIQUIDITY_FUND),
      }
    };
    
    fs.writeFileSync(
      path.join(buildDir, "config.json"),
      JSON.stringify(contractConfig, null, 2)
    );
    
    console.log("Saved contract ABIs and configuration to build directory");
  } catch (error) {
    console.error("Error saving ABIs and configuration:", error);
  }

  // Transfer tokens to validators
  await mockToken.transfer(validator2.address, ethers.parseEther("100"));
  await mockToken.transfer(validator3.address, ethers.parseEther("100"));
  console.log("Transferred 100 tokens to each validator");

  // Helper function to check and log pool phase
  async function logPoolPhase(poolId, label) {
    console.log(`\n---- POOL PHASE CHECK: ${label} ----`);
    
    // Get basics
    const basics = await hiloBonding.getPoolBasics(poolId);
    console.log("Creator:", basics[0]);
    console.log("Start timeframe:", Number(basics[2]));
    
    // Get timelines
    const timelines = await hiloBonding.getPoolTimelines(poolId);
    const currentBlock = await provider.getBlock("latest");
    console.log("Current time:", currentBlock.timestamp);
    console.log("Evaluation phase:", Number(timelines[0]), "-", Number(timelines[1]));
    console.log("Option voting phase:", Number(timelines[2]), "-", Number(timelines[3]));
    console.log("Dispute phase end:", Number(timelines[4]));
    
    // Check where we are in the timeline
    const now = currentBlock.timestamp;
    let currentPhase = "Unknown";
    if (now < Number(timelines[0])) {
      currentPhase = "Pre-Evaluation";
    } else if (now >= Number(timelines[0]) && now <= Number(timelines[1])) {
      currentPhase = "Evaluation";
    } else if (now > Number(timelines[1]) && now < Number(timelines[2])) {
      currentPhase = "Between Evaluation and Option Voting";
    } else if (now >= Number(timelines[2]) && now <= Number(timelines[3])) {
      currentPhase = "Option Voting";
    } else if (now > Number(timelines[3]) && now <= Number(timelines[4])) {
      currentPhase = "Dispute";
    } else if (now > Number(timelines[4])) {
      currentPhase = "Post-Dispute";
    }
    console.log("Current phase based on time:", currentPhase);
    
    // Get evaluation status - THIS IS THE IMPORTANT PART WE MODIFIED
    const evalStatus = await hiloBonding.getPoolEvaluationStatus(poolId);
    console.log("Evaluation status:");
    console.log("  Complete:", evalStatus[0]);
    console.log("  Approved:", evalStatus[1]);
    console.log("  Approve votes:", Number(evalStatus[2]));
    console.log("  Reject votes:", Number(evalStatus[3]));
    console.log("  Approve dispute votes:", Number(evalStatus[4]));
    console.log("  Reject dispute votes:", Number(evalStatus[5]));
    
    // Get pool status
    const poolStatus = await hiloBonding.getPoolStatus(poolId);
    console.log("Pool status:");
    console.log("  Processed:", poolStatus[0]);
    console.log("  Processed time:", Number(poolStatus[1]));
    console.log("  Final approval:", poolStatus[2]);
    console.log("  Dispute round:", poolStatus[3]);
    console.log("  Winning option index:", Number(poolStatus[4]));
    
    console.log("----------------------------------------\n");
  }

  // Helper function to wait for a specific time
  async function waitUntil(targetTime) {
    const currentTime = (await provider.getBlock("latest")).timestamp;
    const timeToWait = Math.max(0, targetTime - currentTime);
    
    if (timeToWait > 0) {
      console.log(`Waiting ${timeToWait} seconds...`);
      await new Promise(resolve => setTimeout(resolve, timeToWait * 1000));
    }
  }

  // New helper function for placing bets with minOdds = 0
  async function placeBet(user, optionGroupId, optionIndex, amount) {
    const minOdds = 0; // Accept any odds
    await mockToken.connect(user).approve(hiloPredictionMarket.target, amount);
    const tx = await hiloPredictionMarket.connect(user).placeBet(
      optionGroupId, 
      optionIndex, 
      amount, 
      minOdds
    );
    await tx.wait();
    console.log(`User ${user.address} placed bet of ${ethers.formatEther(amount)} tokens on option ${optionIndex} in group ${optionGroupId}`);
    
    // Get potential return for this bet
    const betDetails = await hiloPredictionMarket.calculatePotentialReturn(optionGroupId, optionIndex, amount);
    console.log(`Potential return: ${ethers.formatEther(betDetails[0])} tokens, Odds: ${betDetails[1]}`);
  }

  // ----------------------
  // CREATE POOLS
  // ----------------------
  
  // Create a regular pool and a zero-vote pool for comparison
  const regularPoolId = Math.floor(Date.now() / 1000); // Unique ID
  const regularOptionGroupId = regularPoolId * 100 + 1;
  
  const zeroVotePoolId = regularPoolId + 1; // Another unique ID
  const zeroVoteOptionGroupId = zeroVotePoolId * 100 + 1;
  
  // Create a no-liquidity pool to test betting with no initial liquidity
  const noLiquidityPoolId = regularPoolId + 2; // Another unique ID
  const noLiquidityOptionGroupId = noLiquidityPoolId * 100 + 1;
  
  const currentTimestamp = (await provider.getBlock("latest")).timestamp;
  const poolStartTime = currentTimestamp + 60; // Start in 1 minute
  const poolSettleTime = poolStartTime + 300; // 5 minutes after start
  
  const optionNames = ["Option A", "Option B"];

  console.log("\n=== Creating Regular Pool ===");
  tx = await hiloPredictionMarket.connect(poolCreator).createPoolAndOptionGroup(
    regularPoolId,
    regularOptionGroupId,
    "Regular Test Pool",
    poolStartTime,
    poolSettleTime,
    "Regular pool with votes",
    optionNames
  );
  await tx.wait();
  console.log("Regular pool created");

  console.log("\n=== Creating Zero-Vote Pool ===");
  tx = await hiloPredictionMarket.connect(poolCreator).createPoolAndOptionGroup(
    zeroVotePoolId,
    zeroVoteOptionGroupId,
    "Zero-Vote Test Pool",
    poolStartTime,
    poolSettleTime,
    "Zero-vote pool for testing",
    optionNames
  );
  await tx.wait();
  console.log("Zero-vote pool created");

  console.log("\n=== Creating No-Liquidity Pool ===");
  tx = await hiloPredictionMarket.connect(poolCreator).createPoolAndOptionGroup(
    noLiquidityPoolId,
    noLiquidityOptionGroupId,
    "No-Liquidity Test Pool",
    poolStartTime,
    poolSettleTime,
    "Pool for testing betting with no initial liquidity",
    optionNames
  );
  await tx.wait();
  console.log("No-liquidity pool created");

  // Check if auto-liquidity was added
  const regularLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(regularOptionGroupId);
  const zeroVoteLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(zeroVoteOptionGroupId);
  const noLiquidityPoolLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(noLiquidityOptionGroupId);
  
  console.log("\n=== Liquidity Check After Pool Creation ===");
  console.log(`Regular pool liquidity: ${ethers.formatEther(regularLiquidity)} tokens`);
  console.log(`Zero-vote pool liquidity: ${ethers.formatEther(zeroVoteLiquidity)} tokens`);
  console.log(`No-liquidity pool liquidity: ${ethers.formatEther(noLiquidityPoolLiquidity)} tokens`);
  
  // Add manual liquidity to pools if auto-liquidity didn't work
  if (regularLiquidity.toString() === "0") {
    console.log("\n=== Adding Manual Liquidity to Pools ===");
    
    // Check if default liquidity is enabled
    const defaultLiquidityEnabled = await hiloPredictionMarket.defaultLiquidityEnabled();
    console.log(`Default liquidity enabled: ${defaultLiquidityEnabled}`);
    const defaultAmount = await hiloPredictionMarket.defaultLiquidityAmount();
    console.log(`Default liquidity amount: ${ethers.formatEther(defaultAmount)} tokens`);
    
    // Try enabling default liquidity if it's not enabled
    if (!defaultLiquidityEnabled) {
      console.log("Default liquidity not enabled, enabling it now");
      tx = await hiloPredictionMarket.configureDefaultLiquidity(true, DEFAULT_LIQUIDITY);
      await tx.wait();
      console.log(`Configured default liquidity: Enabled with ${ethers.formatEther(DEFAULT_LIQUIDITY)} tokens per pool`);
    }
    
    // Check contract balance
    const contractBalance = await mockToken.balanceOf(hiloPredictionMarket.target);
    console.log(`Prediction market token balance: ${ethers.formatEther(contractBalance)} tokens`);
    
    // If needed, add manual liquidity
    if (contractBalance < DEFAULT_LIQUIDITY) {
      console.log("Adding more tokens to prediction market contract");
      tx = await mockToken.transfer(hiloPredictionMarket.target, DEFAULT_LIQUIDITY * 5n);
      await tx.wait();
    }
    
    // Approve tokens for the prediction market
    const manualLiquidity = ethers.parseEther("100");
    await mockToken.connect(poolCreator).approve(hiloPredictionMarket.target, ethers.parseEther("500"));
    
    // Add liquidity to regular pool
    tx = await hiloPredictionMarket.connect(poolCreator).addLiquidity(regularOptionGroupId, manualLiquidity);
    await tx.wait();
    console.log(`Manually added ${ethers.formatEther(manualLiquidity)} tokens to regular pool`);
    
    // Add liquidity to zero-vote pool
    tx = await hiloPredictionMarket.connect(poolCreator).addLiquidity(zeroVoteOptionGroupId, manualLiquidity);
    await tx.wait();
    console.log(`Manually added ${ethers.formatEther(manualLiquidity)} tokens to zero-vote pool`);
    
    // Add liquidity to no-liquidity pool (contradictory but needed for testing)
    tx = await hiloPredictionMarket.connect(poolCreator).addLiquidity(noLiquidityOptionGroupId, manualLiquidity);
    await tx.wait();
    console.log(`Manually added ${ethers.formatEther(manualLiquidity)} tokens to no-liquidity pool`);
    
    // Check liquidity again
    const regularLiquidityAfter = await hiloPredictionMarket.calculateRemainingLiquidity(regularOptionGroupId);
    const zeroVoteLiquidityAfter = await hiloPredictionMarket.calculateRemainingLiquidity(zeroVoteOptionGroupId);
    const noLiquidityPoolLiquidityAfter = await hiloPredictionMarket.calculateRemainingLiquidity(noLiquidityOptionGroupId);
    
    console.log("\n=== Liquidity Check After Manual Addition ===");
    console.log(`Regular pool liquidity: ${ethers.formatEther(regularLiquidityAfter)} tokens`);
    console.log(`Zero-vote pool liquidity: ${ethers.formatEther(zeroVoteLiquidityAfter)} tokens`);
    console.log(`No-liquidity pool liquidity: ${ethers.formatEther(noLiquidityPoolLiquidityAfter)} tokens`);
  }

  // ----------------------
  // EVALUATION PHASE
  // ----------------------
  
  // Log initial status of all pools
  await logPoolPhase(regularPoolId, "Regular Pool After Creation");
  await logPoolPhase(zeroVotePoolId, "Zero-Vote Pool After Creation");
  await logPoolPhase(noLiquidityPoolId, "No-Liquidity Pool After Creation");
  
  // Cast evaluation votes for regular pool and no-liquidity pool only
  console.log("\n=== Casting Evaluation Votes (Regular Pool and No-Liquidity Pool) ===");
  
  tx = await hiloBonding.connect(validator1).voteEvaluation(regularPoolId, true);
  await tx.wait();
  console.log("Validator 1 cast YES vote for regular pool");
  
  tx = await hiloBonding.connect(validator2).voteEvaluation(regularPoolId, true);
  await tx.wait();
  console.log("Validator 2 cast YES vote for regular pool");

  tx = await hiloBonding.connect(validator1).voteEvaluation(noLiquidityPoolId, true);
  await tx.wait();
  console.log("Validator 1 cast YES vote for no-liquidity pool");
  
  tx = await hiloBonding.connect(validator2).voteEvaluation(noLiquidityPoolId, true);
  await tx.wait();
  console.log("Validator 2 cast YES vote for no-liquidity pool");
  
  // Log status after votes
  await logPoolPhase(regularPoolId, "Regular Pool After Votes");
  await logPoolPhase(zeroVotePoolId, "Zero-Vote Pool (No Votes)");
  await logPoolPhase(noLiquidityPoolId, "No-Liquidity Pool After Votes");
  
  // Wait for pool to start
  console.log("\n=== Waiting for Pool Start ===");
  await waitUntil(poolStartTime + 5);
  
  // Log status after start
  await logPoolPhase(regularPoolId, "Regular Pool After Start");
  await logPoolPhase(zeroVotePoolId, "Zero-Vote Pool After Start");
  await logPoolPhase(noLiquidityPoolId, "No-Liquidity Pool After Start");
  
  // ----------------------
  // TESTING BETTING PHASE
  // ----------------------
  
  console.log("\n=== Testing Betting on Each Pool Type ===");
  
  // Regular pool bet
  console.log("\n- Regular Pool Betting Test -");
  try {
    await placeBet(validator2, regularOptionGroupId, 0, ethers.parseEther("10"));
    console.log("Successfully placed bet on regular pool");
  } catch (error) {
    console.error("Error placing bet on regular pool:", error.message);
  }
  
  // Zero-vote pool - betting should fail since evaluation wasn't approved
  console.log("\n- Zero-Vote Pool Betting Test -");
  try {
    await placeBet(validator2, zeroVoteOptionGroupId, 0, ethers.parseEther("10"));
    console.log("WARNING: Bet on zero-vote pool succeeded unexpectedly");
  } catch (error) {
    console.log("Bet on zero-vote pool failed as expected:", error.message.substring(0, 100) + "...");
  }
  
  // No-liquidity pool - special case for bootstrapping liquidity
  console.log("\n- No-Liquidity Pool Betting Test -");
  try {
    // First bet when no liquidity - should bootstrap the market
    await placeBet(validator3, noLiquidityOptionGroupId, 0, ethers.parseEther("5"));
    console.log("Successfully placed first bet on no-liquidity pool (bootstrapping liquidity)");
    
    // Additional bet to verify market is operating after bootstrap
    await placeBet(validator2, noLiquidityOptionGroupId, 1, ethers.parseEther("10"));
    console.log("Successfully placed second bet on no-liquidity pool");
  } catch (error) {
    console.error("Error placing bet on no-liquidity pool:", error.message);
  }

  // ----------------------
  // WAIT FOR EVALUATION PERIOD TO END
  // ----------------------
  
  // Get evaluation end time for regular pool
  const regularTimelines = await hiloBonding.getPoolTimelines(regularPoolId);
  const evalEndTime = Number(regularTimelines[1]) + 10; // Add buffer
  
  console.log(`\n=== Waiting for Evaluation Period to End (${evalEndTime - (await provider.getBlock("latest")).timestamp} seconds) ===`);
  await waitUntil(evalEndTime);
  
  // Log status after evaluation end - THIS IS THE KEY TEST OF OUR FIX
  // The status should show both pools as "Complete" but different approval status
  console.log("\n=== Testing Evaluation Status After Evaluation Period Ends ===");
  await logPoolPhase(regularPoolId, "Regular Pool After Evaluation End");
  await logPoolPhase(zeroVotePoolId, "Zero-Vote Pool After Evaluation End");
  await logPoolPhase(noLiquidityPoolId, "No-Liquidity Pool After Evaluation End");
  
  // Explicitly check all pools
  const regularEvalStatus = await hiloBonding.getPoolEvaluationStatus(regularPoolId);
  const zeroVoteEvalStatus = await hiloBonding.getPoolEvaluationStatus(zeroVotePoolId);
  const noLiquidityEvalStatus = await hiloBonding.getPoolEvaluationStatus(noLiquidityPoolId);
  
  console.log("\n=== Direct Evaluation Status Comparison ===");
  console.log("Regular Pool:");
  console.log("  Complete:", regularEvalStatus[0]);
  console.log("  Approved:", regularEvalStatus[1]);
  console.log("  Approve Votes:", Number(regularEvalStatus[2]));
  
  console.log("Zero-Vote Pool:");
  console.log("  Complete:", zeroVoteEvalStatus[0]);
  console.log("  Approved:", zeroVoteEvalStatus[1]);
  console.log("  Approve Votes:", Number(zeroVoteEvalStatus[2]));
  
  console.log("No-Liquidity Pool:");
  console.log("  Complete:", noLiquidityEvalStatus[0]);
  console.log("  Approved:", noLiquidityEvalStatus[1]);
  console.log("  Approve Votes:", Number(noLiquidityEvalStatus[2]));
  
  // ----------------------
  // OPTION VOTING PHASE
  // ----------------------
  
  // Wait for option voting to start
  console.log("\n=== Waiting for Option Voting to Start ===");
  await waitUntil(Number(regularTimelines[2]) + 5);
  
  // Log status at option voting start
  await logPoolPhase(regularPoolId, "Regular Pool at Option Voting Start");
  await logPoolPhase(zeroVotePoolId, "Zero-Vote Pool at Option Voting Start");
  await logPoolPhase(noLiquidityPoolId, "No-Liquidity Pool at Option Voting Start");
  
  // Cast option votes for regular pool
  console.log("\n=== Casting Option Votes ===");
  
  // Vote for regular pool
  tx = await hiloBonding.connect(validator1).voteOption(regularPoolId, 0); // Vote for option A
  await tx.wait();
  console.log("Validator 1 voted for Option A in regular pool");
  
  // Vote for no-liquidity pool
  tx = await hiloBonding.connect(validator1).voteOption(noLiquidityPoolId, 0); // Vote for option A
  await tx.wait();
  console.log("Validator 1 voted for Option A in no-liquidity pool");
  
  // Try to vote on zero-vote pool (should fail)
  try {
    tx = await hiloBonding.connect(validator1).voteOption(zeroVotePoolId, 0);
    await tx.wait();
    console.log("WARNING: Vote on zero-vote pool succeeded unexpectedly");
  } catch (error) {
    console.log("Vote on zero-vote pool failed as expected:", error.message.substring(0, 100) + "...");
  }

  // ----------------------
  // TEST LIQUIDITY PROVIDER FUNCTIONS
  // ----------------------
  
  console.log("\n=== Testing Liquidity Provider Functions ===");
  
  // Direct liquidity provider testing
  console.log("\n=== Testing Direct Liquidity Provider Functions ===");
  
  // Create a special pool for testing the liquidity provider directly
  const lpTestPoolId = regularPoolId + 10;
  const lpTestOptionGroupId = lpTestPoolId * 100 + 1;
  
  // Create test pool
  tx = await hiloPredictionMarket.connect(poolCreator).createPoolAndOptionGroup(
    lpTestPoolId,
    lpTestOptionGroupId,
    "Liquidity Provider Test Pool",
    poolStartTime,
    poolSettleTime,
    "Pool for testing liquidity provider direct calls",
    optionNames
  );
  await tx.wait();
  console.log("Liquidity provider test pool created");
  
  // Check if liquidity was auto-added
  const lpTestInitialLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(lpTestOptionGroupId);
  console.log(`Initial liquidity in test pool: ${ethers.formatEther(lpTestInitialLiquidity)} tokens`);
  
  // Make direct call to add liquidity via prediction market
  console.log("Calling prediction market directly to add liquidity");
  await mockToken.connect(deployer).approve(hiloPredictionMarket.target, ethers.parseEther("200"));
  tx = await hiloPredictionMarket.connect(deployer).addLiquidity(lpTestOptionGroupId, ethers.parseEther("100"));
  await tx.wait();
  console.log("Called addLiquidity directly");
  
  // Check liquidity after direct call
  const lpTestFinalLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(lpTestOptionGroupId);
  console.log(`Final liquidity in test pool: ${ethers.formatEther(lpTestFinalLiquidity)} tokens`);
  
  // Check the funding status
  console.log("Prediction market funding status:");
  const contractBalance = await mockToken.balanceOf(hiloPredictionMarket.target);
  console.log(`Contract balance: ${ethers.formatEther(contractBalance)} tokens`);
  
  // Debug prediction market status
  const defaultLiquidityEnabled = await hiloPredictionMarket.defaultLiquidityEnabled();
  console.log(`Default liquidity enabled: ${defaultLiquidityEnabled}`);
  const defaultAmount = await hiloPredictionMarket.defaultLiquidityAmount();
  console.log(`Default liquidity amount: ${ethers.formatEther(defaultAmount)} tokens`);
  const pmBalance = await mockToken.balanceOf(hiloPredictionMarket.target);
  console.log(`Prediction market token balance: ${ethers.formatEther(pmBalance)} tokens`);

  // Continue monitoring through rest of lifecycle
  // This is a simplified script, but you could extend to track dispute phase, processing, etc.
  
  console.log("\n=== Lifecycle Tracking Test Complete ===");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error in deployment script:", error);
    process.exit(1);
  });