// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title MarketMath Library
 * @notice Provides pure calculation functions for the HiloPredictionMarket AMM logic.
 */
library MarketMath {
    // Using a struct to pass market state might reduce stack depth if many values are needed.
    // struct MarketState {
    //     uint256[] currentLiquidity;
    //     uint256[] initialLiquidity;
    // }

    /**
     * @notice Calculate reserve for one option (amount below initial liquidity).
     * @param initialLiq Initial liquidity for the option.
     * @param currentLiq Current liquidity for the option.
     * @return The amount of reserve tokens for the option.
     */
    function calculateReserve(uint256 initialLiq, uint256 currentLiq) internal pure returns (uint256) {
        return currentLiq >= initialLiq ? 0 : initialLiq - currentLiq;
    }

    /**
     * @notice Calculate total 'remaining' liquidity, including current liquidity and reserves.
     * @dev This matches the definition used for odds calculation in the original contract.
     * @param currentLiquidity Array of current liquidity for all options.
     * @param initialLiquidity Array of initial liquidity for all options.
     * @return total Total remaining liquidity (sum of current liquidity and reserves).
     */
    function calculateTotalRemainingLiquidity(
        uint256[] memory currentLiquidity,
        uint256[] memory initialLiquidity
    ) internal pure returns (uint256 total) {
        require(currentLiquidity.length == initialLiquidity.length, "MarketMath: Array length mismatch");
        uint256 optionsCount = currentLiquidity.length;
        for (uint256 i = 0; i < optionsCount; i++) {
            total += currentLiquidity[i];
            // Add reserve for this option
            total += calculateReserve(initialLiquidity[i], currentLiquidity[i]);
        }
        return total;
    }

    /**
     * @notice Calculate odds for a single option based on total remaining liquidity.
     * @param optionLiquidity Current liquidity of the specific option.
     * @param totalRemainingLiquidity Total remaining liquidity including reserves (from calculateTotalRemainingLiquidity).
     * @param precision The precision factor (e.g., 10000).
     * @return odds Odds for the option, scaled by precision. Returns 0 if option liquidity is 0.
     */
    function calculateOddsForOption(
        uint256 optionLiquidity,
        uint256 totalRemainingLiquidity,
        uint256 precision
    ) internal pure returns (uint256 odds) {
         if (optionLiquidity > 0) {
            // Use CPMM odds formula: (total liquidity) / (option liquidity)
            // Solidity 0.8+ handles overflow checks
            odds = (totalRemainingLiquidity * precision) / optionLiquidity;
        } else {
            odds = 0; // Handle zero liquidity case
        }
        return odds;
    }

    /**
     * @notice Calculates the raw return for a binary option bet (Yes/No)
     * @param thisOptionLiquidity The current liquidity of the option being bet on
     * @param otherOptionLiquidity The current liquidity of the other option
     * @param betAmount The amount being bet
     * @return rawReturn The raw return (before fees) extracted from the other pool
     */
    function calculateBetRawReturnBinary(
        uint256 thisOptionLiquidity,
        uint256 otherOptionLiquidity,
        uint256 betAmount
    ) public pure returns (uint256 rawReturn) {
        if (thisOptionLiquidity == 0 || otherOptionLiquidity == 0) {
            return 0; // Cannot calculate if any option has zero liquidity
        }
        
        // Use constant product formula to calculate raw extraction
        uint256 constantK = thisOptionLiquidity * otherOptionLiquidity;
        uint256 newThisLiquidity = thisOptionLiquidity + betAmount;
        uint256 newOtherLiquidity = constantK / newThisLiquidity;
        
        // Calculate the tokens extracted (reduction in other pool)
        // This is exactly what the React code does:
        // const extractedFromOption2 = liquidityOption2 - newLiquidityOption2;
        rawReturn = otherOptionLiquidity > newOtherLiquidity ? 
                    otherOptionLiquidity - newOtherLiquidity : 0;
                    
        return rawReturn;
    }

    /**
     * @notice Calculate early exit value before fees.
     * @dev Replicates logic from original calculateEarlyExitValue, including edge cases.
     *      Assumes a binary market based on original contract structure.
     * @param currentLiquidity Array of current liquidity for all options.
     * @param initialLiquidity Array of initial liquidity (needed for reserves in total calc).
     * @param optionIndex The index of the option being exited.
     * @param betAmount Amount of the specific option's bet being exited.
     * @param precision Precision factor.
     * @return exitValue The calculated value before fees.
     */
    function calculateEarlyExitValue(
        uint256[] memory currentLiquidity,
        uint256[] memory initialLiquidity,
        uint256 optionIndex,
        uint256 betAmount,
        uint256 precision // Pass precision if used in edge cases, although original didn't seem to
    ) internal pure returns (uint256 exitValue) {
        // Basic validation
        require(currentLiquidity.length == initialLiquidity.length, "MarketMath: Array length mismatch");
        require(optionIndex < currentLiquidity.length, "MarketMath: Invalid option index");
        require(currentLiquidity.length == 2, "MarketMath: Exit calculation only supports binary markets"); // Enforce binary assumption

        uint256 optionLiquidity = currentLiquidity[optionIndex]; // X
        uint256 otherLiquidity = currentLiquidity[1 - optionIndex]; // Y

        // Safety checks matching original behavior implicitly or explicitly
        if (optionLiquidity == 0 || betAmount == 0) {
             return 0; // Cannot exit if no liquidity or no amount to exit
        }
         // Check if exit amount exceeds available liquidity for the option itself
         // The caller (main contract) should check this: require(betAmount <= userBet <= optionLiquidity)
         // If betAmount > optionLiquidity, calculation below is invalid. Assume betAmount <= optionLiquidity.


        // --- Replicating Edge Cases and Core Logic from Original ---

        // EDGE CASE 1: Handle very small *other* liquidity situations.
        // Original logic: if (otherLiquidity == 0 || otherLiquidity < _betAmount / 100) return _betAmount;
        // Need to prevent division by zero for small bet amounts.
        if (otherLiquidity == 0 || (betAmount > 100 && otherLiquidity < betAmount / 100)) {
            // If counterparty pool is essentially empty, can only return the bet amount itself.
            return betAmount;
        }

        // Constant product using only current liquidity of the two options (X * Y)
        uint256 constantProduct = optionLiquidity * otherLiquidity;

        // EDGE CASE 2: Handle case where removing bet leaves very small *option* liquidity.
        // Original logic: if (newOptionLiquidity == 0 || newOptionLiquidity < optionLiquidity / 100) return _betAmount;
        if (betAmount >= optionLiquidity) {
             // Trying to exit more than or exactly the pool's liquidity for this option.
             // Return original bet amount as per original logic? Or should it be capped by 'otherLiquidity'?
             // The original logic returned betAmount here. Let's replicate that.
             return betAmount;
        }
        uint256 newOptionLiquidity = optionLiquidity - betAmount; // X_new = X_old - exitAmount
        // Prevent division by zero for small optionLiquidity
        if (optionLiquidity > 100 && newOptionLiquidity < optionLiquidity / 100) {
             // If remaining liquidity is negligible, return original bet.
            return betAmount;
        }

        // Calculate new other liquidity needed to maintain constant product: Y_new = K / X_new
        // Safety check for division - newOptionLiquidity should be > 0 based on checks above
        if (newOptionLiquidity == 0) { return betAmount; } // Should be unreachable but safe guard
        uint256 newOtherLiquidity = constantProduct / newOptionLiquidity; // Y_new

        // EDGE CASE 3: Protection against extreme division values.
        // Original logic: if (constantProduct / newOptionLiquidity > otherLiquidity * 100) return _betAmount;
        // Rewritten: Check if newOtherLiquidity is excessively larger than otherLiquidity
        // Prevent division by zero for otherLiquidity
        if (otherLiquidity > 0 && newOtherLiquidity / 100 > otherLiquidity) {
            return betAmount;
        }
         // Also handle case where constantProduct was 0 initially (if one pool started at 0)
         if (constantProduct == 0 && newOtherLiquidity != 0) {
             // This implies 0 * Y / X_new resulted in non-zero? Should not happen.
             return betAmount;
         }


        // Calculate exit value = required increase in other liquidity: Y_new - Y_old
        if (newOtherLiquidity <= otherLiquidity) {
            // This implies K decreased or X increased on exit, shouldn't happen.
            // Return betAmount as per original edge case.
            return betAmount;
        }
        uint256 additionalLiquidity = newOtherLiquidity - otherLiquidity;

        // EDGE CASE 4: Complex capping logic from original.
        // if (additionalLiquidity > _betAmount * 2) { exitValue = _betAmount * 2; }
        // else if (additionalLiquidity > _betAmount && totalLiquidity > _betAmount * 10) { exitValue = _betAmount; }
        // else { exitValue = additionalLiquidity; }
        // This logic seems complex and potentially market-specific. Let's simplify for the library
        // and return the raw calculated value. The main contract could apply caps if needed.
        // For now, return the calculated additionalLiquidity.
        exitValue = additionalLiquidity;

        // Let's try to replicate the original capping slightly more closely as it might be important.
        // It seems designed to prevent excessive returns, especially capping near the original bet amount.
        uint256 totalCurrentLiquidity = optionLiquidity + otherLiquidity; // Approx total for capping context
         if (additionalLiquidity > betAmount * 2) {
             exitValue = betAmount * 2; // Cap at 2x bet amount
         } else if (additionalLiquidity > betAmount && totalCurrentLiquidity > betAmount * 10) {
             // If exit value exceeds bet amount in a liquid market, cap at bet amount
             // This prevents profiting purely from AMM mechanics on exit?
             exitValue = betAmount;
         } else {
             exitValue = additionalLiquidity; // Default case
         }

        // Ensure exit value doesn't exceed what's available in the other pool (implicit check)
        // Since additionalLiquidity = Y_new - Y_old, and Y_new = K / X_new, it's derived.
        // A direct check isn't usually needed if K is maintained.

        return exitValue;
    }

    /**
     * @notice Calculate winnings for a user based on their share of winning bets vs losing liquidity.
     * @param userBetOnWinningOption The user's total bet amount on the winning option.
     * @param totalBetsOnWinningOption The sum of all users' bets on the winning option.
     * @param totalLiquidityOnLosingOptions Sum of *current* liquidity of all losing options at settlement.
     * @return winnings The amount of tokens won by the user from the losing side's pot.
     */
    function calculateWinnings(
        uint256 userBetOnWinningOption,
        uint256 totalBetsOnWinningOption,
        uint256 totalLiquidityOnLosingOptions
    ) internal pure returns (uint256 winnings) {
        if (totalBetsOnWinningOption == 0) {
            return 0; // Avoid division by zero if no one bet on the winning side.
        }
        // Calculate pro-rata share: (userBet / totalWinningBets) * totalLosingLiquidity
        // Multiply first to maintain precision: (userBet * totalLosingLiquidity) / totalWinningBets
        // Solidity 0.8+ checks for overflow.
        uint256 numerator = userBetOnWinningOption * totalLiquidityOnLosingOptions;
        winnings = numerator / totalBetsOnWinningOption;
        return winnings;
    }
} 