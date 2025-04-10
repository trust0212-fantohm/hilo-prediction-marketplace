const { expect } = require("chai");
const { ethers, network } = require("hardhat");

describe("HiloPredictionMarket with DefaultLiquidityProvider", function () {
  // Define signers and contracts
  let owner, poolCreator, validator1, validator2, user1, user2;
  let hiloStaking, hiloBonding, hiloPredictionMarket, liquidityProviderContract, mockToken;

  // Constants
  const VALIDATOR_THRESHOLD = ethers.parseEther("1");
  const POOL_CREATOR_THRESHOLD = ethers.parseEther("2");
  const EVALUATOR_THRESHOLD = ethers.parseEther("0.5");
  const INITIAL_TOKEN_SUPPLY = ethers.parseEther("1000000");
  const INITIAL_USER_TOKENS = ethers.parseEther("10000");
  const DEFAULT_LIQUIDITY = ethers.parseEther("100");
  const PRECISION = 10000;

  // Test parameters
  let poolId, optionGroupId;
  let currentTime;

  // Helper function to safely increment time
  async function safeIncrementTime(targetTime) {
    const latestBlock = await ethers.provider.getBlock("latest");
    currentTime = Math.max(latestBlock.timestamp + 1, targetTime);
    await network.provider.send("evm_setNextBlockTimestamp", [currentTime]);
    await network.provider.send("evm_mine");
    return currentTime;
  }

  // Helper function to format BigInt to a string with proper decimal places
  function formatBigInt(value, decimals = 4) {
    return (Number(ethers.formatEther(value))).toFixed(decimals);
  }

  // Print the odds for all options in a pool
  async function printOdds(optionGroupId, message = "Current odds") {
    const options = await hiloPredictionMarket.getOptionNames(optionGroupId);
    console.log(`\n${message}:`);
    
    for (let i = 0; i < options.length; i++) {
      const odds = await hiloPredictionMarket.getOdds(optionGroupId, i);
      console.log(`- ${options[i]}: ${(Number(odds) / PRECISION).toFixed(4)}x`);
    }
  }

  // Print liquidity status
  async function printLiquidity(optionGroupId, message = "Current liquidity") {
    const currentLiquidity = await hiloPredictionMarket.getCurrentLiquidity(optionGroupId);
    const totalLiquidity = await hiloPredictionMarket.calculateRemainingLiquidity(optionGroupId);
    
    console.log(`\n${message}:`);
    console.log(`- Total liquidity: ${formatBigInt(totalLiquidity)}`);
    
    const options = await hiloPredictionMarket.getOptionNames(optionGroupId);
    for (let i = 0; i < options.length; i++) {
      console.log(`- ${options[i]}: ${formatBigInt(currentLiquidity[i])}`);
    }
  }

  before(async function () {
    this.timeout(100000);
    [owner, poolCreator, validator1, validator2, user1, user2] = await ethers.getSigners();

    console.log("Deploying contracts...");

    // Deploy ERC20 token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20.deploy("Hilo Test Token", "HTT", INITIAL_TOKEN_SUPPLY);
    await mockToken.waitForDeployment();

    // Deploy HiloStaking
    const HiloStaking = await ethers.getContractFactory("HiloStaking");
    hiloStaking = await HiloStaking.deploy(VALIDATOR_THRESHOLD, POOL_CREATOR_THRESHOLD, EVALUATOR_THRESHOLD);
    await hiloStaking.waitForDeployment();

    // Deploy HiloBonding
    const configValues = [
      60 * 60 * 24, // EVALUATION_DURATION: 1 day
      60 * 60 * 24, // OPTION_VOTING_DURATION: 1 day
      60 * 60 * 12, // DISPUTE_DURATION: 12 hours
      60 * 60 * 6,  // AUTO_UNFREEZE_DELAY: 6 hours
      ethers.parseEther("0.1"),  // FALSE_EVAL_PENALTY
      ethers.parseEther("0.05"), // TRUE_EVAL_REWARD
      ethers.parseEther("0.1"),  // TRUE_DISPUTE_REWARD
      ethers.parseEther("0.15"), // FALSE_DISPUTE_PENALTY
      ethers.parseEther("0.2"),  // GOOD_POOL_REWARD
      ethers.parseEther("0.3"),  // BAD_POOL_PENALTY
      2,                        // MIN_VOTES_REQUIRED
      ethers.parseEther("0"),   // POOL_CREATION_FEE
      5,                        // INITIAL_PER_OPTION_CAP
      3                         // MAX_VOTE_DIFFERENCE
    ];

    const HiloBonding = await ethers.getContractFactory("HiloBonding");
    hiloBonding = await HiloBonding.deploy(await hiloStaking.getAddress(), configValues);
    await hiloBonding.waitForDeployment();

    // Deploy HiloPredictionMarket
    const HiloPredictionMarket = await ethers.getContractFactory("HiloPredictionMarket");
    hiloPredictionMarket = await HiloPredictionMarket.deploy(
      await hiloBonding.getAddress(),
      await hiloStaking.getAddress(),
      await mockToken.getAddress()
    );
    await hiloPredictionMarket.waitForDeployment();

    // Deploy LiquidityProvider
    const LiquidityProvider = await ethers.getContractFactory("HiloDefaultLiquidityProvider");
    liquidityProviderContract = await LiquidityProvider.deploy(
      await hiloPredictionMarket.getAddress(), 
      await mockToken.getAddress()
    );
    await liquidityProviderContract.waitForDeployment();

    // Setup authorizations
    await hiloStaking.connect(owner).updateAuthorizedAddress(await hiloBonding.getAddress(), true);
    await hiloStaking.connect(owner).updateAuthorizedAddress(await hiloPredictionMarket.getAddress(), true);
    await hiloBonding.updateAuthorizedAddress(await hiloPredictionMarket.getAddress(), true);

    // Buy roles
    await hiloStaking.connect(poolCreator).buyPoolCreator({ value: POOL_CREATOR_THRESHOLD });
    await hiloStaking.connect(validator1).buyValidator({ value: VALIDATOR_THRESHOLD });
    await hiloStaking.connect(validator2).buyValidator({ value: VALIDATOR_THRESHOLD });

    // Setup tokens
    await mockToken.transfer(user1.address, INITIAL_USER_TOKENS);
    await mockToken.transfer(user2.address, INITIAL_USER_TOKENS);
    await mockToken.transfer(poolCreator.address, INITIAL_USER_TOKENS);
    await mockToken.connect(user1).approve(await hiloPredictionMarket.getAddress(), ethers.MaxUint256);
    await mockToken.connect(user2).approve(await hiloPredictionMarket.getAddress(), ethers.MaxUint256);
    await mockToken.connect(poolCreator).approve(await hiloPredictionMarket.getAddress(), ethers.MaxUint256);

    // Connect HiloPredictionMarket with LiquidityProvider
    await hiloPredictionMarket.connect(owner).setLiquidityProvider(
      await liquidityProviderContract.getAddress(),
      true // Enable default liquidity
    );

    console.log("Contracts deployed successfully");
  });

  it("should fund the liquidity provider contract", async function () {
    // Transfer tokens to the liquidity provider contract
    const fundAmount = DEFAULT_LIQUIDITY.mul(5); // Fund enough for 5 pools
    await mockToken.transfer(await liquidityProviderContract.getAddress(), fundAmount);
    
    const lpBalance = await mockToken.balanceOf(await liquidityProviderContract.getAddress());
    console.log(`Liquidity provider balance: ${formatBigInt(lpBalance)}`);
    
    expect(lpBalance).to.equal(fundAmount);
  });

  it("should create a pool with automatic liquidity provision", async function () {
    // Get the current block time and set future timestamps
    const block = await ethers.provider.getBlock("latest");
    const startTimeframe = block.timestamp + 60; // 1 minute in the future
    const settleTimeframe = startTimeframe + (3600 * 24 * 2); // 2 days after start
    
    // Generate unique IDs
    poolId = Math.floor(Math.random() * 1000000);
    optionGroupId = Math.floor(Math.random() * 1000000);
    
    console.log(`Creating test pool with ID: ${poolId}, optionGroupId: ${optionGroupId}`);
    
    // Create pool with binary options
    const optionNames = ["Yes", "No"];
    
    // Create the pool and option group
    const tx = await hiloPredictionMarket.connect(poolCreator).createPoolAndOptionGroup(
      poolId,
      optionGroupId,
      "Automatic Liquidity Test Pool",
      startTimeframe,
      settleTimeframe,
      "Testing automatic liquidity provision",
      optionNames
    );
    
    await tx.wait();
    console.log("Pool and option group created");
    
    // Check if liquidity was automatically added
    const liquidityProvided = await hiloPredictionMarket.getLiquidityProvidedByAddress(
      optionGroupId,
      await liquidityProviderContract.getAddress()
    );
    
    console.log(`Automatically provided liquidity: ${formatBigInt(liquidityProvided)}`);
    expect(liquidityProvided).to.equal(DEFAULT_LIQUIDITY);
    
    // Check liquidity distribution
    await printLiquidity(optionGroupId, "Initial liquidity distribution");
    
    // Check initial odds
    await printOdds(optionGroupId, "Initial odds");
    
    // Verify binary pool has approximately 2.0x odds on both sides
    const yesOdds = await hiloPredictionMarket.getOdds(optionGroupId, 0);
    const noOdds = await hiloPredictionMarket.getOdds(optionGroupId, 1);
    
    expect(Math.abs(Number(yesOdds) / PRECISION - 2.0)).to.be.lt(0.1);
    expect(Math.abs(Number(noOdds) / PRECISION - 2.0)).to.be.lt(0.1);
    
    // Approve pool through validators
    await hiloBonding.connect(validator1).voteEvaluation(poolId, true);
    await hiloBonding.connect(validator2).voteEvaluation(poolId, true);
    
    // Move time to after start time to allow betting
    await safeIncrementTime(startTimeframe + 10);
    console.log("Time advanced to after pool start. Betting is now allowed.");
  });

  it("should place multiple bets on both sides and track odds changes", async function () {
    // User1 bets on Yes
    const user1BetAmount = ethers.parseEther("10");
    await hiloPredictionMarket.connect(user1).placeBet(
      optionGroupId,
      0, // Yes
      user1BetAmount,
      1 // minOdds
    );
    
    console.log(`User1 bet ${formatBigInt(user1BetAmount)} tokens on Yes`);
    await printOdds(optionGroupId, "Odds after User1 bet on Yes");
    await printLiquidity(optionGroupId, "Liquidity after User1 bet on Yes");
    
    // User2 bets on No
    const user2BetAmount = ethers.parseEther("15");
    await hiloPredictionMarket.connect(user2).placeBet(
      optionGroupId,
      1, // No
      user2BetAmount,
      1 // minOdds
    );
    
    console.log(`User2 bet ${formatBigInt(user2BetAmount)} tokens on No`);
    await printOdds(optionGroupId, "Odds after User2 bet on No");
    await printLiquidity(optionGroupId, "Liquidity after User2 bet on No");
    
    // User1 bets again on Yes
    const user1SecondBetAmount = ethers.parseEther("5");
    await hiloPredictionMarket.connect(user1).placeBet(
      optionGroupId,
      0, // Yes
      user1SecondBetAmount,
      1 // minOdds
    );
    
    console.log(`User1 bet another ${formatBigInt(user1SecondBetAmount)} tokens on Yes`);
    await printOdds(optionGroupId, "Odds after User1's second bet on Yes");
    await printLiquidity(optionGroupId, "Liquidity after User1's second bet on Yes");
    
    // Check user positions
    const user1Position = await hiloPredictionMarket.GetPoolPositionResults(optionGroupId, user1.address);
    const user2Position = await hiloPredictionMarket.GetPoolPositionResults(optionGroupId, user2.address);
    
    console.log(`\nUser1 position:`);
    console.log(`- Yes bet: ${formatBigInt(user1Position[3][0])}`);
    console.log(`- No bet: ${formatBigInt(user1Position[3][1])}`);
    console.log(`- Potential return on Yes: ${formatBigInt(user1Position[4][0])}`);
    
    console.log(`\nUser2 position:`);
    console.log(`- Yes bet: ${formatBigInt(user2Position[3][0])}`);
    console.log(`- No bet: ${formatBigInt(user2Position[3][1])}`);
    console.log(`- Potential return on No: ${formatBigInt(user2Position[4][1])}`);
    
    // Verify total bets
    const totalBets = await hiloPredictionMarket.getTotalBetsPerOption(optionGroupId);
    const expectedYesBets = user1BetAmount.add(user1SecondBetAmount);
    const expectedNoBets = user2BetAmount;
    
    expect(totalBets[0]).to.equal(expectedYesBets);
    expect(totalBets[1]).to.equal(expectedNoBets);
  });

  it("should allow early exits and recalculate liquidity and odds", async function () {
    // Get initial state
    console.log("\n--- EARLY EXIT TEST ---");
    const initialBalanceUser1 = await mockToken.balanceOf(user1.address);
    console.log(`User1 initial balance: ${formatBigInt(initialBalanceUser1)}`);
    
    // Get User1's bet amount
    const user1YesBet = await hiloPredictionMarket.getUserBet(optionGroupId, user1.address, 0);
    console.log(`User1 current Yes bet: ${formatBigInt(user1YesBet)}`);
    
    // Check early exit details before exiting
    const exitDetails = await hiloPredictionMarket.connect(user1).getEarlyExitDetails(optionGroupId, 0);
    console.log(`\nEarly exit details for User1:`);
    console.log(`- Bet amount: ${formatBigInt(exitDetails[0])}`);
    console.log(`- Exit value before fees: ${formatBigInt(exitDetails[1])}`);
    console.log(`- Exit value after fees: ${formatBigInt(exitDetails[2])}`);
    
    // Calculate percentage of bet being returned
    const percentReturn = Number(exitDetails[2]) * 100 / Number(user1YesBet);
    console.log(`- Percentage of bet returned: ${percentReturn.toFixed(2)}%`);
    
    // Perform early exit for half the bet amount
    const exitAmount = user1YesBet.div(2);
    console.log(`\nUser1 exits half their Yes bet: ${formatBigInt(exitAmount)}`);
    
    await hiloPredictionMarket.connect(user1).earlyExit(
      optionGroupId,
      0, // Yes
      exitAmount
    );
    
    // Check balance after exit
    const afterExitBalanceUser1 = await mockToken.balanceOf(user1.address);
    const tokensReceived = afterExitBalanceUser1.sub(initialBalanceUser1);
    console.log(`User1 received ${formatBigInt(tokensReceived)} tokens from early exit`);
    
    // Check odds and liquidity after exit
    await printOdds(optionGroupId, "Odds after User1's early exit");
    await printLiquidity(optionGroupId, "Liquidity after User1's early exit");
    
    // Verify remaining bet amount
    const remainingBet = await hiloPredictionMarket.getUserBet(optionGroupId, user1.address, 0);
    console.log(`\nUser1 remaining Yes bet: ${formatBigInt(remainingBet)}`);
    expect(remainingBet).to.equal(user1YesBet.sub(exitAmount));
    
    // User2 exits their entire bet
    console.log("\n--- USER2 EARLY EXIT TEST ---");
    const initialBalanceUser2 = await mockToken.balanceOf(user2.address);
    console.log(`User2 initial balance: ${formatBigInt(initialBalanceUser2)}`);
    
    const user2NoBet = await hiloPredictionMarket.getUserBet(optionGroupId, user2.address, 1);
    console.log(`User2 current No bet: ${formatBigInt(user2NoBet)}`);
    
    const exitDetailsUser2 = await hiloPredictionMarket.connect(user2).getEarlyExitDetails(optionGroupId, 1);
    console.log(`\nEarly exit details for User2:`);
    console.log(`- Bet amount: ${formatBigInt(exitDetailsUser2[0])}`);
    console.log(`- Exit value before fees: ${formatBigInt(exitDetailsUser2[1])}`);
    console.log(`- Exit value after fees: ${formatBigInt(exitDetailsUser2[2])}`);
    
    // User2 exits their entire bet
    await hiloPredictionMarket.connect(user2).earlyExit(
      optionGroupId,
      1, // No
      user2NoBet
    );
    
    // Check balance after exit
    const afterExitBalanceUser2 = await mockToken.balanceOf(user2.address);
    const user2TokensReceived = afterExitBalanceUser2.sub(initialBalanceUser2);
    console.log(`User2 received ${formatBigInt(user2TokensReceived)} tokens from early exit`);
    
    // Check odds and liquidity after exit
    await printOdds(optionGroupId, "Odds after User2's early exit");
    await printLiquidity(optionGroupId, "Liquidity after User2's early exit");
    
    // Verify remaining bet amount
    const user2RemainingBet = await hiloPredictionMarket.getUserBet(optionGroupId, user2.address, 1);
    console.log(`\nUser2 remaining No bet: ${formatBigInt(user2RemainingBet)}`);
    expect(user2RemainingBet).to.equal(0);
    
    // Check final CPMM state
    console.log("\n--- FINAL CPMM STATE ---");
    await printOdds(optionGroupId, "Final odds");
    await printLiquidity(optionGroupId, "Final liquidity");
    
    // Verify CPMM constant is preserved
    const currentLiquidity = await hiloPredictionMarket.getCurrentLiquidity(optionGroupId);
    const constantK = currentLiquidity[0] * currentLiquidity[1];
    console.log(`\nCurrent CPMM constant (k = x * y): ${formatBigInt(constantK, 0)}`);
  });
});