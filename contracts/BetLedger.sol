// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

// Minimal interface for HiloPredictionMarket needed by BetLedger's view function
interface IHiloPredictionMarketReader {
    function getCurrentLiquidity(uint256 _optionGroupId) external view returns (uint256[] memory);
    function getInitialLiquidity(uint256 _optionGroupId) external view returns (uint256[] memory); // Needed for K calculation assumption
    function earlyExitFee() external view returns (uint256);
    function PRECISION() external view returns (uint256);
}

contract BetLedger is Ownable {

    enum BetStatus { Active, CashedOut, SettledWon, SettledLost, Refunded }

    struct Bet {
        uint256 id;         // Unique bet ID
        address user;       // Address of the bettor
        uint256 groupId;    // ID of the option group
        uint256 optionIndex; // Index of the chosen option
        uint256 amount;     // Amount bet
        uint256 potentialPayout; // Potential payout if bet wins
        uint64 timestamp;   // When the bet was placed
        BetStatus status;   // Status of the bet
        uint256 lockedOdds; // The odds locked at bet time (precision adjusted)
    }

    // Struct for the combined view result
    struct BetCashoutInfo {
        uint256 betId;
        uint256 cashoutValue; // Value after estimated fee
    }

    mapping(uint256 => Bet) public bets; // betId => Bet details
    uint256 public nextBetId = 1; // Start IDs from 1

    // Indexes for efficient lookups
    mapping(address => mapping(uint256 => uint256[])) private userActiveBetsInGroup; // user => groupId => array of active betIds
    mapping(uint256 => uint256[]) private groupBetIds; // groupId => array of all betIds

    IHiloPredictionMarketReader public hiloMarket; // Store market contract address

    event BetRecorded(
        uint256 indexed betId,
        address indexed user,
        uint256 indexed optionGroupId,
        uint256 optionIndex,
        uint256 amount,
        uint256 potentialPayout
    );
    event BetStatusUpdated(uint256 indexed betId, BetStatus newStatus);

    modifier onlyPredictionMarket() {
        require(msg.sender == owner(), "BetLedger: Caller is not the Prediction Market contract");
        _;
    }

    /**
     * @notice Constructor sets the address of the HiloPredictionMarket contract which is the owner.
     * @param _predictionMarketAddress The address of the HiloPredictionMarket contract.
     */
    constructor(address _predictionMarketAddress) Ownable(_predictionMarketAddress) {
        require(_predictionMarketAddress != address(0), "BetLedger: Invalid market address");
        hiloMarket = IHiloPredictionMarketReader(_predictionMarketAddress);
    }

    // --- Write Functions (Callable only by PredictionMarket/Owner) ---

    /**
     * @notice Records a new bet placed in the Prediction Market.
     * @dev Should only be callable by the linked HiloPredictionMarket contract.
     * @param _user The bettor's address.
     * @param _optionGroupId The market ID.
     * @param _optionIndex The chosen option index.
     * @param _amount The amount bet.
     * @param _potentialPayout The calculated potential payout if the bet wins.
     * @param _expiry Optional expiry timestamp (unused currently).
     * @param _lockedOdds The odds locked at bet time (precision adjusted).
     * @return betId The unique ID assigned to this bet.
     */
    function recordBet(
        address _user,
        uint256 _optionGroupId,
        uint256 _optionIndex,
        uint256 _amount,
        uint256 _potentialPayout,
        uint256 _expiry,
        uint256 _lockedOdds
    ) external onlyPredictionMarket returns (uint256 betId) {
        require(_user != address(0), "BetLedger: Invalid user address");
        require(_amount > 0, "BetLedger: Bet amount must be positive");

        betId = nextBetId++;
        
        Bet storage newBet = bets[betId];
        newBet.id = betId;
        newBet.user = _user;
        newBet.groupId = _optionGroupId;
        newBet.optionIndex = _optionIndex;
        newBet.amount = _amount;
        newBet.potentialPayout = _potentialPayout;
        newBet.timestamp = uint64(block.timestamp);
        newBet.status = BetStatus.Active;
        newBet.lockedOdds = _lockedOdds; // Store the locked odds value

        // Add to indexes
        userActiveBetsInGroup[_user][_optionGroupId].push(betId);
        groupBetIds[_optionGroupId].push(betId);
        
        emit BetRecorded(betId, _user, _optionGroupId, _optionIndex, _amount, _potentialPayout);
        return betId;
    }

    /**
     * @notice Updates the status of a bet (e.g., cashed out, settled, refunded).
     * @dev Should only be callable by the linked HiloPredictionMarket contract.
     * @param _betId The ID of the bet to update.
     * @param newStatus The new status to set for the bet.
     */
    function updateBetStatus(uint256 _betId, BetStatus newStatus) external onlyPredictionMarket {
        // Load into memory instead of using storage pointer
        Bet memory bet = bets[_betId];
        require(bet.id == _betId && bet.id != 0, "BetLedger: Update target bet does not exist"); // Ensure bet exists

        // Prevent unsupported transitions if needed (e.g., can't go from Settled back to Active)
        // require(newStatus > bet.status || newStatus == BetStatus.Refunded, "BetLedger: Invalid status transition");

        // Only update if status is actually changing
        if (bet.status == newStatus) {
            return;
        }

        bool wasActive = bet.status == BetStatus.Active;
        bet.status = newStatus; // Update the status in the memory struct

        // Write the updated struct back to storage
        bets[_betId] = bet;

        // ---> REMOVED CHECK - No longer needed as we explicitly write back <---
        // require(bets[_betId].status == newStatus, "BetLedger: Status did not update in storage!");

        // If status is changing FROM Active TO something else, remove from active index
        if (wasActive && newStatus != BetStatus.Active) {
            _removeFromUserActiveBets(bet.user, bet.groupId, _betId);
        }
        // If somehow changing back TO Active (e.g., correction), need logic to re-add to index (omitted for simplicity)

        emit BetStatusUpdated(_betId, newStatus);
    }

    // --- Internal Helper for Index Maintenance ---

    function _removeFromUserActiveBets(address user, uint256 groupId, uint256 betIdToRemove) private {
        uint256[] storage activeBets = userActiveBetsInGroup[user][groupId];
        uint256 lastIndex = activeBets.length - 1;
        for (uint i = 0; i < activeBets.length; i++) {
            if (activeBets[i] == betIdToRemove) {
                // Swap with last element and pop (only if not already the last element)
                 if (i != lastIndex) {
                    activeBets[i] = activeBets[lastIndex];
                }
                activeBets.pop();
                return; // Assume IDs are unique per user/group active list
            }
        }
        // Bet ID not found in active list (might have already been removed or never added correctly) - do nothing
    }

    // --- View Functions ---

    /**
     * @notice Gets details of a specific bet.
     * @param _betId The ID of the bet.
     * @return Bet struct containing details.
     */
    function getBetDetails(uint256 _betId) external view returns (Bet memory) {
        require(bets[_betId].id == _betId, "BetLedger: Bet ID does not exist"); // Add check here
        console.log("BetLedger.getBetDetails: Reading status for betId %s: Status = %s", _betId, uint(bets[_betId].status));
        return bets[_betId];
    }

    /**
     * @notice Get the IDs of currently active bets placed by a user in a specific group.
     */
    function getUserActiveBetIds(address _user, uint256 _optionGroupId) external view returns (uint256[] memory) {
        return userActiveBetsInGroup[_user][_optionGroupId];
    }

     /**
     * @notice Get the IDs of all bets placed in a specific group (active or inactive).
     * @dev Useful for iterating during settlement or cancellation by an off-chain process or restricted function.
     */
    function getAllBetIdsInGroup(uint256 _optionGroupId) external view returns (uint256[] memory) {
        return groupBetIds[_optionGroupId];
    }

    /**
     * @notice Gets active bets for a user in a group and calculates their current cashout value.
     * @dev Assumes binary market for K calculation based on initial liquidity.
     * @param _user The user address.
     * @param _optionGroupId The market ID.
     * @return An array of structs containing betId and calculated cashoutValue.
     */
    function getActiveBetsWithCashout(
        address _user,
        uint256 _optionGroupId
    ) external view returns (BetCashoutInfo[] memory) {
        // Add check: Ensure the market contract address is set
        require(address(hiloMarket) != address(0), "BetLedger: Market address not set");

        // Add check: Can we *at least* call a simple view like PRECISION?
        try hiloMarket.PRECISION() returns (uint256 p) {
            require(p > 0, "BetLedger: Market PRECISION is zero");
        } catch {
            revert("BetLedger: Failed basic market call (PRECISION)");
        }
        // Removed other try/catch for brevity - add specific checks below

        uint256[] memory activeBetIds = userActiveBetsInGroup[_user][_optionGroupId];
        uint256 numActiveBets = activeBetIds.length;
        if (numActiveBets == 0) {
            return new BetCashoutInfo[](0);
        }

        // Get current state from HiloPredictionMarket via view calls
        // Add specific reverts on failure now
        uint256[] memory currentLiquidity = hiloMarket.getCurrentLiquidity(_optionGroupId);
        require(currentLiquidity.length > 0, "BetLedger: Market returned empty current liquidity");

        uint256[] memory initialLiquidity = hiloMarket.getInitialLiquidity(_optionGroupId);
        require(initialLiquidity.length > 0, "BetLedger: Market returned empty initial liquidity");

        uint256 feePercent = hiloMarket.earlyExitFee();
        uint256 precision = hiloMarket.PRECISION(); // Already checked above, assume ok

        // Assuming binary market for simplicity, like the rest of the logic
        require(currentLiquidity.length == 2, "Ledger: Market not binary (currentLiq)");
        require(initialLiquidity.length == 2, "Ledger: Market not binary (initialLiq)");
        require(precision > 0, "Ledger: Precision is zero");

        uint256 currentLiqOpt1 = currentLiquidity[0];
        uint256 currentLiqOpt2 = currentLiquidity[1];

        // Calculate K based on initial liquidity assumption (potential inaccuracy noted before)
        // Consider requiring K or a calculation function from IHiloPredictionMarketReader if needed
        uint256 constantK = 0;
        if (initialLiquidity[0] > 0 && initialLiquidity[1] > type(uint256).max / initialLiquidity[0]) {
            // Potential overflow if calculating K naively, use a safe default or revert
             revert("BetLedger: K calculation overflow risk");
        } else {
             constantK = initialLiquidity[0] * initialLiquidity[1];
        }
        if (constantK == 0) {
            // If K is zero (e.g., initial liquidity was zero), cashout is likely impossible or zero
             // Return array with zero cashout values
             BetCashoutInfo[] memory zeroResults = new BetCashoutInfo[](numActiveBets);
             for(uint k=0; k<numActiveBets; ++k) {
                 zeroResults[k] = BetCashoutInfo({betId: activeBetIds[k], cashoutValue: 0});
             }
             return zeroResults;
        }


        BetCashoutInfo[] memory results = new BetCashoutInfo[](numActiveBets);

        for (uint i = 0; i < numActiveBets; i++) {
            uint256 betId = activeBetIds[i];
            Bet storage bet = bets[betId]; // Use storage pointer

            // Calculate cashout only if the bet actually exists (paranoid check)
            if (bet.id == 0) {
                 results[i] = BetCashoutInfo({ betId: betId, cashoutValue: 0 });
                 continue;
            }

            uint256 profitPortion = bet.potentialPayout > bet.amount ? bet.potentialPayout - bet.amount : 0;
            uint256 calculatedCashoutRaw = 0;

            // Perform the "offsetting bet" calculation
            // calculateOffsettingBetExit is internal, remove try/catch
            // It will revert on division by zero due to internal requires.
            calculatedCashoutRaw = calculateOffsettingBetExit(
                bet.optionIndex,
                profitPortion,
                currentLiqOpt1,
                currentLiqOpt2,
                constantK
            );

            // Apply Fees (Applying to whole value like HiloMarket's earlyExit)
            uint256 fee = (calculatedCashoutRaw * feePercent) / precision;
            uint256 cashoutValue = calculatedCashoutRaw > fee ? calculatedCashoutRaw - fee : 0;

            // Optional: Add capping logic here if needed (e.g., min(cashoutValue, bet.amount * 2))

            results[i] = BetCashoutInfo({
                betId: betId,
                cashoutValue: cashoutValue
            });
        }

        return results;
    }

     /**
      * @notice Internal pure function to calculate raw exit value using offsetting bet logic.
      * @dev Separated for clarity and potential reuse/testing. Reverts on division by zero.
      * @param _optionIndex Index of the original bet (0 or 1).
      * @param _profitPortion Theoretical profit (PotentialPayout - Amount).
      * @param _currentLiqOpt1 Current liquidity of option 1.
      * @param _currentLiqOpt2 Current liquidity of option 2.
      * @param _constantK The constant product K.
      * @return rawValue Raw cashout value before fees.
      */
     function calculateOffsettingBetExit(
         uint256 _optionIndex,
         uint256 _profitPortion,
         uint256 _currentLiqOpt1,
         uint256 _currentLiqOpt2,
         uint256 _constantK
     ) internal pure returns (uint256 rawValue) {
          require(_constantK > 0, "K must be positive");

          if (_optionIndex == 0) { // Bet on Option 1 -> Simulate betting profit on Option 2
                uint256 simulatedLiqOpt2 = _currentLiqOpt2 + _profitPortion;
                // Division by zero check is crucial
                require(simulatedLiqOpt2 > 0, "CALC_ERR: Simulated liq2 is zero");
                // Add check before division
                require(_constantK > 0, "CALC_ERR: K is zero before div");
                uint256 simulatedLiqOpt1 = _constantK / simulatedLiqOpt2;
                rawValue = _currentLiqOpt1 > simulatedLiqOpt1 ? _currentLiqOpt1 - simulatedLiqOpt1 : 0;
          } else { // Bet on Option 2 -> Simulate betting profit on Option 1
                uint256 simulatedLiqOpt1 = _currentLiqOpt1 + _profitPortion;
                 // Division by zero check is crucial
                require(simulatedLiqOpt1 > 0, "CALC_ERR: Simulated liq1 is zero");
                 // Add check before division
                require(_constantK > 0, "CALC_ERR: K is zero before div");
                uint256 simulatedLiqOpt2 = _constantK / simulatedLiqOpt1;
                rawValue = _currentLiqOpt2 > simulatedLiqOpt2 ? _currentLiqOpt2 - simulatedLiqOpt2 : 0;
          }
          return rawValue;
     }

    /**
     * @notice Updates the HiloPredictionMarket reference
     * @dev Only callable by owner, typically during initial setup
     * @param _newMarketAddress The address of the new HiloPredictionMarket contract
     */
    function updateHiloPredictionMarket(address _newMarketAddress) external onlyOwner {
        require(_newMarketAddress != address(0), "BetLedger: Invalid market address");
        hiloMarket = IHiloPredictionMarketReader(_newMarketAddress);
    }
} 