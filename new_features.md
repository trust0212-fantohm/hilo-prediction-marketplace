# Hilo Prediction Market - Advanced Features

This document outlines how to interact with the advanced features of the Hilo Prediction Market smart contracts, including viewing odds, managing positions, and executing early exits.

## Current Market Odds

### Getting Current Display Odds

The current odds for any option represent the potential return multiplier if that option wins. For example, odds of 2.5x mean you would receive 2.5 times your bet amount if you win.

```javascript
// JavaScript example with ethers.js
const optionGroupId = 123456; // Your option group ID
const currentOdds = await hiloPredictionMarket.getOdds(optionGroupId);

// Convert to human-readable format (assuming binary market)
const yesOdds = Number(currentOdds[0]) / 10000; // Assuming PRECISION = 10000
const noOdds = Number(currentOdds[1]) / 10000;

console.log(`Current Yes odds: ${yesOdds.toFixed(4)}x`);
console.log(`Current No odds: ${noOdds.toFixed(4)}x`);
```

## User Positions

### Getting All User Positions

To view all bets a user has placed on a specific option group:

```javascript
// Get all active bet IDs for a user on a specific option group
const activeBetIds = await betLedger.getUserActiveBetIds(userAddress, optionGroupId);

// Then get details for each bet
for (const betId of activeBetIds) {
    const betDetails = await betLedger.getBetDetails(betId);
    console.log(betDetails);
}
```

### Calculating Potential Payouts

Each bet stores the locked odds at the time of placement, which determines the payout if the bet wins.

```javascript
// JavaScript example to calculate potential payout
async function getUserPositionDetails(userAddress, optionGroupId) {
    // Get all user bets for this option group
    const betIds = await betLedger.getUserActiveBetIds(userAddress, optionGroupId);
    
    // Get option group details to display option names
    const group = await hiloPredictionMarket.optionGroups(optionGroupId);
    
    // Format for display
    const positions = [];
    for (const betId of betIds) {
        const betDetails = await betLedger.getBetDetails(betId);
        
        // Extract details
        const optionIndex = betDetails.optionIndex;
        const optionName = group.options[optionIndex]; // Get option name from option group
        const betAmount = ethers.utils.formatEther(betDetails.amount);
        const lockedOdds = Number(betDetails.lockedOdds) / 10000; // PRECISION = 10000
        
        // Calculate potential payout
        const potentialPayout = betDetails.amount * betDetails.lockedOdds / 10000;
        const formattedPayout = ethers.utils.formatEther(potentialPayout);
        
        // Calculate profit
        const profit = potentialPayout - betDetails.amount;
        const formattedProfit = ethers.utils.formatEther(profit);
        
        positions.push({
            betId: betId.toString(),
            optionName,
            optionIndex: optionIndex.toString(),
            betAmount,
            lockedOdds: `${lockedOdds.toFixed(4)}x`,
            potentialPayout: formattedPayout,
            profit: formattedProfit,
            status: getBetStatusString(betDetails.status)
        });
    }
    
    return positions;
}

function getBetStatusString(statusCode) {
    const statuses = ['Active', 'CashedOut', 'SettledWon', 'SettledLost', 'Refunded'];
    return statuses[statusCode];
}
```

### Example Output

```json
[
  {
    "betId": "42",
    "optionName": "Yes",
    "optionIndex": "0",
    "betAmount": "10.0",
    "lockedOdds": "1.7499x",
    "potentialPayout": "17.499",
    "profit": "7.499",
    "status": "Active"
  },
  {
    "betId": "47",
    "optionName": "No",
    "optionIndex": "1",
    "betAmount": "5.0",
    "lockedOdds": "2.1279x",
    "potentialPayout": "10.6395",
    "profit": "5.6395",
    "status": "Active"
  }
]
```

## Early Exit (Cashout)

Early exit allows users to exit their position before the market settles, securing a portion of their potential profit based on current market conditions.

### Getting Early Exit Value

Before executing an early exit, you can check the current exit value:

```javascript
// Get all active bets with their cashout values
const activeBetsWithCashout = await betLedger.getActiveBetsWithCashout(userAddress, optionGroupId);

// Display cashout values
for (const betInfo of activeBetsWithCashout) {
    console.log(`Bet ID: ${betInfo.betId}, Cashout Value: ${ethers.utils.formatEther(betInfo.cashoutValue)} tokens`);
}
```

### Executing Early Exit

To execute an early exit, call the `earlyExit` function with the bet ID:

```javascript
// Execute early exit for a specific bet
const betIdToExit = 42; // Example bet ID
await hiloPredictionMarket.earlyExit(betIdToExit);

console.log(`Successfully exited position with bet ID ${betIdToExit}`);
```

### Factors Affecting Early Exit Value

The early exit value is calculated based on:

1. The current state of the liquidity pools
2. The locked odds from when the bet was placed 
3. The original bet amount
4. Any early exit fees (configurable by the protocol)

Early exit is typically most profitable when:
- The odds have moved in your favor since placing the bet
- You exit early in the market's lifecycle
- The market has higher overall liquidity

## Complete Example: User Position Management

```javascript
async function manageUserPositions(userAddress, optionGroupId) {
    // 1. Get current odds
    const currentOdds = await hiloPredictionMarket.getOdds(optionGroupId);
    const yesOdds = Number(currentOdds[0]) / 10000;
    const noOdds = Number(currentOdds[1]) / 10000;
    console.log(`Current market odds: Yes ${yesOdds.toFixed(4)}x, No ${noOdds.toFixed(4)}x`);
    
    // 2. Get user positions
    const betIds = await betLedger.getUserActiveBetIds(userAddress, optionGroupId);
    console.log(`User has ${betIds.length} active positions`);
    
    // 3. Get cashout values
    const cashoutInfos = await betLedger.getActiveBetsWithCashout(userAddress, optionGroupId);
    
    // 4. Display comprehensive position information
    for (let i = 0; i < betIds.length; i++) {
        const betId = betIds[i];
        const betDetails = await betLedger.getBetDetails(betId);
        const cashoutInfo = cashoutInfos.find(info => info.betId.eq(betId));
        
        const betAmount = ethers.utils.formatEther(betDetails.amount);
        const lockedOdds = Number(betDetails.lockedOdds) / 10000;
        const optionName = betDetails.optionIndex == 0 ? "Yes" : "No";
        const potentialPayout = ethers.utils.formatEther(betDetails.amount.mul(betDetails.lockedOdds).div(10000));
        const cashoutValue = ethers.utils.formatEther(cashoutInfo.cashoutValue);
        
        console.log(`
Position #${i+1}:
  Bet ID: ${betId}
  Option: ${optionName}
  Bet Amount: ${betAmount} tokens
  Locked Odds: ${lockedOdds.toFixed(4)}x
  Potential Payout: ${potentialPayout} tokens
  Current Cashout Value: ${cashoutValue} tokens
  Cashout % of Potential: ${(Number(cashoutValue) / Number(potentialPayout) * 100).toFixed(2)}%
        `);
    }
    
    // 5. Execute early exit for a selected bet
    const betIdToExit = betIds[0]; // Example: exit the first position
    await hiloPredictionMarket.earlyExit(betIdToExit);
    console.log(`Successfully exited position with bet ID ${betIdToExit}`);
}
```

This documentation provides the key information needed to integrate with the Hilo Prediction Market's features for displaying odds, managing user positions, and executing early exits. 