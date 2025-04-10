// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

// Import the new library
import "./MarketMath.sol";

// Interface for BetLedger
interface IBetLedger {
    // Define enum locally for interface compatibility if needed, or assume type match
    enum BetStatus { Active, CashedOut, SettledWon, SettledLost, Refunded }

    struct Bet {
        uint256 id;
        address user;
        uint256 optionGroupId;
        uint256 optionIndex;
        uint256 amount;
        uint256 potentialPayout;
        uint64 timestamp;
        BetStatus status;
        uint256 lockedOdds; // Added lockedOdds field
    }

    function recordBet(
        address _user,
        uint256 _optionGroupId,
        uint256 _optionIndex,
        uint256 _amount,
        uint256 _potentialPayout,
        uint256 _expiry,
        uint256 _lockedOdds
    ) external returns (uint256 betId);

    function updateBetStatus(uint256 _betId, BetStatus _newStatus) external;

    function getBetDetails(uint256 _betId) external view returns (Bet memory);
    function getUserActiveBetIds(address _user, uint256 _optionGroupId) external view returns (uint256[] memory);
    function getAllBetIdsInGroup(uint256 _optionGroupId) external view returns (uint256[] memory);
}

interface IHiloBonding {
    function getPoolBasics(uint256 _poolId) external view returns (
        address creator,
        string memory title,
        uint256 startTimeframe,
        uint256 evaluationEnd,
        uint256 disputeEnd
    );
    function getPoolStatus(uint256 _poolId) external view returns (
        bool processed,
        uint256 processedTime,
        bool finalApproval,
        bool disputeRound,
        uint256 winningOptionIndex
    );
    function getPoolOptions(uint256 _poolId) external view returns (
        string[] memory optionNames,
        bool hasOptions
    );
    function getPoolEvaluationStatus(uint256 _poolId) external view returns (
        bool evaluationComplete,
        bool evaluationApproved,
        uint256 approveVotes,
        uint256 rejectVotes,
        uint256 approveDisputeVotes,
        uint256 rejectDisputeVotes
    );
    function createPool(uint256 _poolId, string calldata _title, uint256 _startTimeframe, uint256 _settleTimeframe, string calldata _data, address _who) external;
    function setPoolOptions(uint256 _poolId, string[] calldata _optionNames) external;
}

interface IHiloStaking {
    function getValidatorStake(address user) external view returns (uint256);
    function getPoolCreatorStake(address user) external view returns (uint256);
}

contract HiloPredictionMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // No direct 'using for' as functions are standalone pure calculations

    IHiloBonding public bondingContract;
    IHiloStaking public stakingContract;
    IERC20 public bettingToken;
    IBetLedger public betLedgerContract; // Added BetLedger contract instance
    
    // Settings
    bool public defaultLiquidityEnabled = true;
    uint256 public defaultLiquidityAmount = 150 * 10**18; // 100 tokens by default
    
    // Emergency pause mechanism
    bool public paused = false;
    
    // Events for pause status changes
    event ContractPaused(address by);
    event ContractUnpaused(address by);
    
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    uint256 public platformFee = 300; // 3%
    uint256 public earlyExitFee = 500; // 5%
    uint256 public constant MAX_FEE = 1000; // 10%
    uint256 public constant PRECISION = 10000;

    // Option data structure
    struct Option {
        string name;
        uint256 index;
    }

    // Option group structure
    struct OptionGroup {
        uint256 poolId;
        bool initialized;
        bool settled;
        bool canceled;
        uint8 winningOptionIndex;
        uint256 settleTimeframe;
        uint256 totalLiquidity;
        uint256 totalFees;
        Option[] options;
        uint256[] initialLiquidity;
        uint256[] currentLiquidity;
        uint256[] totalBets;
        mapping(address => uint256) liquidityProviders;
        address[] liquidityProvidersList;
    }

    mapping(uint256 => OptionGroup) public optionGroups;

    event OptionGroupCreated(uint256 indexed optionGroupId, uint256 indexed poolId, uint256 optionsCount);
    
    event PoolAndOptionGroupCreated(
        uint256 indexed poolId,
        uint256 indexed optionGroupId,
        string poolTitle,
        uint256 startTimeframe,
        uint256 settleTimeframe,
        string data,
        string[] optionNames,
        uint256 evaluationEnd,
        uint256 optionVotingEnd,
        uint256 disputeEnd
    );
    
    event LiquidityAdded(uint256 indexed optionGroupId, address indexed provider, uint256 amount);
    
    event BetPlaced(
        uint256 indexed optionGroupId, 
        address indexed user, 
        uint256 optionIndex, 
        uint256 amount, 
        uint256 potentialReturn, 
        uint256 lockedOdds
    );
    
    event OptionGroupSettled(uint256 indexed optionGroupId, uint8 winningOptionIndex);
    event WinningsClaimed(uint256 indexed optionGroupId, address indexed user, uint256 amount);
    event LiquidityRemoved(uint256 indexed optionGroupId, address indexed provider, uint256 amount);
    event FeesCollected(uint256 indexed optionGroupId, uint256 amount);
    event OptionGroupCanceled(uint256 indexed optionGroupId);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event EarlyExit(uint256 indexed optionGroupId, address indexed user, uint256 optionIndex, uint256 betAmount, uint256 exitAmount, uint256 indexed betId);
    event EarlyExitFeeUpdated(uint256 oldFee, uint256 newFee);
    event BetRefunded(uint256 indexed optionGroupId, address indexed user, uint256 amount, uint256 betId);
    
    event PoolBet(
        address indexed wallet, 
        uint256 indexed poolId, 
        uint256 optionIndex, 
        uint256 amount,
        uint256 potentialReturn,
        uint256 lockedOdds
    );
    
    event OddsChanged(
        uint256 indexed poolId, 
        uint256[] odds,
        uint256 totalLiquidity,
        uint256[] optionLiquidity
    );
    
    event DefaultLiquidityConfigured(bool enabled, uint256 amount);
    event DefaultLiquidityAttempted(uint256 optionGroupId, bool configEnabled);
    event DefaultLiquiditySuccess(uint256 optionGroupId, uint256 amount);
    event DefaultLiquidityFailed(uint256 optionGroupId, string reason);
    event DefaultLiquidityCheckpoint(uint256 optionGroupId, string checkpoint);

    constructor(address _bondingContract, address _stakingContract, address _bettingToken, address _betLedgerAddress) Ownable(msg.sender) {
        require(_bondingContract != address(0), "Invalid bonding contract address");
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_bettingToken != address(0), "Invalid betting token address");
        require(_betLedgerAddress != address(0), "Invalid BetLedger address"); // Add check for BetLedger
        bondingContract = IHiloBonding(_bondingContract);
        stakingContract = IHiloStaking(_stakingContract);
        bettingToken = IERC20(_bettingToken);
        betLedgerContract = IBetLedger(_betLedgerAddress); // Set BetLedger address
    }

    /**
     * @notice Configure the default liquidity settings
     * @param _enabled Whether to enable default liquidity
     * @param _amount Amount of tokens to provide as default liquidity (if 0, keeps current amount)
     */
    function configureDefaultLiquidity(bool _enabled, uint256 _amount) external onlyOwner {
        defaultLiquidityEnabled = _enabled;
        
        if (_amount > 0) {
            defaultLiquidityAmount = _amount;
        }
        
        emit DefaultLiquidityConfigured(_enabled, defaultLiquidityAmount);
    }

    // Use MarketMath library for odds calculation in _emitOddsChanged
    function _emitOddsChanged(uint256 _optionGroupId) private {
        OptionGroup storage group = optionGroups[_optionGroupId];
        uint256 totalRemainingLiq = MarketMath.calculateTotalRemainingLiquidity(group.currentLiquidity, group.initialLiquidity);
        uint256 optionsCount = group.options.length;
        uint256[] memory newOdds = new uint256[](optionsCount);
        uint256[] memory optionLiquidity = new uint256[](optionsCount);

        for (uint256 i = 0; i < optionsCount; i++) {
            newOdds[i] = MarketMath.calculateOddsForOption(group.currentLiquidity[i], totalRemainingLiq, PRECISION);
            optionLiquidity[i] = group.currentLiquidity[i];
        }
        
        // Use totalRemainingLiq consistent with odds calc
        emit OddsChanged(_optionGroupId, newOdds, totalRemainingLiq, optionLiquidity);
    }
    
    // Helper function to reduce stack depth - initializes arrays only
    function _initializeOptionGroupArrays(uint256 _optionGroupId, uint256 optionsCount) private {
        OptionGroup storage group = optionGroups[_optionGroupId];
        group.initialLiquidity = new uint256[](optionsCount);
        group.currentLiquidity = new uint256[](optionsCount);
        group.totalBets = new uint256[](optionsCount);
    }

    // Initialize option group data - handles full option group setup
    function _initializeOptionGroup(OptionGroup storage group, string[] memory _options) private {
        uint256 optionsCount = _options.length;
        for (uint256 i = 0; i < optionsCount; i++) {
            group.options.push(Option({ name: _options[i], index: i }));
        }
        group.initialLiquidity = new uint256[](optionsCount);
        group.currentLiquidity = new uint256[](optionsCount);
        group.totalBets = new uint256[](optionsCount);
    }

    /**
     * @notice Helper function to add default liquidity
     * @dev Extracted to separate function to avoid stack depth issues
     */
    function _tryAddDefaultLiquidity(uint256 _optionGroupId) private {
        emit DefaultLiquidityAttempted(_optionGroupId, defaultLiquidityEnabled);
        if (!defaultLiquidityEnabled) {
            emit DefaultLiquidityFailed(_optionGroupId, "Default liquidity disabled");
            return;
        }
        emit DefaultLiquidityCheckpoint(_optionGroupId, "Configuration check passed");
        
        OptionGroup storage group = optionGroups[_optionGroupId];
        uint256 optionsCount = group.options.length;
        if (optionsCount == 0) {
             emit DefaultLiquidityFailed(_optionGroupId, "No options in group");
            return;
        }
        if (defaultLiquidityAmount == 0) {
             emit DefaultLiquidityFailed(_optionGroupId, "Default amount is zero");
             return;
        }
        emit DefaultLiquidityCheckpoint(_optionGroupId, "Checks passed");
        
        uint256 amountPerOption = defaultLiquidityAmount / optionsCount;
        if (amountPerOption == 0) {
             emit DefaultLiquidityFailed(_optionGroupId, "Amount per option is zero (total amount too small)");
             return;
        }
        emit DefaultLiquidityCheckpoint(_optionGroupId, "Amount per option calculated");

        uint256 totalDefaultAmount = amountPerOption * optionsCount;
        // Check if contract has enough balance *to cover this addition*
        if (bettingToken.balanceOf(address(this)) < totalDefaultAmount) {
            emit DefaultLiquidityFailed(_optionGroupId, "Insufficient contract balance for default liquidity");
            return;
        }
        emit DefaultLiquidityCheckpoint(_optionGroupId, "Balance checked");

        // Add liquidity to the group
        for (uint256 i = 0; i < optionsCount; i++) {
            group.initialLiquidity[i] += amountPerOption; // Track contribution
            group.currentLiquidity[i] += amountPerOption; // Add to AMM pool
        }

        group.totalLiquidity += totalDefaultAmount; // Track total LP contribution

        // Record contract as provider for this default liquidity
        address self = address(this);
        if (group.liquidityProviders[self] == 0) {
             if (!isProviderInList(group.liquidityProvidersList, self)) { // Prevent duplicates if called multiple times somehow
                 group.liquidityProvidersList.push(self);
             }
        }
        group.liquidityProviders[self] += totalDefaultAmount;

        emit DefaultLiquiditySuccess(_optionGroupId, totalDefaultAmount);
        emit LiquidityAdded(_optionGroupId, self, totalDefaultAmount);
        _emitOddsChanged(_optionGroupId); // Emit odds after adding liquidity
    }

    // Helper to check if address is already in the provider list
    function isProviderInList(address[] storage list, address provider) private view returns (bool) {
        for (uint i = 0; i < list.length; i++) {
            if (list[i] == provider) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Pause the contract in emergency situations
     */
    function pause() external onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }
    
    /**
     * @notice Unpause the contract when emergency is resolved
     */
    function unpause() external onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }
    
    function createOptionGroup(uint256 _optionGroupId, uint256 _poolId, string[] calldata _optionNames) external whenNotPaused {
        require(stakingContract.getPoolCreatorStake(msg.sender) > 0, "Not a pool creator");
        require(!optionGroups[_optionGroupId].initialized, "Option group already exists");
        uint256 optionsCount = _optionNames.length;
        require(optionsCount >= 2, "Need at least 2 options");

        (,, uint256 startTimeframe,, ) = bondingContract.getPoolBasics(_poolId);
        require(block.timestamp < startTimeframe, "Pool already started");

        (string[] memory bondingOptions, bool hasOptions) = bondingContract.getPoolOptions(_poolId);
        if (hasOptions) {
            require(bondingOptions.length == optionsCount, "Option count mismatch with bonding contract");
            for (uint256 i = 0; i < optionsCount; i++) {
                require(keccak256(bytes(bondingOptions[i])) == keccak256(bytes(_optionNames[i])), "Option names mismatch");
            }
        } else {
            bondingContract.setPoolOptions(_poolId, _optionNames);
        }

        OptionGroup storage group = optionGroups[_optionGroupId];
        group.poolId = _poolId;
        group.initialized = true;
        group.settleTimeframe = startTimeframe + 7 days; // Example alignment

        // Initialize the option group using our helper
        _initializeOptionGroup(group, _optionNames);

        emit OptionGroupCreated(_optionGroupId, _poolId, optionsCount);
        
        // Add default liquidity if enabled
        _tryAddDefaultLiquidity(_optionGroupId);
    }

    function createPoolAndOptionGroup(
        uint256 _poolId,
        uint256 _optionGroupId,
        string calldata _poolTitle,
        uint256 _startTimeframe,
        uint256 _settleTimeframe,
        string calldata _data,
        string[] calldata _optionNames
    ) external nonReentrant whenNotPaused {
        require(stakingContract.getPoolCreatorStake(msg.sender) > 0, "Not a pool creator");
        require(!optionGroups[_optionGroupId].initialized, "Option group already exists");
        uint256 optionsCount = _optionNames.length;
        require(optionsCount >= 2, "Need at least 2 options");
        require(_startTimeframe > block.timestamp, "Start time in past");
        require(_settleTimeframe > _startTimeframe, "Invalid settle time");

        bondingContract.createPool(_poolId, _poolTitle, _startTimeframe, _settleTimeframe, _data, msg.sender);
        bondingContract.setPoolOptions(_poolId, _optionNames);

        // Initialize the option group
        OptionGroup storage group = optionGroups[_optionGroupId];
        group.poolId = _poolId;
        group.initialized = true;
        group.settleTimeframe = _settleTimeframe;

        // Use helper for option initialization
        _initializeOptionGroup(group, _optionNames);
        
        // Get timeline information directly for the event
        (,, , uint256 evaluationEnd, uint256 disputeEnd) = bondingContract.getPoolBasics(_poolId);
        
        // Simplify calculation to avoid overflow
        // Just use a value in the middle of evaluation end and dispute end
        uint256 optionVotingEnd = evaluationEnd + ((disputeEnd - evaluationEnd) / 2);

        // Emit event with timeline information
        emit PoolAndOptionGroupCreated(
            _poolId,
            _optionGroupId,
            _poolTitle,
            _startTimeframe,
            _settleTimeframe,
            _data,
            _optionNames,
            evaluationEnd,
            optionVotingEnd,
            disputeEnd
        );
        
        // Add default liquidity if enabled
        _tryAddDefaultLiquidity(_optionGroupId);
    }

    function addLiquidity(uint256 _optionGroupId, uint256 _amount) external nonReentrant whenNotPaused {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        
        // Determine if this is a call from the contract itself for default liquidity
        bool isFromContract = (msg.sender == address(this));
        
        // Skip validation for contract default liquidity
        if (!isFromContract) {
            require(!group.settled && !group.canceled, "Option group settled or canceled");
            (,, uint256 startTimeframe,, ) = bondingContract.getPoolBasics(group.poolId);
            require(block.timestamp < startTimeframe, "Pool already started");
            
            // Transfer tokens from external caller
            bettingToken.safeTransferFrom(msg.sender, address(this), _amount);
        }
        // No token transfer needed for default liquidity (contract already has the tokens)
        
        // Safety check for empty options array (shouldn't happen, but just in case)
        uint256 optionsCount = group.options.length;
        if (optionsCount == 0) {
            if (!isFromContract) {
                bettingToken.safeTransfer(msg.sender, _amount); // Return tokens to external caller
            }
            return;
        }
        
        uint256 amountPerOption = _amount / optionsCount;

        // Update totals - track liquidity provider's contribution
        if (group.liquidityProviders[msg.sender] == 0) {
            group.liquidityProvidersList.push(msg.sender);
        }
        group.liquidityProviders[msg.sender] += _amount;

        // Distribute liquidity equally among all options
        for (uint256 i = 0; i < optionsCount; i++) {
            group.initialLiquidity[i] += amountPerOption;
            group.currentLiquidity[i] += amountPerOption;
        }

        // Use simplified logic during initialization to avoid complex calculations
        if (isFromContract) {
            // Simple constant product calculation for initialization
            // K is no longer stored, remove related assignments
            // if (optionsCount == 2) {
            //     uint256 initialPerOption = amountPerOption;
            //     // REMOVED: group.k = initialPerOption * initialPerOption * PRECISION;
            // } else {
            //     // REMOVED: group.k = (_amount * _amount * PRECISION) / optionsCount;
            // }
            } else {
            // Standard path for normal liquidity addition - K update removed
            // REMOVED: updateConstantProduct(_optionGroupId);
        }
        
        // Recalculate totalLiquidity to include current liquidity values
        uint256 currentTotal = 0;
        for (uint256 i = 0; i < optionsCount; i++) {
            currentTotal += group.currentLiquidity[i];
            // Add any reserves (using our Excel calculation approach)
            currentTotal += calculateReserve(group.initialLiquidity[i], group.currentLiquidity[i]);
        }
        group.totalLiquidity = currentTotal;
        
        _emitOddsChanged(_optionGroupId);
        emit LiquidityAdded(_optionGroupId, msg.sender, _amount);
    }

    // Helper function to calculate reserve based on Excel approach
    function calculateReserve(uint256 initialLiq, uint256 currentLiq) private pure returns (uint256) {
        return currentLiq >= initialLiq ? 0 : initialLiq - currentLiq;
    }
    
    // UPDATED: CPMM implementation of constant product calculation with PRECISION scaling
    function updateConstantProduct(uint256 _optionGroupId) internal {
        OptionGroup storage group = optionGroups[_optionGroupId];
        
        // For binary markets (2 options), use simple X * Y = K with scaling by PRECISION to avoid overflow
        if (group.options.length == 2) {
            // Check if both options have liquidity
            if (group.currentLiquidity[0] > 0 && group.currentLiquidity[1] > 0) {
                // Scale one of the values by PRECISION to avoid overflow
                // k = (x * PRECISION) * (y / PRECISION) = x * y
                uint256 scaledLiq0 = (group.currentLiquidity[0] * PRECISION);
                uint256 scaledLiq1 = group.currentLiquidity[1];
                // k = scaledLiq0 * scaledLiq1; // This is effectively k * PRECISION
                return;
            }
        }
        
        // For multiple options or if one option has zero liquidity,
        // use a geometric mean approach with scaling
        uint256 totalLiq = calculateRemainingLiquidity(_optionGroupId);
        if (totalLiq > 0) {
            // For safety, use a simpler squared approach with scaling
            if (totalLiq <= (type(uint256).max / PRECISION) / totalLiq) {
                // k = (totalLiq * totalLiq * PRECISION); // Scale by PRECISION
            } else {
                // If we'd overflow, scale down the total first
                uint256 scaledTotal = totalLiq / 1000;
                // k = (scaledTotal * scaledTotal * PRECISION * 1000000); // Scale back up appropriately
            }
        } else {
            // k = PRECISION; // Default to PRECISION if total is zero to avoid division by zero later
        }
    }

    // Helper function to process Yes bets - Excel aligned approach
    function _processYesBet(
        OptionGroup storage group,
        uint256 _amount
    ) private {
        // Calculate excess (net value) before this bet
        uint256 totalYesBets = group.totalBets[0];
        uint256 totalNoBets = group.totalBets[1];
        
        // Calculate excess using Excel formula approach
        uint256 excess1 = 0;
        uint256 excess2 = 0;
        
        if (totalYesBets > totalNoBets) {
            excess1 = totalYesBets - totalNoBets;
        } else {
            excess2 = totalNoBets - totalYesBets;
        }
        
        // Reserve calculations exactly as in Excel: =IF(I9>=$I$8,0,I$8-I9)
        uint256 reserveX = group.currentLiquidity[0] >= group.initialLiquidity[0] ? 0 : group.initialLiquidity[0] - group.currentLiquidity[0];
        uint256 reserveY = group.currentLiquidity[1] >= group.initialLiquidity[1] ? 0 : group.initialLiquidity[1] - group.currentLiquidity[1];
        
        // Get initial K exactly as in Excel: Constant K = I8*J8
        uint256 initialK = group.initialLiquidity[0] * group.initialLiquidity[1];
        
        // Handle all cases from Excel IFS function:
        // =IFS(AND(C9>0,G8=0),I8+C9,AND(C9>0,G8>0),I8+C9,AND(C9>0,G8<0),I8+C9*M8/H8,...)
        uint256 newLiquidityOption1;
        uint256 newLiquidityOption2;
        
        if (excess1 == 0 && excess2 == 0) {
            // Case: AND(C9>0,G8=0) - No excess
            newLiquidityOption1 = group.currentLiquidity[0] + _amount;
        } else if (excess1 > 0) {
            // Case: AND(C9>0,G8>0) - Yes has excess
            newLiquidityOption1 = group.currentLiquidity[0] + _amount;
        } else if (excess2 > 0 && reserveX > 0) {
            // Case: AND(C9>0,G8<0) - No has excess, scale by reserveX/excess2
            uint256 scaleFactor = (reserveX * PRECISION) / excess2;
            uint256 scaledBet = (_amount * scaleFactor) / PRECISION;
            newLiquidityOption1 = group.currentLiquidity[0] + scaledBet;
        } else {
            // Default case
            newLiquidityOption1 = group.currentLiquidity[0] + _amount;
        }
        
        // Calculate new liquidity for opposite option using K (constant product)
        newLiquidityOption2 = initialK / newLiquidityOption1;
        
        // Update state with new liquidity values
        group.currentLiquidity[0] = newLiquidityOption1;
        group.currentLiquidity[1] = newLiquidityOption2;
        
        // Recalculate total liquidity
        group.totalLiquidity = newLiquidityOption1 + newLiquidityOption2 + 
                              (group.currentLiquidity[0] >= group.initialLiquidity[0] ? 0 : group.initialLiquidity[0] - group.currentLiquidity[0]) + 
                              (group.currentLiquidity[1] >= group.initialLiquidity[1] ? 0 : group.initialLiquidity[1] - group.currentLiquidity[1]);
    }
    
    // Helper function to process No bets with exact Excel formula alignment
    function _processNoBet(
        OptionGroup storage group,
        uint256 _amount
    ) private {
        // Calculate excess (net value) before this bet
        uint256 totalYesBets = group.totalBets[0];
        uint256 totalNoBets = group.totalBets[1];
        
        // Calculate excess using Excel formula approach
        uint256 excess1 = 0;
        uint256 excess2 = 0;
        
        if (totalYesBets > totalNoBets) {
            excess1 = totalYesBets - totalNoBets;
        } else {
            excess2 = totalNoBets - totalYesBets;
        }
        
        // Reserve calculations exactly as in Excel: =IF(J9>=$J$8,0,J$8-J9)
        uint256 reserveX = group.currentLiquidity[0] >= group.initialLiquidity[0] ? 0 : group.initialLiquidity[0] - group.currentLiquidity[0];
        uint256 reserveY = group.currentLiquidity[1] >= group.initialLiquidity[1] ? 0 : group.initialLiquidity[1] - group.currentLiquidity[1];
        
        // Get initial K exactly as in Excel: Constant K = I8*J8
        uint256 initialK = group.initialLiquidity[0] * group.initialLiquidity[1];
        
        // Handle all cases from Excel IFS function for No bets:
        // =IFS(AND(D9>0,H8=0),J8+D9,AND(D9>0,H8>0),J8+D9,AND(D9>0,H8<0),J8+D9*N8/G8,...)
        uint256 newLiquidityOption1;
        uint256 newLiquidityOption2;
        
        if (excess1 == 0 && excess2 == 0) {
            // Case: AND(D9>0,H8=0) - No excess
            newLiquidityOption2 = group.currentLiquidity[1] + _amount;
        } else if (excess2 > 0) {
            // Case: AND(D9>0,H8>0) - No has excess
            newLiquidityOption2 = group.currentLiquidity[1] + _amount;
        } else if (excess1 > 0 && reserveY > 0) {
            // Case: AND(D9>0,H8<0) - Yes has excess, scale by reserveY/excess1
            uint256 scaleFactor = (reserveY * PRECISION) / excess1;
            uint256 scaledBet = (_amount * scaleFactor) / PRECISION;
            newLiquidityOption2 = group.currentLiquidity[1] + scaledBet;
        } else {
            // Default case
            newLiquidityOption2 = group.currentLiquidity[1] + _amount;
        }
        
        // Calculate new liquidity for opposite option using K (constant product)
        newLiquidityOption1 = initialK / newLiquidityOption2;
        
        // Update state with new liquidity values
        group.currentLiquidity[0] = newLiquidityOption1;
        group.currentLiquidity[1] = newLiquidityOption2;
        
        // Recalculate total liquidity with reserves
        group.totalLiquidity = newLiquidityOption1 + newLiquidityOption2 + 
                              (group.currentLiquidity[0] >= group.initialLiquidity[0] ? 0 : group.initialLiquidity[0] - group.currentLiquidity[0]) + 
                              (group.currentLiquidity[1] >= group.initialLiquidity[1] ? 0 : group.initialLiquidity[1] - group.currentLiquidity[1]);
    }

    // Updated process bet function to match Excel calculations exactly
    function _processBet(
        OptionGroup storage group,
        uint256 _optionGroupId,
        uint256 _optionIndex,
        uint256 _amount,
        uint256 _minOdds
    ) private {
        // Check if pool has liquidity
        uint256 totalLiquidity = calculateRemainingLiquidity(_optionGroupId);
        require(totalLiquidity > 0, "Pool has no liquidity");
        
        // First update total bets
        group.totalBets[_optionIndex] += _amount;
        
    
        // Process bets based on market type
        if (group.options.length == 2) {
            // Process binary markets (Yes/No)
            if (_optionIndex == 0) {
                _processYesBet(group, _amount);
            } else {
                _processNoBet(group, _amount);
            }
        } else {
            // For non-binary markets (more than 2 options), use a simpler approach
            // Add bet amount to the option liquidity
            group.currentLiquidity[_optionIndex] += _amount;
            group.totalLiquidity += _amount;
            
            // Update constant product for all options
            updateConstantProduct(_optionGroupId);
        }
        
        // Check if odds are acceptable
        uint256 optionLiquidity = group.currentLiquidity[_optionIndex];
        require(optionLiquidity > 0, "Option liquidity cannot be zero");
        
        uint256 newOdds = (calculateRemainingLiquidity(_optionGroupId) * PRECISION) / optionLiquidity;
        require(newOdds >= _minOdds, "Odds too low after bet");
        
        // Calculate potential return and emit events
        // Ignore rawReturn here as these functions are likely deprecated/internal helpers
        (uint256 potentialReturn, uint256 lockedOdds, ) = calculatePotentialReturn(
            _optionGroupId, _optionIndex, _amount
        );
        emit BetPlaced(_optionGroupId, msg.sender, _optionIndex, _amount, potentialReturn, lockedOdds);
        _emitOddsChanged(_optionGroupId);
    }

    // Calculate net value between this option and all other options
    function calculateNetValue(uint256 _optionGroupId, uint256 _optionIndex) private view returns (int256) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        
        // For binary options, simply get the difference
        if (group.options.length == 2) {
            uint256 otherIndex = _optionIndex == 0 ? 1 : 0;
            return int256(group.totalBets[_optionIndex]) - int256(group.totalBets[otherIndex]);
        }
        
        // For multiple options, sum all other bets
        uint256 totalOtherSideBets = 0;
        for (uint256 i = 0; i < group.options.length; i++) {
            if (i != _optionIndex) {
                totalOtherSideBets += group.totalBets[i];
            }
        }
        
        return int256(group.totalBets[_optionIndex]) - int256(totalOtherSideBets);
    }

    /**
     * @notice Calculates the potential return and locked odds for a given bet amount.
     * @dev Assumes binary market. Fee is calculated on the raw profit.
     * @param _optionGroupId The ID of the option group.
     * @param _optionIndex The index of the option being bet on.
     * @param _amount The amount being bet.
     * @return potentialReturn The total amount the user would receive if the bet wins (amount + net profit).
     * @return lockedOdds The effective odds the user receives, scaled by PRECISION.
     * @return rawReturn The profit calculated by the AMM before any fees.
     */
    function calculatePotentialReturn(
        uint256 _optionGroupId,
        uint256 _optionIndex,
        uint256 _amount
    ) public view returns (uint256 potentialReturn, uint256 lockedOdds, uint256 rawReturn) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        require(_optionIndex < group.options.length, "Invalid option index");
        require(group.options.length == 2, "Potential return calc only supports binary");

        // Save the current liquidity state (to avoid stack too deep)
        uint256[] memory currentLiq = new uint256[](group.currentLiquidity.length);
        for (uint i = 0; i < currentLiq.length; i++) {
            currentLiq[i] = group.currentLiquidity[i];
        }

        // Calculate total remaining liquidity using full reserve calculation
        uint256 totalRemainingLiquidity = MarketMath.calculateTotalRemainingLiquidity(
            group.initialLiquidity,
            currentLiq
        );

        // Calculate the raw return from the CPMM formula (profit before fees)
        rawReturn = MarketMath.calculateBetRawReturnBinary(
            currentLiq[_optionIndex],
            currentLiq[1 - _optionIndex],
            _amount
        );

        // Calculate locked odds using the exact formula from React implementation
        uint256 tokensExtracted = rawReturn; // This is equivalent to liquidityOption2 - newLiquidityOption2
        uint256 extractionRatio = (tokensExtracted * PRECISION) / _amount;
        uint256 feeAdjustedRatio = (extractionRatio * (PRECISION - platformFee)) / PRECISION;
        lockedOdds = PRECISION + feeAdjustedRatio;

        // Apply platformFee to raw profit
        uint256 feeAmount = (rawReturn * platformFee) / PRECISION;
        
        // Total return = original bet amount + (raw profit - fee)
        potentialReturn = _amount + rawReturn - feeAmount;
        
        return (potentialReturn, lockedOdds, rawReturn);
    }

    /**
     * @notice Place a bet on a specific option
     */
    function placeBet(
        uint256 _optionGroupId,
        uint256 _optionIndex,
        uint256 _amount,
        uint256 _minOdds // Minimum odds user is willing to accept (scaled by PRECISION)
    ) external nonReentrant whenNotPaused {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        require(!group.settled && !group.canceled, "Option group settled or canceled");
        require(_optionIndex < group.options.length, "Invalid option index");
        require(_amount > 0, "Amount must be positive");

        // Check if betting is allowed based on bonding contract status
        (bool processed, , bool finalApproval, , ) = bondingContract.getPoolStatus(group.poolId);
        ( , , uint256 startTimeframe, uint256 evaluationEnd, ) = bondingContract.getPoolBasics(group.poolId);
        require(!processed || (processed && finalApproval), "Pool is not approved or already processed");
        require(block.timestamp >= startTimeframe, "Betting not started yet");
        require(block.timestamp < group.settleTimeframe, "Betting window closed");

        // Transfer tokens from bettor
        bettingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Always use the full React formula approach - calculate state changes EXACTLY like the React app
        uint256 potentialReturn;
        uint256 lockedOdds;
        uint256 rawReturn;
        
        // This is a binary market
        require(group.options.length == 2, "Current implementation supports binary only");
        
        // Get total bets for excess calculations
        uint256 totalYesBets = group.totalBets[0];
        uint256 totalNoBets = group.totalBets[1];
        
        // Calculate excess exactly as in React
        int256 excess1 = int256(totalYesBets) - int256(totalNoBets);
        
        // Calculate reserves exactly as in React
        uint256 reserveX = group.currentLiquidity[0] >= group.initialLiquidity[0] ? 0 : group.initialLiquidity[0] - group.currentLiquidity[0];
        uint256 reserveY = group.currentLiquidity[1] >= group.initialLiquidity[1] ? 0 : group.initialLiquidity[1] - group.currentLiquidity[1];
        
        // Get the opposite option index
        uint256 oppositeIndex = 1 - _optionIndex;
        
        // Calculate based on constant product formula, exactly as in React
        uint256 initialK = group.initialLiquidity[0] * group.initialLiquidity[1];
        uint256 currentLiqThis = group.currentLiquidity[_optionIndex];
        uint256 currentLiqOther = group.currentLiquidity[oppositeIndex];
        
        // Calculate new liquidities after the bet WITH PROPER SCALING EXACTLY LIKE REACT
        uint256 newLiqThis;
        
        if (_optionIndex == 0) { // Yes bet
            if (excess1 < 0 && reserveX > 0) { // No has excess
                // Scale bet by reserveX / |excess1|
                uint256 scaleFactor = (reserveX * PRECISION) / uint256(-excess1);
                uint256 scaledBet = (_amount * scaleFactor) / PRECISION;
                newLiqThis = currentLiqThis + scaledBet;
            } else {
                // Standard formula when Yes has no excess or positive excess
                newLiqThis = currentLiqThis + _amount;
            }
        } else { // No bet
            if (excess1 > 0 && reserveY > 0) { // Yes has excess
                // Scale bet by reserveY / excess1
                uint256 scaleFactor = (reserveY * PRECISION) / uint256(excess1);
                uint256 scaledBet = (_amount * scaleFactor) / PRECISION;
                newLiqThis = currentLiqThis + scaledBet;
            } else {
                // Standard formula when No has no excess or positive excess
                newLiqThis = currentLiqThis + _amount;
            }
        }
        
        // Calculate opposite side liquidity using constant k
        uint256 newLiqOther = initialK / newLiqThis;
        
        // Calculate extracted tokens (exactly as in React)
        rawReturn = currentLiqOther > newLiqOther ? currentLiqOther - newLiqOther : 0;
        uint256 extractionRatio = (rawReturn * PRECISION) / _amount;
        uint256 feeAdjustedRatio = (extractionRatio * (PRECISION - platformFee)) / PRECISION;
        lockedOdds = PRECISION + feeAdjustedRatio;
        
        // Calculate fee
        uint256 feeAmount = (rawReturn * platformFee) / PRECISION;
        
        // Calculate final return
        potentialReturn = _amount + rawReturn - feeAmount;
        
        // Check locked odds
        require(lockedOdds >= _minOdds, "Odds too low before bet execution");
        
        // Update state
        group.totalFees += feeAmount;
        group.totalBets[_optionIndex] += _amount;
        
        // Record bet in ledger
        uint256 betId = betLedgerContract.recordBet(
            msg.sender,
            _optionGroupId,
            _optionIndex,
            _amount,
            potentialReturn,
            block.timestamp,
            lockedOdds
        );
        
        // Update liquidity pools
        group.currentLiquidity[_optionIndex] = newLiqThis;
        group.currentLiquidity[oppositeIndex] = newLiqOther;
        
        // Update total liquidity with reserves
        group.totalLiquidity = newLiqThis + newLiqOther +
                             (group.currentLiquidity[0] >= group.initialLiquidity[0] ? 0 : group.initialLiquidity[0] - group.currentLiquidity[0]) +
                             (group.currentLiquidity[1] >= group.initialLiquidity[1] ? 0 : group.initialLiquidity[1] - group.currentLiquidity[1]);
        
        // Emit events
        emit BetPlaced(_optionGroupId, msg.sender, _optionIndex, _amount, potentialReturn, lockedOdds);
        emit PoolBet(msg.sender, _optionGroupId, _optionIndex, _amount, potentialReturn, lockedOdds);
        _emitOddsChanged(_optionGroupId);
    }

    // Rewritten earlyExit function to use BetLedger and offsetting logic
    function earlyExit(uint256 _betId) external nonReentrant whenNotPaused {
        // 1. Fetch Bet Details from BetLedger
        IBetLedger.Bet memory bet = betLedgerContract.getBetDetails(_betId);

        // 2. Validate the Request
        require(bet.id == _betId && bet.id != 0, "EarlyExit: Invalid bet ID");
        require(bet.user == msg.sender, "EarlyExit: Caller is not the bet owner");
        require(bet.status == IBetLedger.BetStatus.Active, "EarlyExit: Bet not active");

        uint256 optionGroupId = bet.optionGroupId;
        OptionGroup storage group = optionGroups[optionGroupId];
        require(group.initialized, "EarlyExit: Option group does not exist");
        require(!group.settled && !group.canceled, "EarlyExit: Option group settled or canceled");
        require(group.options.length == 2, "EarlyExit: Only binary markets supported"); // Required by calc

        (,, uint256 startTimeframe,, uint256 settleTimeframe) = bondingContract.getPoolBasics(group.poolId);
        require(block.timestamp >= startTimeframe, "EarlyExit: Pool not started yet");
        require(block.timestamp < settleTimeframe, "EarlyExit: Pool betting period ended");

        // 3. Get Current Market State
        uint256 currentLiqOpt1 = group.currentLiquidity[0];
        uint256 currentLiqOpt2 = group.currentLiquidity[1];
        uint256 feePercent = earlyExitFee; // Already stored in this contract
        // uint256 precision = PRECISION; // Already a constant

        // Calculate K based on initial liquidity assumption (matches view function)
        // Note potential inaccuracy if liquidity added/removed asymmetrically
        uint256 constantK = 0;
        if (group.initialLiquidity[0] > 0 && group.initialLiquidity[1] > type(uint256).max / group.initialLiquidity[0]) {
             revert("EarlyExit: K calculation overflow risk");
        } else {
             constantK = group.initialLiquidity[0] * group.initialLiquidity[1];
        }
        require(constantK > 0, "EarlyExit: Cannot calculate with zero K");

        // 4. Calculate Raw Cashout Value (Offsetting Bet Logic)
        uint256 profitPortion = bet.potentialPayout > bet.amount ? bet.potentialPayout - bet.amount : 0;
        uint256 calculatedCashoutRaw = 0;
        uint256 simulatedLiqOpt1 = 0;
        uint256 simulatedLiqOpt2 = 0;

        // Replicate logic from BetLedger.calculateOffsettingBetExit
        if (bet.optionIndex == 0) { // Original bet was on Option 1 (Yes)
            simulatedLiqOpt2 = currentLiqOpt2 + profitPortion;
            require(simulatedLiqOpt2 > 0, "EarlyExit: Simulated liq2 is zero");
            simulatedLiqOpt1 = constantK / simulatedLiqOpt2;
            calculatedCashoutRaw = currentLiqOpt1 > simulatedLiqOpt1 ? currentLiqOpt1 - simulatedLiqOpt1 : 0;
        } else { // Original bet was on Option 2 (No)
            simulatedLiqOpt1 = currentLiqOpt1 + profitPortion;
            require(simulatedLiqOpt1 > 0, "EarlyExit: Simulated liq1 is zero");
            simulatedLiqOpt2 = constantK / simulatedLiqOpt1;
            calculatedCashoutRaw = currentLiqOpt2 > simulatedLiqOpt2 ? currentLiqOpt2 - simulatedLiqOpt2 : 0;
        }

        // 5. Apply Fee (Matching simulator: fee on profit portion)
        // uint256 profitInCashout = calculatedCashoutRaw > bet.amount ? calculatedCashoutRaw - bet.amount : 0;
        // uint256 fee = (profitInCashout * feePercent) / PRECISION;

        // Alternative: Apply Fee (Matching original contract: fee on whole value)
        uint256 fee = (calculatedCashoutRaw * feePercent) / PRECISION;

        uint256 exitAmount = calculatedCashoutRaw > fee ? calculatedCashoutRaw - fee : 0;

        // 6. Check Contract Balance
        require(exitAmount <= bettingToken.balanceOf(address(this)), "EarlyExit: Contract insufficient balance");

        // --- Update State --- 

        // 7. Update HiloPredictionMarket State
        // Update liquidity pools to match the state *after* the simulated offsetting bet
        group.currentLiquidity[0] = simulatedLiqOpt1;
        group.currentLiquidity[1] = simulatedLiqOpt2;
        // Update total fees collected
        group.totalFees += fee;
        // No longer update totalBets or userBets here

        // 8. Update BetLedger State
        betLedgerContract.updateBetStatus(_betId, IBetLedger.BetStatus.CashedOut);

        // 9. Transfer Tokens
        if (exitAmount > 0) { // Only transfer if there's something to send
             bettingToken.safeTransfer(msg.sender, exitAmount);
        }

        // 10. Emit Event
        emit EarlyExit(optionGroupId, msg.sender, bet.optionIndex, bet.amount, exitAmount, _betId);
        _emitOddsChanged(optionGroupId); // Reflect odds change after liquidity update
    }

    /**
     * @notice Settle an option group based on the result from the bonding contract
     * @param _optionGroupId The ID of the option group
     * @param _winningOptionIndex The index of the winning option
     */
    function settleOptionGroup(uint256 _optionGroupId, uint8 _winningOptionIndex) external nonReentrant {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        require(!group.settled && !group.canceled, "Option group settled or canceled");
        require(_winningOptionIndex < group.options.length, "Invalid winning option index");

        // Check if the pool is effectively processed, even if not explicitly processed
        (bool processed,, bool finalApproval,, uint256 bondedWinningIndex) = bondingContract.getPoolStatus(group.poolId);
        require(processed, "Pool not processed yet");
        require(finalApproval, "Pool was not approved");
        require(block.timestamp >= group.settleTimeframe, "Settlement timeframe not reached");
        require(_winningOptionIndex == bondedWinningIndex, "Winning index mismatch with bonding");

        // Check if any bets were placed
        bool anyBets = false;
        for (uint256 i = 0; i < group.options.length; i++) {
            if (group.totalBets[i] > 0) {
                anyBets = true;
                break;
            }
        }
        
        // Handle special case: no liquidity added but bets were placed
        uint256 totalLiquidity = calculateRemainingLiquidity(_optionGroupId);
        if (totalLiquidity == 0 && anyBets) {
            // Still allow settlement for zero-liquidity pools with bets
            group.winningOptionIndex = _winningOptionIndex;
            group.settled = true;
            emit OptionGroupSettled(_optionGroupId, _winningOptionIndex);
            return;
        }
        
        // Regular settlement
        group.winningOptionIndex = _winningOptionIndex;
        group.settled = true;
        emit OptionGroupSettled(_optionGroupId, _winningOptionIndex);
    }

    // UPDATED: claimWinnings with CPMM-aligned zero liquidity handling
    function claimWinnings(uint256 _optionGroupId) external nonReentrant {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        
        // If not settled yet, check if we can automatically settle
        if (!group.settled) {
            (bool processed,, bool finalApproval,, uint256 bondedWinningIndex) = bondingContract.getPoolStatus(group.poolId);
            
            // Auto-settle if conditions are met
            if (processed && finalApproval && block.timestamp >= group.settleTimeframe && bondedWinningIndex < group.options.length) {
                group.winningOptionIndex = uint8(bondedWinningIndex);
                group.settled = true;
                emit OptionGroupSettled(_optionGroupId, uint8(bondedWinningIndex));
            } else {
                revert("Option group not settled");
            }
        }

        uint8 winningIndex = group.winningOptionIndex;
        uint256 betAmount = group.totalBets[winningIndex];
        require(betAmount > 0, "No winning bets");

        uint256 totalLiquidity = calculateRemainingLiquidity(_optionGroupId);
        uint256 potentialReturn;
        
        // UPDATED: Modified zero liquidity handling for CPMM
        if (totalLiquidity == 0) {
            // For zero liquidity pools, we'll distribute winnings proportionally based on total bets
            uint256 totalBets = 0;
            uint256 totalWinningBets = 0;
            
            for (uint256 i = 0; i < group.options.length; i++) {
                totalBets += group.totalBets[i];
                if (i == winningIndex) {
                    totalWinningBets = group.totalBets[i];
                }
            }
            
            if (totalBets > totalWinningBets && totalWinningBets > 0) {
                // Calculate share of the losing bets
                potentialReturn = (betAmount * (totalBets - totalWinningBets)) / totalWinningBets;
            } else {
                // Fallback to previous calculation if we can't determine a fair distribution
                potentialReturn = betAmount * (group.options.length - 1);
            }
        } else {
            // Normal calculation using potential return function
            // Ignore rawReturn and lockedOdds here as only potentialReturn is needed for fee calc
            (potentialReturn, , ) = calculatePotentialReturn(_optionGroupId, winningIndex, betAmount);
        }
        
        uint256 fee = (potentialReturn * platformFee) / PRECISION;
        uint256 winnings = potentialReturn - fee;

        group.totalFees += fee;
        group.totalBets[winningIndex] = 0;
        bettingToken.safeTransfer(msg.sender, betAmount + winnings);

        emit WinningsClaimed(_optionGroupId, msg.sender, betAmount + winnings);
    }

    // UPDATED: removeLiquidity with CPMM-aligned share calculation
    function removeLiquidity(uint256 _optionGroupId) external nonReentrant {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        
        // If not settled yet, check if we can automatically settle or cancel
        if (!group.settled && !group.canceled) {
            (bool processed,, bool finalApproval,, uint256 bondedWinningIndex) = bondingContract.getPoolStatus(group.poolId);
            
            if (processed) {
                if (finalApproval && block.timestamp >= group.settleTimeframe) {
                    // Auto-settle
                    group.winningOptionIndex = uint8(bondedWinningIndex);
                    group.settled = true;
                    emit OptionGroupSettled(_optionGroupId, uint8(bondedWinningIndex));
                } else if (!finalApproval) {
                    // Auto-cancel
                    group.canceled = true;
                    emit OptionGroupCanceled(_optionGroupId);
                } else {
                    revert("Option group not settled or canceled");
                }
            } else {
                revert("Option group not settled or canceled");
            }
        }

        uint256 providerLiquidity = group.liquidityProviders[msg.sender];
        require(providerLiquidity > 0, "No liquidity provided");

        // UPDATED: Calculate share based on CPMM principles
        uint256 totalRemaining = calculateRemainingLiquidity(_optionGroupId);
        
        // Provider's share is proportional to their contribution
        uint256 providerShare = (totalRemaining * providerLiquidity) / group.totalLiquidity;
        uint256 feeShare = (group.totalFees * providerLiquidity) / group.totalLiquidity;

        // Update state
        group.liquidityProviders[msg.sender] = 0;
        
        // Send tokens to provider
        bettingToken.safeTransfer(msg.sender, providerShare + feeShare);

        emit LiquidityRemoved(_optionGroupId, msg.sender, providerShare + feeShare);
    }

    function cancelOptionGroup(uint256 _optionGroupId) external nonReentrant {
        require(stakingContract.getValidatorStake(msg.sender) > 0, "Not a validator");

        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        require(!group.settled && !group.canceled, "Option group settled or canceled");

        (bool processed,, bool finalApproval,, ) = bondingContract.getPoolStatus(group.poolId);
        require(processed, "Pool not processed yet");
        require(!finalApproval, "Pool was approved");

        group.canceled = true;
        emit OptionGroupCanceled(_optionGroupId);
    }

    function refundBet(uint256 _optionGroupId, uint256 _optionIndex) external nonReentrant {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        
        // If not canceled yet, check if we can automatically cancel
        if (!group.canceled) {
            (bool processed,, bool finalApproval,, ) = bondingContract.getPoolStatus(group.poolId);
            
            if (processed && !finalApproval) {
                // Auto-cancel
                group.canceled = true;
                emit OptionGroupCanceled(_optionGroupId);
            } else {
                revert("Option group not canceled");
            }
        }

        uint256 betAmount = group.totalBets[_optionIndex];
        require(betAmount > 0, "No bet to refund");

        group.totalBets[_optionIndex] = 0;
        bettingToken.safeTransfer(msg.sender, betAmount);

        emit BetRefunded(_optionGroupId, msg.sender, betAmount, 0);
    }

    function updatePlatformFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= MAX_FEE, "Fee exceeds maximum");
        uint256 oldFee = platformFee;
        platformFee = _newFee;
        emit PlatformFeeUpdated(oldFee, _newFee);
    }

    function updateEarlyExitFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= MAX_FEE, "Fee exceeds maximum");
        uint256 oldFee = earlyExitFee;
        earlyExitFee = _newFee;
        emit EarlyExitFeeUpdated(oldFee, _newFee);
    }

    function getOdds(uint256 _optionGroupId, uint256 _optionIndex) external view returns (uint256 odds) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        require(_optionIndex < group.options.length, "Invalid option index");

        uint256 totalRemainingLiq = MarketMath.calculateTotalRemainingLiquidity(group.currentLiquidity, group.initialLiquidity);
        return MarketMath.calculateOddsForOption(group.currentLiquidity[_optionIndex], totalRemainingLiq, PRECISION);
    }

    function getAllOdds(uint256 _optionGroupId) external view returns (uint256[] memory allOdds) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        uint256 optionsCount = group.options.length;
        allOdds = new uint256[](optionsCount);
        uint256 totalRemainingLiq = MarketMath.calculateTotalRemainingLiquidity(group.currentLiquidity, group.initialLiquidity);
        
        for (uint256 i = 0; i < optionsCount; i++) {
            allOdds[i] = MarketMath.calculateOddsForOption(group.currentLiquidity[i], totalRemainingLiq, PRECISION);
        }
        return allOdds;
    }

    function getOptionNames(uint256 _optionGroupId) external view returns (string[] memory optionNames) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        uint256 count = group.options.length;
        optionNames = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            optionNames[i] = group.options[i].name;
        }
        return optionNames;
    }

    function getLiquidityProviders(uint256 _optionGroupId) external view returns (address[] memory) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        return group.liquidityProvidersList;
    }

    function getLiquidityProvidedByAddress(uint256 _optionGroupId, address _provider) external view returns (uint256) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        return group.liquidityProviders[_provider];
    }

    function getTotalBetsPerOption(uint256 _optionGroupId) external view returns (uint256[] memory) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        return group.totalBets;
    }

    function getCurrentLiquidity(uint256 _optionGroupId) external view returns (uint256[] memory) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        return group.currentLiquidity;
    }

    function getInitialLiquidity(uint256 _optionGroupId) external view returns (uint256[] memory) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        require(group.initialized, "Option group does not exist");
        console.log("HiloMarket.getInitialLiquidity: Entered for groupId %s", _optionGroupId);
        return group.initialLiquidity;
    }

    function getReservedTokens(uint256 _optionGroupId) public view returns (uint256[] memory reserves) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        uint256 optionCount = group.options.length;
        reserves = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            reserves[i] = MarketMath.calculateReserve(group.initialLiquidity[i], group.currentLiquidity[i]);
        }
        return reserves;
    }

    function calculateRemainingLiquidity(uint256 _groupId) public view returns (uint256) {
        OptionGroup storage group = optionGroups[_groupId];
        uint256 total = 0;
        
        // Sum both currentLiquidity and reserves
        for (uint256 i = 0; i < group.currentLiquidity.length; i++) {
            // Add current liquidity
            total += group.currentLiquidity[i];
            
            // Add reserves (max(0, initialLiquidity - currentLiquidity))
            total += calculateReserve(group.initialLiquidity[i], group.currentLiquidity[i]);
        }
        
        return total;
    }

    function calculateEarlyExitValue(uint256 _optionGroupId, uint256 _optionIndex, uint256 _betAmount) public view returns (uint256 exitValue) {
        OptionGroup storage group = optionGroups[_optionGroupId];
        
        // Get current liquidity
        uint256 optionLiquidity = group.currentLiquidity[_optionIndex];
        uint256 totalLiquidity = calculateRemainingLiquidity(_optionGroupId);
        
        // Safety checks
        require(optionLiquidity > 0, "Option has no liquidity");
        require(_betAmount <= optionLiquidity, "Exit amount exceeds option liquidity");
        
        // EDGE CASE 1: Handle very small liquidity situations
        // This covers the equal odds case where liquidity might be balanced
        uint256 otherLiquidity = totalLiquidity - optionLiquidity;
        if (otherLiquidity == 0 || otherLiquidity < _betAmount / 100) {
            return _betAmount; // Just return the bet amount as a safe value
        }
        
        // Safety check for multiplication overflow
        if (optionLiquidity > 0 && otherLiquidity > type(uint256).max / optionLiquidity) {
            // If potential overflow, return original bet amount as a safe value
            return _betAmount;
        }
        
        // Calculate constant product before exit
        uint256 constantProduct = optionLiquidity * otherLiquidity;
        
        // EDGE CASE 2: Handle case where removing bet leaves very small liquidity
        uint256 newOptionLiquidity = optionLiquidity - _betAmount;
        if (newOptionLiquidity == 0 || newOptionLiquidity < optionLiquidity / 100) {
            return _betAmount; // If removing all or most liquidity, return original bet
        }
        
        // Safety check for division
        if (constantProduct == 0) {
            return _betAmount; // Zero product case, return original bet
        }
        
        // EDGE CASE 3: Protection against extreme division values
        if (constantProduct / newOptionLiquidity > otherLiquidity * 100) {
            return _betAmount; // Return bet amount if division would result in extreme values
        }
        
        // Calculate new other liquidity to maintain constant product
        uint256 newOtherLiquidity = constantProduct / newOptionLiquidity;
        
        // Calculate exit value - check for logic errors
        if (newOtherLiquidity <= otherLiquidity) {
            // This case shouldn't happen with proper AMM logic, but handle it gracefully
            return _betAmount;
        }
        
        uint256 additionalLiquidity = newOtherLiquidity - otherLiquidity;
        
        // EDGE CASE 4: Prevent getting more than bet amount in liquid markets
        if (additionalLiquidity > _betAmount * 2) {
            // Cap at 2x bet amount as a reasonable maximum
            exitValue = _betAmount * 2;
        } else if (additionalLiquidity > _betAmount && totalLiquidity > _betAmount * 10) {
            // If exit value exceeds bet amount in a liquid market, cap at bet amount
            exitValue = _betAmount;
        } else {
            exitValue = additionalLiquidity;
        }
        
        return exitValue;
    }

    function updateLiquidityAfterEarlyExit(uint256 _optionGroupId, uint256 _optionIndex, uint256 _betAmount, uint256 _exitAmount) internal {
        OptionGroup storage group = optionGroups[_optionGroupId];
        
        // Remove bet amount from option's liquidity
        group.currentLiquidity[_optionIndex] -= _betAmount;
        
        // Distribute exit amount to other options according to their proportions
        uint256 optionsCount = group.options.length;
        uint256 totalOtherLiquidity = 0;
        
        // Calculate total liquidity in other options
        for (uint256 i = 0; i < optionsCount; i++) {
            if (i != _optionIndex) {
                totalOtherLiquidity += group.currentLiquidity[i];
            }
        }
        
        // Distribute exit amount proportionally
        if (totalOtherLiquidity > 0) {
            for (uint256 i = 0; i < optionsCount; i++) {
                if (i != _optionIndex) {
                    uint256 proportion = (group.currentLiquidity[i] * _exitAmount) / totalOtherLiquidity;
                    group.currentLiquidity[i] += proportion;
                }
            }
        } else {
            // If no other liquidity, distribute evenly
            uint256 amountPerOption = _exitAmount / (optionsCount - 1);
            for (uint256 i = 0; i < optionsCount; i++) {
                if (i != _optionIndex) {
                    group.currentLiquidity[i] += amountPerOption;
                }
            }
        }
        
        // Update constant product
        updateConstantProduct(_optionGroupId);
    }
}

// Simple Math library for min function used in removeLiquidity
library Math {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
}
}