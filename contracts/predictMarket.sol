// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title PredictionMarket
 * @dev Implementation of a prediction market using constant product formula with reserves
 *      Based on the Excel-matched formula system from the React implementation
 */
contract PredictionMarket {
    // Market structure to store all data for a single prediction market
    struct Market {
        uint256 id;
        string question;
        uint256 initialLiquidity;
        uint256 feePercentage;
        uint256 liquidityOption1; // Yes (X)
        uint256 liquidityOption2; // No (Y)
        uint256 totalBetsOption1;
        uint256 totalBetsOption2;
        uint256 reserveX; // Reserve for Option 1
        uint256 reserveY; // Reserve for Option 2
        bool isResolved;
        bool outcome; // true = Option1 (Yes) won, false = Option2 (No) won
        mapping(address => BetInfo[]) userBets;
    }

    // Bet information to track individual bets
    struct BetInfo {
        uint256 id;
        uint256 timestamp;
        bool isOption1;  // true = Yes, false = No
        uint256 amount;
        uint256 lockedOdds; // Scaled by PRECISION
        uint256 potentialPayout;
        bool claimed;
    }

    // Public data structure for returning bet info (without the 'claimed' flag)
    struct BetData {
        uint256 id;
        uint256 timestamp;
        bool isOption1;
        uint256 amount;
        uint256 lockedOdds;
        uint256 potentialPayout;
    }

    // Market metadata
    struct MarketInfo {
        uint256 id;
        string question;
        uint256 initialLiquidity;
        uint256 feePercentage;
        uint256 liquidityOption1;
        uint256 liquidityOption2;
        uint256 totalBetsOption1;
        uint256 totalBetsOption2;
        uint256 reserveX;
        uint256 reserveY;
        bool isResolved;
        bool outcome;
    }

    // Constants
    uint256 private constant PRECISION = 10000;
    uint256 private constant MAX_FEE = 1000; // 10% maximum fee
    uint256 private constant MIN_INITIAL_LIQUIDITY = 10;

    // State variables
    mapping(uint256 => Market) private markets;
    uint256 private marketCount;
    address private owner;
    
    // Events
    event MarketCreated(uint256 indexed marketId, string question, uint256 initialLiquidity, uint256 feePercentage);
    event BetPlaced(uint256 indexed marketId, address indexed bettor, bool isOption1, uint256 amount, uint256 lockedOdds, uint256 potentialPayout);
    event MarketResolved(uint256 indexed marketId, bool outcome);
    event PayoutClaimed(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event FeesCollected(uint256 indexed marketId, address indexed collector, uint256 amount);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier marketExists(uint256 marketId) {
        require(marketId > 0 && marketId <= marketCount, "Market does not exist");
        _;
    }

    modifier marketNotResolved(uint256 marketId) {
        require(!markets[marketId].isResolved, "Market already resolved");
        _;
    }

    modifier marketIsResolved(uint256 marketId) {
        require(markets[marketId].isResolved, "Market not resolved yet");
        _;
    }

    // Constructor
    constructor() {
        owner = msg.sender;
        marketCount = 0;
    }

    /**
     * @dev Create a new prediction market
     * @param question The prediction market question
     * @param initialLiquidity The initial liquidity to be provided for both options
     * @param feePercentage The fee percentage (scaled by 100, e.g., 5% = 500)
     */
    function createMarket(
        string memory question,
        uint256 initialLiquidity,
        uint256 feePercentage
    ) external {
        require(bytes(question).length > 0, "Question cannot be empty");
        require(initialLiquidity >= MIN_INITIAL_LIQUIDITY, "Initial liquidity too low");
        require(feePercentage <= MAX_FEE, "Fee percentage too high");

        marketCount++;
        uint256 marketId = marketCount;
        
        Market storage newMarket = markets[marketId];
        newMarket.id = marketId;
        newMarket.question = question;
        newMarket.initialLiquidity = initialLiquidity;
        newMarket.feePercentage = feePercentage;
        newMarket.liquidityOption1 = initialLiquidity;
        newMarket.liquidityOption2 = initialLiquidity;
        newMarket.totalBetsOption1 = 0;
        newMarket.totalBetsOption2 = 0;
        newMarket.reserveX = 0;
        newMarket.reserveY = 0;
        newMarket.isResolved = false;
        
        emit MarketCreated(marketId, question, initialLiquidity, feePercentage);
    }

    /**
     * @dev Place a bet on Option 1 (Yes)
     * @param marketId The ID of the market
     */
    function betOnOption1(uint256 marketId) 
        external 
        payable 
        marketExists(marketId) 
        marketNotResolved(marketId) 
    {
        require(msg.value > 0, "Bet amount must be greater than 0");
        
        Market storage market = markets[marketId];
        uint256 betAmount = msg.value;
        
        // Update total bets
        market.totalBetsOption1 += betAmount;
        
        // Calculate excess
        int256 excess1 = int256(market.totalBetsOption1) - int256(market.totalBetsOption2);
        int256 excess2 = int256(market.totalBetsOption2) - int256(market.totalBetsOption1);
        
        // Update liquidities according to Excel formula
        uint256 constantK = market.initialLiquidity * market.initialLiquidity;
        uint256 newLiquidityOption1;
        uint256 newLiquidityOption2;
        
        // For Yes bets, if No has excess (excess1 < 0), scale the bet
        if (excess1 < 0) {
            // Scale the bet by reserveX / |excess1|
            uint256 scaleFactor = (market.reserveX * PRECISION) / uint256(-excess1);
            uint256 scaledBet = (betAmount * scaleFactor) / PRECISION;
            
            newLiquidityOption1 = market.liquidityOption1 + scaledBet;
            newLiquidityOption2 = constantK / newLiquidityOption1;
        } else {
            // Standard formula when Yes has no excess or positive excess
            newLiquidityOption1 = market.liquidityOption1 + betAmount;
            newLiquidityOption2 = constantK / newLiquidityOption1;
        }
        
        // Calculate extraction and locked odds
        uint256 extractedFromOption2 = market.liquidityOption2 > newLiquidityOption2 ? 
            market.liquidityOption2 - newLiquidityOption2 : 0;
        
        uint256 extractionRatio = (extractedFromOption2 * PRECISION) / betAmount;
        uint256 feeMultiplier = PRECISION - market.feePercentage;
        uint256 lockedOdds = PRECISION + ((extractionRatio * feeMultiplier) / PRECISION);
        
        // Calculate potential payout and fees
        uint256 potentialPayout = (betAmount * lockedOdds) / PRECISION;
        
        // Update reserves according to Excel formula
        uint256 newReserveX = newLiquidityOption1 >= market.initialLiquidity ? 0 : 
            market.initialLiquidity - newLiquidityOption1;
        
        uint256 newReserveY = newLiquidityOption2 >= market.initialLiquidity ? 0 : 
            market.initialLiquidity - newLiquidityOption2;
        
        // Update market state
        market.liquidityOption1 = newLiquidityOption1;
        market.liquidityOption2 = newLiquidityOption2;
        market.reserveX = newReserveX;
        market.reserveY = newReserveY;
        
        // Record user bet
        BetInfo memory betInfo = BetInfo({
            id: market.userBets[msg.sender].length + 1,
            timestamp: block.timestamp,
            isOption1: true,
            amount: betAmount,
            lockedOdds: lockedOdds,
            potentialPayout: potentialPayout,
            claimed: false
        });
        
        market.userBets[msg.sender].push(betInfo);
        
        emit BetPlaced(marketId, msg.sender, true, betAmount, lockedOdds, potentialPayout);
    }

    /**
     * @dev Place a bet on Option 2 (No)
     * @param marketId The ID of the market
     */
    function betOnOption2(uint256 marketId) 
        external 
        payable 
        marketExists(marketId) 
        marketNotResolved(marketId) 
    {
        require(msg.value > 0, "Bet amount must be greater than 0");
        
        Market storage market = markets[marketId];
        uint256 betAmount = msg.value;
        
        // Update total bets
        market.totalBetsOption2 += betAmount;
        
        // Calculate excess
        int256 excess1 = int256(market.totalBetsOption1) - int256(market.totalBetsOption2);
        int256 excess2 = int256(market.totalBetsOption2) - int256(market.totalBetsOption1);
        
        // Update liquidities according to Excel formula
        uint256 constantK = market.initialLiquidity * market.initialLiquidity;
        uint256 newLiquidityOption1;
        uint256 newLiquidityOption2;
        
        // For No bets, if Yes has excess (excess1 > 0), scale the bet
        if (excess1 > 0) {
            // Scale the bet by reserveY / excess1
            uint256 scaleFactor = (market.reserveY * PRECISION) / uint256(excess1);
            uint256 scaledBet = (betAmount * scaleFactor) / PRECISION;
            
            newLiquidityOption2 = market.liquidityOption2 + scaledBet;
            newLiquidityOption1 = constantK / newLiquidityOption2;
        } else {
            // Standard formula when No has no excess or positive excess
            newLiquidityOption2 = market.liquidityOption2 + betAmount;
            newLiquidityOption1 = constantK / newLiquidityOption2;
        }
        
        // Calculate extraction and locked odds
        uint256 extractedFromOption1 = market.liquidityOption1 > newLiquidityOption1 ? 
            market.liquidityOption1 - newLiquidityOption1 : 0;
        
        uint256 extractionRatio = (extractedFromOption1 * PRECISION) / betAmount;
        uint256 feeMultiplier = PRECISION - market.feePercentage;
        uint256 lockedOdds = PRECISION + ((extractionRatio * feeMultiplier) / PRECISION);
        
        // Calculate potential payout and fees
        uint256 potentialPayout = (betAmount * lockedOdds) / PRECISION;
        
        // Update reserves according to Excel formula
        uint256 newReserveX = newLiquidityOption1 >= market.initialLiquidity ? 0 : 
            market.initialLiquidity - newLiquidityOption1;
        
        uint256 newReserveY = newLiquidityOption2 >= market.initialLiquidity ? 0 : 
            market.initialLiquidity - newLiquidityOption2;
        
        // Update market state
        market.liquidityOption1 = newLiquidityOption1;
        market.liquidityOption2 = newLiquidityOption2;
        market.reserveX = newReserveX;
        market.reserveY = newReserveY;
        
        // Record user bet
        BetInfo memory betInfo = BetInfo({
            id: market.userBets[msg.sender].length + 1,
            timestamp: block.timestamp,
            isOption1: false,
            amount: betAmount,
            lockedOdds: lockedOdds,
            potentialPayout: potentialPayout,
            claimed: false
        });
        
        market.userBets[msg.sender].push(betInfo);
        
        emit BetPlaced(marketId, msg.sender, false, betAmount, lockedOdds, potentialPayout);
    }

    /**
     * @dev Resolve the market with the final outcome
     * @param marketId The ID of the market
     * @param outcome The outcome of the market (true = Option1/Yes won, false = Option2/No won)
     */
    function resolveMarket(uint256 marketId, bool outcome) 
        external 
        onlyOwner 
        marketExists(marketId) 
        marketNotResolved(marketId) 
    {
        Market storage market = markets[marketId];
        market.isResolved = true;
        market.outcome = outcome;
        
        emit MarketResolved(marketId, outcome);
    }

    /**
     * @dev Claim payouts for winning bets
     * @param marketId The ID of the market
     */
    function claimPayouts(uint256 marketId) 
        external 
        marketExists(marketId) 
        marketIsResolved(marketId) 
    {
        Market storage market = markets[marketId];
        BetInfo[] storage bets = market.userBets[msg.sender];
        
        uint256 totalPayout = 0;
        
        for (uint256 i = 0; i < bets.length; i++) {
            if (!bets[i].claimed && bets[i].isOption1 == market.outcome) {
                totalPayout += bets[i].potentialPayout;
                bets[i].claimed = true;
            }
        }
        
        require(totalPayout > 0, "No winning bets to claim");
        require(address(this).balance >= totalPayout, "Insufficient contract balance");
        
        payable(msg.sender).transfer(totalPayout);
        
        emit PayoutClaimed(marketId, msg.sender, totalPayout);
    }

    /**
     * @dev Collect accumulated fees (admin function)
     * @param marketId The ID of the market
     */
    function collectFees(uint256 marketId) 
        external 
        onlyOwner 
        marketExists(marketId) 
        marketIsResolved(marketId) 
    {
        Market storage market = markets[marketId];
        
        // Calculate total fees accumulated
        uint256 totalBets = market.totalBetsOption1 + market.totalBetsOption2;
        uint256 totalPayouts = calculateTotalPayouts(marketId);
        
        uint256 fees = totalBets > totalPayouts ? totalBets - totalPayouts : 0;
        require(fees > 0, "No fees to collect");
        require(address(this).balance >= fees, "Insufficient contract balance");
        
        payable(owner).transfer(fees);
        
        emit FeesCollected(marketId, owner, fees);
    }

    /**
     * @dev Calculate total payouts for a market
     * @param marketId The ID of the market
     * @return Total payout amount
     */
    function calculateTotalPayouts(uint256 marketId) internal view returns (uint256) {
        Market storage market = markets[marketId];
        uint256 totalPayout = 0;
        
        address[] memory bettors = getAllBettors(marketId);
        
        for (uint256 i = 0; i < bettors.length; i++) {
            BetInfo[] storage bets = market.userBets[bettors[i]];
            
            for (uint256 j = 0; j < bets.length; j++) {
                if (bets[j].isOption1 == market.outcome) {
                    totalPayout += bets[j].potentialPayout;
                }
            }
        }
        
        return totalPayout;
    }

    /**
     * @dev Get all unique bettors for a market
     * @param marketId The ID of the market
     * @return Array of bettor addresses
     */
    function getAllBettors(uint256 marketId) internal view returns (address[] memory) {
        // This is a simplified implementation to demonstrate the concept
        // In a production environment, you would maintain a separate mapping of bettors
        // This implementation has limitations and is gas-inefficient for large numbers of bettors
        
        // For demonstration purposes, we'll just return the owner address
        // In a real implementation, you would track and return all unique bettor addresses
        address[] memory bettors = new address[](1);
        bettors[0] = owner;
        return bettors;
    }

    /**
     * @dev Get market information
     * @param marketId The ID of the market
     * @return Market information
     */
    function getMarketInfo(uint256 marketId) 
        external 
        view 
        marketExists(marketId) 
        returns (MarketInfo memory) 
    {
        Market storage market = markets[marketId];
        
        return MarketInfo({
            id: market.id,
            question: market.question,
            initialLiquidity: market.initialLiquidity,
            feePercentage: market.feePercentage,
            liquidityOption1: market.liquidityOption1,
            liquidityOption2: market.liquidityOption2,
            totalBetsOption1: market.totalBetsOption1,
            totalBetsOption2: market.totalBetsOption2,
            reserveX: market.reserveX,
            reserveY: market.reserveY,
            isResolved: market.isResolved,
            outcome: market.outcome
        });
    }

    /**
     * @dev Get current market odds
     * @param marketId The ID of the market
     * @return oddsOption1 Odds for Option 1 (Yes), scaled by PRECISION
     * @return oddsOption2 Odds for Option 2 (No), scaled by PRECISION
     */
    function getMarketOdds(uint256 marketId) 
        external 
        view 
        marketExists(marketId) 
        returns (uint256 oddsOption1, uint256 oddsOption2) 
    {
        Market storage market = markets[marketId];
        
        uint256 totalLiquidity = market.liquidityOption1 + market.liquidityOption2;
        oddsOption1 = (totalLiquidity * PRECISION) / market.liquidityOption1;
        oddsOption2 = (totalLiquidity * PRECISION) / market.liquidityOption2;
        
        return (oddsOption1, oddsOption2);
    }

    /**
     * @dev Get user's bets for a specific market
     * @param marketId The ID of the market
     * @param user The address of the user
     * @return Array of bet information
     */
    function getUserBets(uint256 marketId, address user) 
        external 
        view 
        marketExists(marketId) 
        returns (BetData[] memory) 
    {
        BetInfo[] storage bets = markets[marketId].userBets[user];
        BetData[] memory betData = new BetData[](bets.length);
        
        for (uint256 i = 0; i < bets.length; i++) {
            betData[i] = BetData({
                id: bets[i].id,
                timestamp: bets[i].timestamp,
                isOption1: bets[i].isOption1,
                amount: bets[i].amount,
                lockedOdds: bets[i].lockedOdds,
                potentialPayout: bets[i].potentialPayout
            });
        }
        
        return betData;
    }

    /**
     * @dev Get total number of markets
     * @return Total market count
     */
    function getMarketCount() external view returns (uint256) {
        return marketCount;
    }

    /**
     * @dev Calculate potential payout and locked odds for a hypothetical bet
     * @param marketId The ID of the market
     * @param isOption1 Whether it's a bet on Option 1 (Yes)
     * @param betAmount The amount to bet
     * @return lockedOdds The locked odds for the bet, scaled by PRECISION
     * @return potentialPayout The potential payout for the bet
     */
    function calculatePotentialBet(uint256 marketId, bool isOption1, uint256 betAmount)
        external
        view
        marketExists(marketId)
        marketNotResolved(marketId)
        returns (uint256 lockedOdds, uint256 potentialPayout)
    {
        Market storage market = markets[marketId];
        uint256 constantK = market.initialLiquidity * market.initialLiquidity;
        
        if (isOption1) {
            // Betting on Option 1 (Yes)
            int256 excess1 = int256(market.totalBetsOption1) - int256(market.totalBetsOption2);
            
            uint256 newLiquidityOption1;
            uint256 newLiquidityOption2;
            
            if (excess1 < 0) {
                uint256 scaleFactor = (market.reserveX * PRECISION) / uint256(-excess1);
                uint256 scaledBet = (betAmount * scaleFactor) / PRECISION;
                
                newLiquidityOption1 = market.liquidityOption1 + scaledBet;
                newLiquidityOption2 = constantK / newLiquidityOption1;
            } else {
                newLiquidityOption1 = market.liquidityOption1 + betAmount;
                newLiquidityOption2 = constantK / newLiquidityOption1;
            }
            
            uint256 extractedFromOption2 = market.liquidityOption2 > newLiquidityOption2 ? 
                market.liquidityOption2 - newLiquidityOption2 : 0;
            
            uint256 extractionRatio = (extractedFromOption2 * PRECISION) / betAmount;
            uint256 feeMultiplier = PRECISION - market.feePercentage;
            lockedOdds = PRECISION + ((extractionRatio * feeMultiplier) / PRECISION);
            potentialPayout = (betAmount * lockedOdds) / PRECISION;
        } else {
            // Betting on Option 2 (No)
            int256 excess1 = int256(market.totalBetsOption1) - int256(market.totalBetsOption2);
            
            uint256 newLiquidityOption1;
            uint256 newLiquidityOption2;
            
            if (excess1 > 0) {
                uint256 scaleFactor = (market.reserveY * PRECISION) / uint256(excess1);
                uint256 scaledBet = (betAmount * scaleFactor) / PRECISION;
                
                newLiquidityOption2 = market.liquidityOption2 + scaledBet;
                newLiquidityOption1 = constantK / newLiquidityOption2;
            } else {
                newLiquidityOption2 = market.liquidityOption2 + betAmount;
                newLiquidityOption1 = constantK / newLiquidityOption2;
            }
            
            uint256 extractedFromOption1 = market.liquidityOption1 > newLiquidityOption1 ? 
                market.liquidityOption1 - newLiquidityOption1 : 0;
            
            uint256 extractionRatio = (extractedFromOption1 * PRECISION) / betAmount;
            uint256 feeMultiplier = PRECISION - market.feePercentage;
            lockedOdds = PRECISION + ((extractionRatio * feeMultiplier) / PRECISION);
            potentialPayout = (betAmount * lockedOdds) / PRECISION;
        }
        
        return (lockedOdds, potentialPayout);
    }
}