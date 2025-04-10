// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IHiloStaking {
    function adjustReward(address user, uint256 amount, uint8 op) external;
    function getValidatorStake(address user) external view returns (uint256);
    function getPoolCreatorStake(address user) external view returns (uint256);
    function getEvaluatorStake(address user) external view returns (uint256);
    function freezeRoles(address user, uint8 freezeType) external;
    function unfreezeRoles(address user, uint8 freezeType) external;
    function slashPoolCreator(address user, uint256 amount) external;
    function getReward(address user) external view returns (uint256);
}

contract HiloBonding is Ownable, ReentrancyGuard {
    IHiloStaking public stakingContract;
    uint256[] public poolIds;

    struct ContractConfig {
        uint256 evaluationDuration;
        uint256 optionVotingDuration;
        uint256 disputeDuration;
        uint256 autoUnfreezeDelay;
        uint256 poolCreationFee;
        uint256 falseEvalPenalty;
        uint256 trueEvalReward;
        uint256 trueDisputeReward;
        uint256 falseDisputePenalty;
        uint256 goodPoolReward;
        uint256 badPoolPenalty;
        uint256 minVotesRequired;
        uint256 initialPerOptionCap;
        uint256 maxVoteDifference;
    }
    ContractConfig public config;

    struct PoolBase {
        address creator;
        string title;
        string data;
        uint256 poolId;
        uint256 startTimeframe;
        uint256 evaluationStart;
        uint256 evaluationEnd;
        uint256 optionVotingStart;
        uint256 optionVotingEnd;
        uint256 disputeEnd;
        uint256 processedTime;
    }

    struct PoolState {
        bool processed;
        bool evaluationComplete;
        bool evaluationApproved;
        bool finalApproval;
        bool disputeRound;
        bool canceled;
        bool settled;
        uint256 approveVotes;
        uint256 rejectVotes;
        uint256 approveDisputeVotes;
        uint256 rejectDisputeVotes;
        uint256 winningOptionIndex;
        mapping(uint256 => uint256) optionVoteCounts;
        mapping(uint256 => uint256) disputeOptionVoteCounts;
        uint256 maxPerOptionCount;
        uint256 maxDisputePerOptionCount;
    }

    struct PoolOptions {
        string[] optionNames;
        bool hasOptions;
    }

    // Added this struct to help with stack depth issues in getPoolStatus
    struct EffectivePoolStatus {
        bool processed;
        uint256 processedTime;
        bool finalApproval;
        bool disputeRound;
        uint256 winningOptionIndex;
    }

    // Added this struct to help with stack depth issues in GetValidationResultForPoolId
    struct ValidationResult {
        bool processed;
        bool finalApproval;
        uint256 winningOptionIndex;
        bool validatorVoted;
        uint256 validatorOption;
        bool rewardClaimed;
        uint256 estimatedReward;
        int8 rewardType;
    }

    mapping(uint256 => PoolBase) private poolsBase;
    mapping(uint256 => PoolState) private poolsState;
    mapping(uint256 => PoolOptions) private poolsOptions;
    
    mapping(uint256 => mapping(address => uint8)) private initialVotes;
    mapping(uint256 => mapping(address => uint8)) private disputeVotes;
    mapping(uint256 => mapping(address => uint256)) private optionVotes;
    mapping(uint256 => mapping(address => uint256)) private optionDisputeVotes;
    
    mapping(uint256 => mapping(address => bool)) private frozenStakes;
    mapping(uint256 => address[]) private validatorsList;
    mapping(uint256 => mapping(address => bool)) private validatorRegisteredForPool;
    mapping(uint256 => mapping(address => bool)) public rewardClaimed;

    mapping(address => bool) public authorizedAddresses;

    uint8 private constant FREEZE_VALIDATOR = 0;
    uint8 private constant FREEZE_POOL_CREATOR = 1;
    uint8 private constant FREEZE_EVALUATOR = 2;
    uint8 private constant FREEZE_ALL = 3;

    uint256 private constant MAX_OPTIONS = 20;
    uint256 private constant MAX_OPTION_NAME_LENGTH = 100;
    uint256 private constant MAX_VALIDATORS_PER_BATCH = 50;

    // UPDATED EVENT: Added additional timeline information
    event PoolCreated(
        uint256 indexed poolId, 
        address indexed creator, 
        uint256 startTimeframe, 
        string indexed _data, 
        uint256 evaluationStart, 
        uint256 evaluationEnd, 
        uint256 optionVotingEnd, 
        uint256 disputeEnd
    );
    
    event PoolOptionsSet(uint256 indexed poolId, uint256 optionsCount);
    
    // UPDATED EVENT: Added current vote counts
    event EvaluationVoteCast(
        uint256 indexed poolId, 
        address indexed evaluator, 
        bool approved, 
        uint256 approveVotes, 
        uint256 rejectVotes
    );
    
    // UPDATED EVENT: Added current vote count for this option
    event OptionVoteCast(
        uint256 indexed poolId, 
        address indexed evaluator, 
        uint256 optionIndex, 
        uint256 currentVoteCount
    );
    
    // UPDATED EVENT: Added vote counts
    event DisputeVoteCast(
        uint256 indexed poolId, 
        address indexed evaluator, 
        bool isEvaluationDispute, 
        uint256 voteValue, 
        uint256 currentVoteCount
    );
    
    event EvaluationPhaseCompleted(uint256 indexed poolId, bool approved);
    event PoolProcessed(uint256 indexed poolId, bool finalApproval, uint256 winningOptionIndex);
    event RewardClaimedForPool(address indexed evaluator, uint256 indexed poolId, uint256 amount, uint8 op);
    event CreatorPenalized(uint256 indexed poolId, address indexed creator, uint256 penaltyAmount);
    event StakeFrozen(uint256 indexed poolId, address indexed validator);
    event StakeUnfrozen(uint256 indexed poolId, address indexed validator);
    event BulkStakesUnfrozen(uint256 indexed poolId, uint256 validatorCount);
    event ConfigUpdated();
    event AuthorizedAddressUpdated(address indexed addr, bool status);
    event OptionGroupCanceled(uint256 indexed poolId);
    event VoteCapIncreased(uint256 indexed poolId, uint256 optionIndex, bool isDispute, uint256 newCap);
    
    modifier onlyOwnerOrAuthorized() {
        require(msg.sender == owner() || authorizedAddresses[msg.sender], "Not authorized");
        _;
    }

    modifier onlyValidator() {
        require(stakingContract.getValidatorStake(msg.sender) > 0, "Not validator");
        _;
    }

    modifier onlyPoolCreator() {
        require(stakingContract.getPoolCreatorStake(msg.sender) > 0 || authorizedAddresses[msg.sender], "Not pool creator or authorized contract");
        _;
    }

    modifier onlyEvaluator() {
        require(stakingContract.getEvaluatorStake(msg.sender) > 0, "Not evaluator");
        _;
    }

    modifier poolExists(uint256 _poolId) {
        require(poolsBase[_poolId].poolId != 0, "Pool not exist");
        _;
    }

    constructor(address _stakingContract, uint256[14] memory _configValues) Ownable(msg.sender) {
        require(_stakingContract != address(0), "Invalid staking address");
        stakingContract = IHiloStaking(_stakingContract);
        config = ContractConfig({
            evaluationDuration: _configValues[0],
            optionVotingDuration: _configValues[1],
            disputeDuration: _configValues[2],
            autoUnfreezeDelay: _configValues[3],
            falseEvalPenalty: _configValues[4],
            trueEvalReward: _configValues[5],
            trueDisputeReward: _configValues[6],
            falseDisputePenalty: _configValues[7],
            goodPoolReward: _configValues[8],
            badPoolPenalty: _configValues[9],
            minVotesRequired: _configValues[10],
            poolCreationFee: _configValues[11],
            initialPerOptionCap: _configValues[12],
            maxVoteDifference: _configValues[13]
        });
    }

    function updateConfig(uint256[14] calldata _newConfig) external onlyOwner {
        config.evaluationDuration = _newConfig[0];
        config.optionVotingDuration = _newConfig[1];
        config.disputeDuration = _newConfig[2];
        config.autoUnfreezeDelay = _newConfig[3];
        config.falseEvalPenalty = _newConfig[4];
        config.trueEvalReward = _newConfig[5];
        config.trueDisputeReward = _newConfig[6];
        config.falseDisputePenalty = _newConfig[7];
        config.goodPoolReward = _newConfig[8];
        config.badPoolPenalty = _newConfig[9];
        config.minVotesRequired = _newConfig[10];
        config.poolCreationFee = _newConfig[11];
        config.initialPerOptionCap = _newConfig[12];
        config.maxVoteDifference = _newConfig[13];
        emit ConfigUpdated();
    }

    function updateAuthorizedAddress(address _addr, bool _status) external onlyOwner {
        require(_addr != address(0), "Invalid address");
        authorizedAddresses[_addr] = _status;
        emit AuthorizedAddressUpdated(_addr, _status);
    }

    function createPool(
        uint256 _poolId,
        string calldata _title,
        uint256 _startTimeframe,
        uint256 _settleTimeframe,
        string calldata _data,
        address _who
    ) external nonReentrant onlyPoolCreator {
        require(poolsBase[_poolId].poolId == 0, "Pool exists");
        require(_startTimeframe > block.timestamp, "Start in past");
        require(_settleTimeframe > _startTimeframe, "Invalid settle time");

        if (_who != msg.sender) {
            require(authorizedAddresses[msg.sender], "Not authorized to create for others");
        }

        uint256 creatorStake = stakingContract.getPoolCreatorStake(_who);
        require(creatorStake >= config.poolCreationFee, "Insufficient stake");

        PoolBase storage base = poolsBase[_poolId];
        base.poolId = _poolId;
        base.creator = _who;
        base.title = _title;
        base.startTimeframe = _startTimeframe;
        
        // MODIFIED: Evaluation still starts immediately at pool creation time
        base.evaluationStart = block.timestamp;
        base.evaluationEnd = block.timestamp + config.evaluationDuration;
        
        // MODIFIED: Option voting now starts AFTER the settle timeframe (end of the event)
        base.optionVotingStart = _settleTimeframe;
        base.optionVotingEnd = base.optionVotingStart + config.optionVotingDuration;
        base.disputeEnd = base.optionVotingEnd + config.disputeDuration;

        PoolState storage state = poolsState[_poolId];
        state.maxPerOptionCount = config.initialPerOptionCap;
        state.maxDisputePerOptionCount = config.initialPerOptionCap;

        poolIds.push(_poolId);

        // UPDATED: Included additional timeline data in the event emission
        emit PoolCreated(
            _poolId, 
            _who, 
            _startTimeframe, 
            _data, 
            base.evaluationStart, 
            base.evaluationEnd, 
            base.optionVotingEnd, 
            base.disputeEnd
        );

        if (config.poolCreationFee > 0) {
            stakingContract.slashPoolCreator(_who, config.poolCreationFee);
        }
        stakingContract.freezeRoles(_who, FREEZE_POOL_CREATOR);
    }

    function setPoolOptions(uint256 _poolId, string[] calldata _optionNames) external poolExists(_poolId) {
        PoolBase storage base = poolsBase[_poolId];
        require(msg.sender == base.creator || msg.sender == owner() || authorizedAddresses[msg.sender], "Not authorized to set options");
        require(block.timestamp < base.startTimeframe, "Pool already started");
        require(!poolsOptions[_poolId].hasOptions, "Options already set");
        require(_optionNames.length >= 2, "Need at least 2 options");
        require(_optionNames.length <= MAX_OPTIONS, "Too many options");

        for (uint256 i = 0; i < _optionNames.length; i++) {
            require(bytes(_optionNames[i]).length <= MAX_OPTION_NAME_LENGTH, "Option name too long");
            require(bytes(_optionNames[i]).length > 0, "Empty option name");
        }

        PoolOptions storage options = poolsOptions[_poolId];
        options.hasOptions = true;
        for (uint256 i = 0; i < _optionNames.length; i++) {
            options.optionNames.push(_optionNames[i]);
        }
        emit PoolOptionsSet(_poolId, _optionNames.length);
    }

    function voteEvaluation(uint256 _poolId, bool _approve) external nonReentrant onlyValidator poolExists(_poolId) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        
        // ENHANCEMENT: Auto-complete the evaluation if the time has passed
        if (block.timestamp > base.evaluationEnd) {
            _tryCompleteEvaluationPhase(_poolId);
        }
        
        require(!state.evaluationComplete, "Evaluation phase complete");
        require(block.timestamp >= base.evaluationStart && block.timestamp <= base.evaluationEnd, "Not in eval window");
        require(initialVotes[_poolId][msg.sender] == 0, "Already voted");

        if (_approve) {
            if (state.approveVotes >= state.rejectVotes) {
                require(state.approveVotes - state.rejectVotes < config.maxVoteDifference, "Max approve vote difference reached");
            }
            state.approveVotes++;
        } else {
            if (state.rejectVotes >= state.approveVotes) {
                require(state.rejectVotes - state.approveVotes < config.maxVoteDifference, "Max reject vote difference reached");
            }
            state.rejectVotes++;
        }

        initialVotes[_poolId][msg.sender] = _approve ? 1 : 2;

        frozenStakes[_poolId][msg.sender] = true;
        if (!validatorRegisteredForPool[_poolId][msg.sender]) {
            validatorRegisteredForPool[_poolId][msg.sender] = true;
            validatorsList[_poolId].push(msg.sender);
        }

        // UPDATED: Include current vote counts
        emit EvaluationVoteCast(_poolId, msg.sender, _approve, state.approveVotes, state.rejectVotes);
        
        stakingContract.freezeRoles(msg.sender, FREEZE_VALIDATOR);
        emit StakeFrozen(_poolId, msg.sender);
        
        // ENHANCEMENT: Check if we can auto-complete evaluation phase after this vote
        if (state.approveVotes + state.rejectVotes >= config.minVotesRequired) {
            if (state.approveVotes > state.rejectVotes + config.maxVoteDifference || 
                state.rejectVotes > state.approveVotes + config.maxVoteDifference) {
                _tryCompleteEvaluationPhase(_poolId);
            }
        }
    }

    // Enhanced internal function to check if evaluation can be auto-completed
    function _tryCompleteEvaluationPhase(uint256 _poolId) internal returns (bool) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        
        // Return early if already completed
        if (state.evaluationComplete) {
            return true;
        }
        
        // ENHANCEMENT: Auto-complete if evaluation end time has passed
        bool timeElapsed = block.timestamp > base.evaluationEnd;
        uint256 totalVotes = state.approveVotes + state.rejectVotes;
        
        if (timeElapsed && totalVotes > 0) {
            // At evaluation end, we process the results no matter the vote count
            state.evaluationApproved = state.approveVotes >= state.rejectVotes; // Ties result in approval
            state.evaluationComplete = true;
            emit EvaluationPhaseCompleted(_poolId, state.evaluationApproved);
            return true;
        } else if (!timeElapsed && totalVotes >= config.minVotesRequired) {
            // During the evaluation period, only auto-complete if clear winner
            if (state.approveVotes > state.rejectVotes + config.maxVoteDifference || 
                state.rejectVotes > state.approveVotes + config.maxVoteDifference) {
                state.evaluationApproved = state.approveVotes > state.rejectVotes;
                state.evaluationComplete = true;
                emit EvaluationPhaseCompleted(_poolId, state.evaluationApproved);
                return true;
            }
        }
        
        return false;
    }

    function completeEvaluationPhase(uint256 _poolId) external nonReentrant poolExists(_poolId) {
        // Try auto-completion first
        bool completed = _tryCompleteEvaluationPhase(_poolId);
        
        // If auto-completion didn't work, handle manual completion (for backward compatibility)
        if (!completed) {
            PoolBase storage base = poolsBase[_poolId];
            PoolState storage state = poolsState[_poolId];
            require(!state.evaluationComplete, "Evaluation already completed");
            require(block.timestamp > base.evaluationEnd, "Evaluation phase not over");
            
            uint256 totalVotes = state.approveVotes + state.rejectVotes;
            require(totalVotes >= config.minVotesRequired || msg.sender == owner() || authorizedAddresses[msg.sender], 
                    "Insufficient votes");
            
            state.evaluationApproved = state.approveVotes > state.rejectVotes;
            state.evaluationComplete = true;
            
            emit EvaluationPhaseCompleted(_poolId, state.evaluationApproved);
        }
    }

    function voteOption(uint256 _poolId, uint256 _optionIndex) external nonReentrant onlyValidator poolExists(_poolId) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        PoolOptions storage options = poolsOptions[_poolId];
        
        // Check if we need to auto-complete evaluation
        if (!state.evaluationComplete) {
            _tryCompleteEvaluationPhase(_poolId);
        }
        
        require(state.evaluationComplete, "Evaluation phase not complete");
        require(state.evaluationApproved, "Pool was not approved");
        require(block.timestamp >= base.optionVotingStart && block.timestamp <= base.optionVotingEnd, "Not in option voting window");
        require(options.hasOptions, "No options set");
        require(_optionIndex < options.optionNames.length, "Invalid option index");
        require(optionVotes[_poolId][msg.sender] == 0, "Already voted for option");

        uint256 currentCount = state.optionVoteCounts[_optionIndex];
        
        uint256 maxVotes = 0;
        for (uint256 i = 0; i < options.optionNames.length; i++) {
            if (state.optionVoteCounts[i] > maxVotes && i != _optionIndex) {
                maxVotes = state.optionVoteCounts[i];
            }
        }
        
        require(currentCount < maxVotes + config.maxVoteDifference, "Max vote difference would be exceeded");
        
        state.optionVoteCounts[_optionIndex]++;
        optionVotes[_poolId][msg.sender] = _optionIndex + 1;

        if (!frozenStakes[_poolId][msg.sender]) {
            frozenStakes[_poolId][msg.sender] = true;
            if (!validatorRegisteredForPool[_poolId][msg.sender]) {
                validatorRegisteredForPool[_poolId][msg.sender] = true;
                validatorsList[_poolId].push(msg.sender);
            }
            stakingContract.freezeRoles(msg.sender, FREEZE_VALIDATOR);
            emit StakeFrozen(_poolId, msg.sender);
        }
        
        // UPDATED: Include current vote count for this option
        emit OptionVoteCast(_poolId, msg.sender, _optionIndex, state.optionVoteCounts[_optionIndex]);
        
        // ENHANCEMENT: Check if we should automatically process the pool at dispute end
        if (block.timestamp > base.disputeEnd && !state.processed) {
            _tryProcessPool(_poolId);
        }
    }

    function voteDispute(uint256 _poolId, bool _isEvaluationDispute, uint256 _voteValue) external nonReentrant onlyValidator poolExists(_poolId) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        
        // First make sure evaluation is complete
        if (!state.evaluationComplete) {
            _tryCompleteEvaluationPhase(_poolId);
        }
        
        require(block.timestamp > base.optionVotingEnd && block.timestamp <= base.disputeEnd, "Not in dispute window");
        
        uint256 currentVoteCount;
        
        if (_isEvaluationDispute) {
            require(state.evaluationComplete, "Evaluation not complete");
            require(disputeVotes[_poolId][msg.sender] == 0, "Already cast evaluation dispute vote");
            
            bool isApprove = _voteValue == 1;
            
            if (isApprove) {
                if (state.approveDisputeVotes >= state.rejectDisputeVotes) {
                    require(state.approveDisputeVotes - state.rejectDisputeVotes < config.maxVoteDifference, 
                            "Max approve dispute vote difference reached");
                }
                state.approveDisputeVotes++;
                currentVoteCount = state.approveDisputeVotes;
            } else {
                if (state.rejectDisputeVotes >= state.approveDisputeVotes) {
                    require(state.rejectDisputeVotes - state.approveDisputeVotes < config.maxVoteDifference, 
                            "Max reject dispute vote difference reached");
                }
                state.rejectDisputeVotes++;
                currentVoteCount = state.rejectDisputeVotes;
            }
            
            disputeVotes[_poolId][msg.sender] = isApprove ? 1 : 2;
        } else {
            require(state.evaluationComplete && state.evaluationApproved, "Pool not approved in evaluation");
            require(optionDisputeVotes[_poolId][msg.sender] == 0, "Already cast option dispute vote");
            
            PoolOptions storage options = poolsOptions[_poolId];
            require(_voteValue < options.optionNames.length, "Invalid option index");
            
            uint256 currentCount = state.disputeOptionVoteCounts[_voteValue];
            
            uint256 maxVotes = 0;
            for (uint256 i = 0; i < options.optionNames.length; i++) {
                if (state.disputeOptionVoteCounts[i] > maxVotes && i != _voteValue) {
                    maxVotes = state.disputeOptionVoteCounts[i];
                }
            }
            
            require(currentCount < maxVotes + config.maxVoteDifference, "Max dispute vote difference would be exceeded");
            
            state.disputeOptionVoteCounts[_voteValue]++;
            optionDisputeVotes[_poolId][msg.sender] = _voteValue + 1;
            currentVoteCount = state.disputeOptionVoteCounts[_voteValue];
        }
        
        if (!frozenStakes[_poolId][msg.sender]) {
            frozenStakes[_poolId][msg.sender] = true;
            if (!validatorRegisteredForPool[_poolId][msg.sender]) {
                validatorRegisteredForPool[_poolId][msg.sender] = true;
                validatorsList[_poolId].push(msg.sender);
            }
            stakingContract.freezeRoles(msg.sender, FREEZE_VALIDATOR);
            emit StakeFrozen(_poolId, msg.sender);
        }
        
        // UPDATED: Include current vote count
        emit DisputeVoteCast(_poolId, msg.sender, _isEvaluationDispute, _voteValue, currentVoteCount);
        
        // ENHANCEMENT: Check if we should automatically process the pool at dispute end
        if (block.timestamp > base.disputeEnd) {
            _tryProcessPool(_poolId);
        }
    }
    
    // New internal function to attempt pool processing
    function _tryProcessPool(uint256 _poolId) internal returns (bool) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        
        if (state.processed || block.timestamp <= base.disputeEnd) {
            return false;
        }
        
        bool poolApproved;
        if (state.approveDisputeVotes > 0 || state.rejectDisputeVotes > 0) {
            poolApproved = state.approveDisputeVotes >= state.rejectDisputeVotes; // Ties result in approval
            state.disputeRound = true;
        } else {
            poolApproved = state.evaluationApproved;
        }
        
        state.finalApproval = poolApproved;
        
        if (poolApproved) {
            PoolOptions storage options = poolsOptions[_poolId];
            uint256 winningIndex = 0;
            uint256 highestVotes = 0;
            
            bool hasOptionDisputes = false;
            for (uint256 i = 0; i < options.optionNames.length; i++) {
                if (state.disputeOptionVoteCounts[i] > 0) {
                    hasOptionDisputes = true;
                    break;
                }
            }
            
            if (hasOptionDisputes) {
                for (uint256 i = 0; i < options.optionNames.length; i++) {
                    if (state.disputeOptionVoteCounts[i] > highestVotes) {
                        highestVotes = state.disputeOptionVoteCounts[i];
                        winningIndex = i;
                    }
                }
            } else {
                for (uint256 i = 0; i < options.optionNames.length; i++) {
                    if (state.optionVoteCounts[i] > highestVotes) {
                        highestVotes = state.optionVoteCounts[i];
                        winningIndex = i;
                    }
                }
            }
            
            state.winningOptionIndex = winningIndex;
        }
        
        state.processed = true;
        state.settled = true;
        base.processedTime = block.timestamp;
        
        emit PoolProcessed(_poolId, state.finalApproval, state.winningOptionIndex);
        
        stakingContract.unfreezeRoles(base.creator, FREEZE_POOL_CREATOR);
        
        if (state.finalApproval) {
            stakingContract.adjustReward(base.creator, config.goodPoolReward, 0);
        } else {
            uint256 currentRewards = stakingContract.getReward(base.creator);
            if (currentRewards >= config.badPoolPenalty) {
                stakingContract.adjustReward(base.creator, config.badPoolPenalty, 1);
                emit CreatorPenalized(_poolId, base.creator, config.badPoolPenalty);
            }
        }
        
        return true;
    }
    
    function processPool(uint256 _poolId) external nonReentrant poolExists(_poolId) {
        bool processed = _tryProcessPool(_poolId);
        if (!processed) {
            PoolBase storage base = poolsBase[_poolId];
            require(block.timestamp > base.disputeEnd, "Dispute phase not ended");
            require(!poolsState[_poolId].processed, "Already processed");
            
            // If we get here, _tryProcessPool must have failed for some reason
            // Let's try to explicitly process the pool
            _tryProcessPool(_poolId);
        }
    }

function claimRewardForPool(uint256 _poolId) external nonReentrant poolExists(_poolId) {
    PoolBase storage base = poolsBase[_poolId];
    PoolState storage state = poolsState[_poolId];
    
    // ENHANCEMENT: Auto-process pool if needed
    if (!state.processed && block.timestamp > base.disputeEnd) {
        _tryProcessPool(_poolId);
    }
    
    require(state.processed, "Pool not processed");
    require(!rewardClaimed[_poolId][msg.sender], "Already claimed");
    
    uint8 evaluationVote = initialVotes[_poolId][msg.sender];
    uint8 disputeEvalVote = disputeVotes[_poolId][msg.sender];
    uint256 optionVote = optionVotes[_poolId][msg.sender];
    uint256 disputeOptionVote = optionDisputeVotes[_poolId][msg.sender];
    
    require(evaluationVote != 0 || disputeEvalVote != 0 || optionVote != 0 || disputeOptionVote != 0, "No vote recorded");
    
    uint256 amount;
    uint8 op;
    
    if (state.disputeRound) {
        if (disputeEvalVote != 0) {
            bool votedCorrectly = (disputeEvalVote == 1 && state.finalApproval) || 
                                  (disputeEvalVote == 2 && !state.finalApproval);
            if (votedCorrectly) {
                amount = config.trueDisputeReward;
                op = 1; // For reward
            } else {
                amount = config.falseDisputePenalty;
                op = 0; // For penalty
            }
        } else if (disputeOptionVote != 0 && state.finalApproval) {
            bool votedCorrectly = (disputeOptionVote - 1) == state.winningOptionIndex;
            if (votedCorrectly) {
                amount = config.trueDisputeReward;
                op = 1; // For reward
            } else {
                amount = config.falseDisputePenalty;
                op = 0; // For penalty
            }
        } else if (evaluationVote != 0) {
            amount = 0;
            op = 0;
        } else if (optionVote != 0 && state.finalApproval) {
            amount = 0;
            op = 0;
        }
    } else {
        if (evaluationVote != 0) {
            bool votedCorrectly = (evaluationVote == 1 && state.finalApproval) || 
                                 (evaluationVote == 2 && !state.finalApproval);
            if (votedCorrectly) {
                amount = config.trueEvalReward; // This is 0.05 ETH
                op = 1; // For reward
            } else {
                amount = config.falseEvalPenalty;
                op = 0; // For penalty
            }
        } else if (optionVote != 0 && state.finalApproval) {
            bool votedCorrectly = (optionVote - 1) == state.winningOptionIndex;
            if (votedCorrectly) {
                amount = config.trueEvalReward; // FIXED: Using evaluation reward (0.05 ETH) instead of dispute reward
                op = 1; // For reward
            } else {
                amount = config.falseEvalPenalty;
                op = 0; // For penalty
            }
        }
    }
    
    rewardClaimed[_poolId][msg.sender] = true;
    if (frozenStakes[_poolId][msg.sender]) {
        frozenStakes[_poolId][msg.sender] = false;
        stakingContract.unfreezeRoles(msg.sender, FREEZE_VALIDATOR);
        emit StakeUnfrozen(_poolId, msg.sender);
    }
    
    if (amount > 0) {
        stakingContract.adjustReward(msg.sender, amount, op);
        emit RewardClaimedForPool(msg.sender, _poolId, amount, op);
    }
}

    function forceUnfreezeValidator(uint256 _poolId, address _validator) external onlyOwner poolExists(_poolId) {
        require(frozenStakes[_poolId][_validator], "Validator not frozen");
        frozenStakes[_poolId][_validator] = false;
        stakingContract.unfreezeRoles(_validator, FREEZE_VALIDATOR);
        emit StakeUnfrozen(_poolId, _validator);
    }

    // Helper function for getPoolEvaluationStatus to avoid stack too deep errors
function _getEffectiveEvaluationStatus(uint256 _poolId) private view returns (
    bool effectiveEvalComplete,
    bool effectiveEvalApproved
) {
    PoolBase storage base = poolsBase[_poolId];
    PoolState storage state = poolsState[_poolId];
    
    effectiveEvalComplete = state.evaluationComplete;
    effectiveEvalApproved = state.evaluationApproved;
    
    // If time elapsed but evaluation not marked complete, calculate what the result would be
    bool timeElapsed = block.timestamp > base.evaluationEnd;
    if (timeElapsed && !state.evaluationComplete) { // REMOVED VOTE CHECK
        effectiveEvalComplete = true;
        
        // Handle zero-vote case
        if (state.approveVotes == 0 && state.rejectVotes == 0) {
            effectiveEvalApproved = false; // Zero votes means rejection
        } else {
            effectiveEvalApproved = state.approveVotes >= state.rejectVotes; // Ties result in approval
        }
    }
    
    return (effectiveEvalComplete, effectiveEvalApproved);
}
function getPoolEvaluationStatus(uint256 _poolId) external view poolExists(_poolId) returns (
    bool evaluationComplete,
    bool evaluationApproved,
    uint256 approveVotes,
    uint256 rejectVotes,
    uint256 approveDisputeVotes,
    uint256 rejectDisputeVotes
) {
    PoolBase storage base = poolsBase[_poolId];
    PoolState storage state = poolsState[_poolId];
    
    // Always use the actual numeric vote counts
    approveVotes = state.approveVotes;
    rejectVotes = state.rejectVotes;
    approveDisputeVotes = state.approveDisputeVotes;
    rejectDisputeVotes = state.rejectDisputeVotes;
    
    // Check if evaluation period has ended (regardless of stored state)
    bool timeElapsed = block.timestamp > base.evaluationEnd;
    
    if (state.evaluationComplete) {
        // If already marked complete in storage, use stored values
        evaluationComplete = true;
        evaluationApproved = state.evaluationApproved;
    } else if (timeElapsed) {
        // Time has elapsed but not marked complete in storage
        // Calculate what the values SHOULD be
        evaluationComplete = true;
        
        if (approveVotes == 0 && rejectVotes == 0) {
            // Zero votes = rejected
            evaluationApproved = false;
        } else {
            // With votes, tie goes to approval
            evaluationApproved = approveVotes >= rejectVotes;
        }
    } else {
        // Still in evaluation period
        evaluationComplete = false;
        evaluationApproved = false;
    }
    
    return (evaluationComplete, evaluationApproved, approveVotes, rejectVotes, approveDisputeVotes, rejectDisputeVotes);
}
    
    function getPoolTimelines(uint256 _poolId) external view poolExists(_poolId) returns (
        uint256 evaluationStart,
        uint256 evaluationEnd,
        uint256 optionVotingStart,
        uint256 optionVotingEnd,
        uint256 disputeEnd
    ) {
        PoolBase storage base = poolsBase[_poolId];
        return (
            base.evaluationStart,
            base.evaluationEnd,
            base.optionVotingStart,
            base.optionVotingEnd,
            base.disputeEnd
        );
    }
    
    function getUserVotes(uint256 _poolId, address _user) external view poolExists(_poolId) returns (
        uint8 evaluationVote,
        uint8 disputeEvalVote,
        uint256 optionVote,
        uint256 disputeOptionVote
    ) {
        return (
            initialVotes[_poolId][_user],
            disputeVotes[_poolId][_user],
            optionVotes[_poolId][_user],
            optionDisputeVotes[_poolId][_user]
        );
    }


// Helper function to determine effective pool state to avoid stack too deep errors
function _calculateEffectivePoolStatus(uint256 _poolId) private view returns (bool, bool, uint256) {
    PoolBase storage base = poolsBase[_poolId];
    PoolState storage state = poolsState[_poolId];
    PoolOptions storage options = poolsOptions[_poolId];
    
    // If already processed, return existing values
    if (state.processed) {
        return (state.finalApproval, state.disputeRound, state.winningOptionIndex);
    }
    
    // If dispute phase has not ended, return not processed values
    if (block.timestamp <= base.disputeEnd) {
        return (false, false, 0);
    }
    
    // Calculate evaluation results
    bool evalComplete = state.evaluationComplete;
    bool evalApproved = state.evaluationApproved;
    
    // If evaluation not complete, determine what it would be
    if (!evalComplete && (state.approveVotes > 0 || state.rejectVotes > 0)) {
        evalComplete = true;
        evalApproved = state.approveVotes >= state.rejectVotes;
    }
    
    // FIXED: No votes means not processed - THIS IS THE KEY FIX
    if (state.approveVotes == 0 && state.rejectVotes == 0) {
        return (false, false, 0);
    }
    
    // If evaluation phase wasn't completed, don't process automatically
    if (!evalComplete) {
        return (false, false, 0);
    }
    
    // Determine if there was a dispute round
    bool effectiveDisputeRound = (state.approveDisputeVotes > 0 || state.rejectDisputeVotes > 0);
    
    // Determine effective final approval
    bool effectiveFinalApproval;
    if (effectiveDisputeRound) {
        effectiveFinalApproval = state.approveDisputeVotes >= state.rejectDisputeVotes;
    } else {
        effectiveFinalApproval = evalApproved;
    }
    
    // If not approved, no winning option
    if (!effectiveFinalApproval) {
        return (effectiveFinalApproval, effectiveDisputeRound, 0);
    }
    
    // Determine effective winning option
    uint256 effectiveWinningIndex = 0;
    uint256 highestVotes = 0;
    
    bool hasOptionDisputes = false;
    for (uint256 i = 0; i < options.optionNames.length; i++) {
        if (state.disputeOptionVoteCounts[i] > 0) {
            hasOptionDisputes = true;
            break;
        }
    }
    
    if (hasOptionDisputes) {
        for (uint256 i = 0; i < options.optionNames.length; i++) {
            if (state.disputeOptionVoteCounts[i] > highestVotes) {
                highestVotes = state.disputeOptionVoteCounts[i];
                effectiveWinningIndex = i;
            }
        }
    } else {
        for (uint256 i = 0; i < options.optionNames.length; i++) {
            if (state.optionVoteCounts[i] > highestVotes) {
                highestVotes = state.optionVoteCounts[i];
                effectiveWinningIndex = i;
            }
        }
    }
    
    return (effectiveFinalApproval, effectiveDisputeRound, effectiveWinningIndex);
}


    function GetEvaluationResultForPoolId(uint256 _poolId) external view 
        returns (
            bool processed,
            bool finalApproval,
            uint256 winningOptionIndex,
            uint256[] memory evaluationVotes,
            uint256[] memory disputeVotes
        ) 
    {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        PoolOptions storage options = poolsOptions[_poolId];
        
        // ENHANCEMENT: Calculate effective processed state
        bool effectiveProcessed = state.processed;
        bool effectiveDisputeRound;
        uint256 effectiveWinningIndex;
        
        // If dispute phase has ended but pool not processed, calculate what the result would be
        if (!effectiveProcessed && block.timestamp > base.disputeEnd) {
            effectiveProcessed = true;
            (finalApproval, effectiveDisputeRound, effectiveWinningIndex) = _calculateEffectivePoolStatus(_poolId);
        } else {
            finalApproval = state.finalApproval;
            effectiveWinningIndex = state.winningOptionIndex;
        }
        
        evaluationVotes = new uint256[](options.optionNames.length);
        disputeVotes = new uint256[](options.optionNames.length);
        
        for (uint256 i = 0; i < options.optionNames.length; i++) {
            evaluationVotes[i] = state.optionVoteCounts[i];
            disputeVotes[i] = state.disputeOptionVoteCounts[i];
        }
        
        processed = effectiveProcessed;
        winningOptionIndex = effectiveWinningIndex;
        
        return (processed, finalApproval, winningOptionIndex, evaluationVotes, disputeVotes);
    }

    function _getValidatorVoteDetails(uint256 _poolId, address _validator) private view returns (
        bool hasVoted,
        uint256 validatorOption
    ) {
        uint8 evalVote = initialVotes[_poolId][_validator];
        uint8 disputeEvalVote = disputeVotes[_poolId][_validator];
        uint256 optionVote = optionVotes[_poolId][_validator];
        uint256 optDispVote = optionDisputeVotes[_poolId][_validator];
        
        hasVoted = (evalVote != 0 || disputeEvalVote != 0 || optionVote != 0 || optDispVote != 0);
        
        if (optDispVote != 0) {
            validatorOption = optDispVote - 1;
        } else if (optionVote != 0) {
            validatorOption = optionVote - 1;
        } else {
            validatorOption = 0;
        }
        
        return (hasVoted, validatorOption);
    }
    
    // Split calculation into separate function to avoid stack too deep errors
function _calculateRewardDetails(
    uint256 _poolId, 
    address _validator, 
    bool _processed,
    bool _finalApproval,
    uint256 _winningIndex
) private view returns (
    uint256 reward,
    int8 rewardType
) {
    uint8 evalVote = initialVotes[_poolId][_validator];
    uint8 disputeEvalVote = disputeVotes[_poolId][_validator];
    uint256 optionVote = optionVotes[_poolId][_validator];
    uint256 optDispVote = optionDisputeVotes[_poolId][_validator];
    bool hasDispute = poolsState[_poolId].disputeRound;
    
    reward = 0;
    rewardType = 0;
    
    if (!_processed) {
        return (0, 0);
    }
    
    if (hasDispute) {
        if (disputeEvalVote != 0) {
            bool votedCorrectly = (disputeEvalVote == 1 && _finalApproval) || 
                                 (disputeEvalVote == 2 && !_finalApproval);
            if (votedCorrectly) {
                reward = config.trueDisputeReward;
                rewardType = 1;
            } else {
                reward = config.falseDisputePenalty;
                rewardType = -1;
            }
        } else if (optDispVote != 0 && _finalApproval) {
            bool votedCorrectly = (optDispVote - 1) == _winningIndex;
            if (votedCorrectly) {
                reward = config.trueDisputeReward;
                rewardType = 1;
            } else {
                reward = config.falseDisputePenalty;
                rewardType = -1;
            }
        }
    } else {
        if (evalVote != 0) {
            bool votedCorrectly = (evalVote == 1 && _finalApproval) || 
                                 (evalVote == 2 && !_finalApproval);
            if (votedCorrectly) {
                reward = config.trueEvalReward;
                rewardType = 1;
            } else {
                reward = config.falseEvalPenalty;
                rewardType = -1;
            }
        } else if (optionVote != 0 && _finalApproval) {
            bool votedCorrectly = (optionVote - 1) == _winningIndex;
            if (votedCorrectly) {
                // FIXED: Use TRUE_DISPUTE_REWARD (0.1 ETH) instead of TRUE_EVAL_REWARD (0.05 ETH) for correct option votes
                reward = config.trueDisputeReward;
                rewardType = 1;
            } else {
                reward = config.falseEvalPenalty;
                rewardType = -1;
            }
        }
    }
    
    return (reward, rewardType);
}
    // Use the struct to avoid stack too deep errors
    function GetValidationResultForPoolId(uint256 _poolId, address _validator) external view 
        returns (
            bool processed,
            bool finalApproval,
            uint256 winningOptionIndex,
            bool validatorVoted,
            uint256 validatorOption,
            bool rewardClaimedResult,
            uint256 estimatedReward,
            int8 rewardType
        ) 
    {
        ValidationResult memory result;
        
        result.processed = poolsState[_poolId].processed;
        result.finalApproval = poolsState[_poolId].finalApproval;
        result.winningOptionIndex = poolsState[_poolId].winningOptionIndex;
        
        // If not processed, calculate effective state
        if (!result.processed && block.timestamp > poolsBase[_poolId].disputeEnd) {
            result.processed = true;
            (result.finalApproval, , result.winningOptionIndex) = _calculateEffectivePoolStatus(_poolId);
        }
        
        result.rewardClaimed = rewardClaimed[_poolId][_validator];
        (result.validatorVoted, result.validatorOption) = _getValidatorVoteDetails(_poolId, _validator);
        (result.estimatedReward, result.rewardType) = _calculateRewardDetails(
            _poolId, 
            _validator, 
            result.processed,
            result.finalApproval,
            result.winningOptionIndex
        );
        
        return (
            result.processed, 
            result.finalApproval, 
            result.winningOptionIndex, 
            result.validatorVoted, 
            result.validatorOption, 
            result.rewardClaimed, 
            result.estimatedReward, 
            result.rewardType
        );
    }

    function getPoolBasics(uint256 _poolId) external view poolExists(_poolId) returns (
        address creator,
        string memory title,
        uint256 startTimeframe,
        uint256 evaluationEnd,
        uint256 disputeEnd
    ) {
        PoolBase storage base = poolsBase[_poolId];
        return (base.creator, base.title, base.startTimeframe, base.evaluationEnd, base.disputeEnd);
    }

    function getPoolOptions(uint256 _poolId) external view poolExists(_poolId) returns (string[] memory optionNames, bool hasOptions) {
        PoolOptions storage options = poolsOptions[_poolId];
        return (options.optionNames, options.hasOptions);
    }

    // Use struct to help with stack depth issues
    // Use struct to help with stack depth issues
function getPoolStatus(uint256 _poolId) external view poolExists(_poolId) returns (
    bool processed,
    uint256 processedTime,
    bool finalApproval,
    bool disputeRound,
    uint256 winningOptionIndex
) {
    PoolBase storage base = poolsBase[_poolId];
    PoolState storage state = poolsState[_poolId];
    
    // Return actual values if already processed
    if (state.processed) {
        return (
            state.processed,
            base.processedTime,
            state.finalApproval,
            state.disputeRound,
            state.winningOptionIndex
        );
    }
    
    // FIXED: If no votes at all, the pool is never auto-processed
    if (state.approveVotes == 0 && state.rejectVotes == 0) {
        return (false, 0, false, false, 0);
    }
    
    // Calculate effective state if after dispute end
    if (block.timestamp > base.disputeEnd) {
        bool effectiveDisputeRound;
        uint256 effectiveWinningIndex;
        
        (finalApproval, effectiveDisputeRound, effectiveWinningIndex) = _calculateEffectivePoolStatus(_poolId);
        
        return (
            true, // processed
            block.timestamp, // effective processed time
            finalApproval,
            effectiveDisputeRound,
            effectiveWinningIndex
        );
    }
    
    // Not processed yet
    return (false, 0, false, false, 0);
}


    function getPoolVotes(uint256 _poolId) external view poolExists(_poolId) returns (
        uint256 approveVotes,
        uint256 rejectVotes,
        uint256[] memory optionVoteCounts,
        uint256[] memory disputeOptionVoteCounts,
        uint256 maxPerOptionCount,
        uint256 maxDisputePerOptionCount
    ) {
        PoolState storage state = poolsState[_poolId];
        PoolOptions storage options = poolsOptions[_poolId];
        optionVoteCounts = new uint256[](options.optionNames.length);
        disputeOptionVoteCounts = new uint256[](options.optionNames.length);
        
        for (uint256 i = 0; i < options.optionNames.length; i++) {
            optionVoteCounts[i] = state.optionVoteCounts[i];
            disputeOptionVoteCounts[i] = state.disputeOptionVoteCounts[i];
        }
        
        return (
            state.approveVotes,
            state.rejectVotes,
            optionVoteCounts,
            disputeOptionVoteCounts,
            state.maxPerOptionCount,
            state.maxDisputePerOptionCount
        );
    }

    function isValidatorFrozen(uint256 _poolId, address _validator) external view returns (bool) {
        return frozenStakes[_poolId][_validator];
    }

    function getValidatorCount(uint256 _poolId) external view returns (uint256) {
        return validatorsList[_poolId].length;
    }

    function getFrozenValidators(uint256 _poolId) external view returns (address[] memory) {
        address[] storage validators = validatorsList[_poolId];
        uint256 count = validators.length;
        uint256 frozenCount = 0;
        
        for (uint256 i = 0; i < count; i++) {
            if (frozenStakes[_poolId][validators[i]]) frozenCount++;
        }
        
        address[] memory result = new address[](frozenCount);
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < count; i++) {
            if (frozenStakes[_poolId][validators[i]]) {
                result[resultIndex] = validators[i];
                resultIndex++;
            }
        }
        
        return result;
    }

    function getAutoUnfreezeStatus(uint256 _poolId) external view poolExists(_poolId) returns (
        bool isProcessed,
        bool unfreezeEligible,
        uint256 timeRemaining
    ) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        
        // ENHANCEMENT: Calculate effective processed status
        isProcessed = state.processed;
        
        if (!isProcessed && block.timestamp > base.disputeEnd) {
            isProcessed = true;
        }
        
        if (isProcessed) {
            uint256 processedTime = state.processed ? base.processedTime : block.timestamp;
            uint256 unfreezeTime = processedTime + config.autoUnfreezeDelay;
            unfreezeEligible = block.timestamp >= unfreezeTime;
            timeRemaining = unfreezeEligible ? 0 : unfreezeTime - block.timestamp;
        } else {
            unfreezeEligible = false;
            timeRemaining = 0;
        }
    }

    function isPoolCanceled(uint256 _poolId) external view poolExists(_poolId) returns (bool) {
        return poolsState[_poolId].canceled;
    }

    function isPoolSettled(uint256 _poolId) external view poolExists(_poolId) returns (bool) {
        PoolBase storage base = poolsBase[_poolId];
        PoolState storage state = poolsState[_poolId];
        
        // ENHANCEMENT: Calculate effective settled status
        bool effectiveSettled = state.settled;
        
        if (!effectiveSettled && block.timestamp > base.disputeEnd) {
            effectiveSettled = true;
        }
        
        return effectiveSettled;
    }

    function getPools(uint256 start, uint256 count) external view returns (PoolBase[] memory pools) {
        uint256 total = poolIds.length;
        if (start >= total) return new PoolBase[](0);
        
        uint256 end = start + count;
        if (end > total) end = total;
        
        uint256 length = end - start;
        pools = new PoolBase[](length);
        
        for (uint256 i = 0; i < length; i++) {
            pools[i] = poolsBase[poolIds[start + i]];
        }
    }
    
}