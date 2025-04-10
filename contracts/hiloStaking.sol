// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HiloStaking is Ownable(msg.sender), ReentrancyGuard {
    struct Staker {
        uint256 validatorStake;
        uint256 poolCreatorStake;
        uint256 evaluatorStake;
    }
    
    mapping(address => Staker) public stakers;
    mapping(address => bool) public authorizedContracts;
    
    // Separate freeze flags for each role.
    mapping(address => bool) public validatorFrozen;
    mapping(address => bool) public poolCreatorFrozen;
    mapping(address => bool) public evaluatorFrozen;
    
    // Rewards mapping stores additional ETH rewards for each user.
    mapping(address => uint256) public rewards;
    
    // Total rewards outstanding to ensure contract has sufficient balance
    uint256 public totalRewardsOutstanding;

    uint256 public validatorThreshold;
    uint256 public poolCreatorThreshold;
    uint256 public evaluatorThreshold;

    event RolePurchased(address indexed user, string role, uint256 amount);
    event Unstaked(address indexed user, string role, uint256 amount);
    event RoleRevoked(address indexed user, string role);
    event Slashed(address indexed user, string role, uint256 amount);
    event AuthorizationUpdated(address indexed contractAddress, bool status);
    event RoleFreezeUpdated(address indexed user, string role, bool frozen);
    event RewardUpdated(address indexed user, uint256 newReward);
    event RewardClaimed(address indexed user, uint256 reward);
    // op: 0 for addition, 1 for subtraction.
    event RewardAdjusted(address indexed user, uint8 op, uint256 amount, uint256 newReward);
    event ThresholdsUpdated(uint256 newValidatorThreshold, uint256 newPoolCreatorThreshold, uint256 newEvaluatorThreshold);

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender], "Caller is not authorized");
        _;
    }
    
    modifier onlyOwnerOrAuthorized() {
        require(msg.sender == owner() || authorizedContracts[msg.sender], "Caller is not owner or authorized");
        _;
    }
    
    constructor(
        uint256 _validatorThreshold,
        uint256 _poolCreatorThreshold,
        uint256 _evaluatorThreshold
    ) {
        validatorThreshold = _validatorThreshold;
        poolCreatorThreshold = _poolCreatorThreshold;
        evaluatorThreshold = _evaluatorThreshold;
    }
    
    // Allow the contract to receive ETH for rewards or other purposes.
    receive() external payable {}
    fallback() external payable {}
    
    /**
     * @notice Buy the Validator role by sending ETH equal to the validatorThreshold.
     */
    function buyValidator() external payable nonReentrant {
        require(stakers[msg.sender].validatorStake == 0, "Validator role already purchased");
        require(msg.value == validatorThreshold, "Incorrect ETH amount sent for Validator role");
        stakers[msg.sender].validatorStake = validatorThreshold;
        emit RolePurchased(msg.sender, "Validator", validatorThreshold);
    }
    
    /**
     * @notice Buy the PoolCreator role by sending ETH equal to the poolCreatorThreshold.
     */
    function buyPoolCreator() external payable nonReentrant {
        require(stakers[msg.sender].poolCreatorStake == 0, "PoolCreator role already purchased");
        require(msg.value == poolCreatorThreshold, "Incorrect ETH amount sent for PoolCreator role");
        stakers[msg.sender].poolCreatorStake = poolCreatorThreshold;
        emit RolePurchased(msg.sender, "PoolCreator", poolCreatorThreshold);
    }
    
    /**
     * @notice Buy the Evaluator role by sending ETH equal to the evaluatorThreshold.
     */
    function buyEvaluator() external payable nonReentrant {
        require(stakers[msg.sender].evaluatorStake == 0, "Evaluator role already purchased");
        require(msg.value == evaluatorThreshold, "Incorrect ETH amount sent for Evaluator role");
        stakers[msg.sender].evaluatorStake = evaluatorThreshold;
        emit RolePurchased(msg.sender, "Evaluator", evaluatorThreshold);
    }
    
    /**
     * @notice Unstake ETH for the Validator role, revoking the role.
     */
    function unstakeValidator() external nonReentrant {
        require(!validatorFrozen[msg.sender], "Validator stake is frozen");
        uint256 amount = stakers[msg.sender].validatorStake;
        require(amount > 0, "No Validator stake to unstake");
        stakers[msg.sender].validatorStake = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send ETH");
        emit Unstaked(msg.sender, "Validator", amount);
    }
    
    /**
     * @notice Unstake ETH for the PoolCreator role, revoking the role.
     */
    function unstakePoolCreator() external nonReentrant {
        require(!poolCreatorFrozen[msg.sender], "PoolCreator stake is frozen");
        uint256 amount = stakers[msg.sender].poolCreatorStake;
        require(amount > 0, "No PoolCreator stake to unstake");
        stakers[msg.sender].poolCreatorStake = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send ETH");
        emit Unstaked(msg.sender, "PoolCreator", amount);
    }
    
    /**
     * @notice Unstake ETH for the Evaluator role, revoking the role.
     */
    function unstakeEvaluator() external nonReentrant {
        require(!evaluatorFrozen[msg.sender], "Evaluator stake is frozen");
        uint256 amount = stakers[msg.sender].evaluatorStake;
        require(amount > 0, "No Evaluator stake to unstake");
        stakers[msg.sender].evaluatorStake = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send ETH");
        emit Unstaked(msg.sender, "Evaluator", amount);
    }
    
    /**
     * @notice Freeze specific roles of a user's stake.
     * @param user The address of the user.
     * @param freezeType Role identifier:
     *        0 = freeze Validator,
     *        1 = freeze PoolCreator,
     *        2 = freeze Evaluator,
     *        3 = freeze All roles.
     */
    function freezeRoles(address user, uint8 freezeType) external onlyOwnerOrAuthorized {
        require(freezeType < 4, "Invalid freeze type");
        if (freezeType == 0 || freezeType == 3) {
            require(stakers[user].validatorStake > 0, "User is not a validator");
            validatorFrozen[user] = true;
            emit RoleFreezeUpdated(user, "Validator", true);
        }
        if (freezeType == 1 || freezeType == 3) {
            require(stakers[user].poolCreatorStake > 0, "User is not a pool creator");
            poolCreatorFrozen[user] = true;
            emit RoleFreezeUpdated(user, "PoolCreator", true);
        }
        if (freezeType == 2 || freezeType == 3) {
            require(stakers[user].evaluatorStake > 0, "User is not an evaluator");
            evaluatorFrozen[user] = true;
            emit RoleFreezeUpdated(user, "Evaluator", true);
        }
    }
    
    /**
     * @notice Unfreeze specific roles of a user's stake.
     * @param user The address of the user.
     * @param freezeType Role identifier:
     *        0 = unfreeze Validator,
     *        1 = unfreeze PoolCreator,
     *        2 = unfreeze Evaluator,
     *        3 = unfreeze All roles.
     */
    function unfreezeRoles(address user, uint8 freezeType) external onlyOwnerOrAuthorized {
        require(freezeType < 4, "Invalid freeze type");
        if (freezeType == 0 || freezeType == 3) {
            require(stakers[user].validatorStake > 0, "User is not a validator");
            validatorFrozen[user] = false;
            emit RoleFreezeUpdated(user, "Validator", false);
        }
        if (freezeType == 1 || freezeType == 3) {
            require(stakers[user].poolCreatorStake > 0, "User is not a pool creator");
            poolCreatorFrozen[user] = false;
            emit RoleFreezeUpdated(user, "PoolCreator", false);
        }
        if (freezeType == 2 || freezeType == 3) {
            require(stakers[user].evaluatorStake > 0, "User is not an evaluator");
            evaluatorFrozen[user] = false;
            emit RoleFreezeUpdated(user, "Evaluator", false);
        }
    }
    
    /**
     * @notice Slash a portion of the PoolCreator stake by specifying whether to check the threshold.
     * @param user The address to slash.
     * @param amount The amount to slash.
     * @param checkThreshold If true, revoke role when stake falls below threshold. If false, maintain role.
     */
    function slashPoolCreator(address user, uint256 amount, bool checkThreshold) public onlyOwnerOrAuthorized nonReentrant {
        uint256 stake = stakers[user].poolCreatorStake;
        require(stake >= amount, "Cannot slash more than staked for PoolCreator role");
        stakers[user].poolCreatorStake -= amount;
        (bool sent, ) = payable(owner()).call{value: amount}("");
        require(sent, "Failed to send ETH to owner");
        
        if (checkThreshold && stakers[user].poolCreatorStake < poolCreatorThreshold) {
            stakers[user].poolCreatorStake = 0;
            emit RoleRevoked(user, "PoolCreator");
        }
        
        emit Slashed(user, "PoolCreator", amount);
    }
    
    /**
     * @notice Legacy function to maintain compatibility with existing contracts.
     * @param user The address to slash.
     * @param amount The amount to slash.
     */
    function slashPoolCreator(address user, uint256 amount) external onlyOwnerOrAuthorized nonReentrant {
        slashPoolCreator(user, amount, true);
    }
    
    /**
     * @notice Slash a portion of the Evaluator stake. If the remaining stake is less than the threshold, revokes the role.
     * @param user The address to slash.
     * @param amount The amount to slash.
     */
    function slashEvaluator(address user, uint256 amount) external onlyOwnerOrAuthorized nonReentrant {
        uint256 stake = stakers[user].evaluatorStake;
        require(stake >= amount, "Cannot slash more than staked for Evaluator role");
        stakers[user].evaluatorStake -= amount;
        (bool sent, ) = payable(owner()).call{value: amount}("");
        require(sent, "Failed to send ETH to owner");
        if (stakers[user].evaluatorStake < evaluatorThreshold) {
            stakers[user].evaluatorStake = 0;
            emit RoleRevoked(user, "Evaluator");
        }
        emit Slashed(user, "Evaluator", amount);
    }
    
    /**
     * @notice Update the authorization status of an external contract.
     * @param contractAddress The contract's address.
     * @param status The new authorization status.
     */
    function updateAuthorizedAddress(address contractAddress, bool status) external onlyOwner {
        require(contractAddress != address(0), "Invalid contract address");
        authorizedContracts[contractAddress] = status;
        emit AuthorizationUpdated(contractAddress, status);
    }
    
    /**
     * @notice Update the thresholds for roles. Callable only by the owner.
     * @param _validatorThreshold New threshold for Validator role.
     * @param _poolCreatorThreshold New threshold for PoolCreator role.
     * @param _evaluatorThreshold New threshold for Evaluator role.
     */
    function updateThresholds(
        uint256 _validatorThreshold,
        uint256 _poolCreatorThreshold,
        uint256 _evaluatorThreshold
    ) external onlyOwner {
        validatorThreshold = _validatorThreshold;
        poolCreatorThreshold = _poolCreatorThreshold;
        evaluatorThreshold = _evaluatorThreshold;
        emit ThresholdsUpdated(_validatorThreshold, _poolCreatorThreshold, _evaluatorThreshold);
    }
    
    // =======================================
    // Reward Functions (Managed by Authorized Contracts or Owner)
    // =======================================
    
    /**
     * @notice Adjust a user's reward balance.
     * @param user The address whose rewards are to be adjusted.
     * @param amount The amount by which to adjust.
     * @param op Operation type: 0 for addition, 1 for subtraction.
     * Callable only by the owner or an authorized contract.
     */
    function adjustReward(address user, uint256 amount, uint8 op) external onlyOwnerOrAuthorized nonReentrant {
        require(op == 0 || op == 1, "Invalid operation type");
        
        if (op == 0) {
            rewards[user] += amount;
            totalRewardsOutstanding += amount;
            require(address(this).balance >= totalRewardsOutstanding, "Insufficient contract balance for rewards");
        } else {
            require(rewards[user] >= amount, "Insufficient rewards for reduction");
            rewards[user] -= amount;
            totalRewardsOutstanding -= amount;
        }
        
        emit RewardAdjusted(user, op, amount, rewards[user]);
    }
    
    /**
     * @notice Claim accumulated reward ETH.
     */
    function claimReward() external nonReentrant {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards available");
        rewards[msg.sender] = 0;
        totalRewardsOutstanding -= reward;
        (bool sent, ) = payable(msg.sender).call{value: reward}("");
        require(sent, "Failed to send reward ETH");
        emit RewardClaimed(msg.sender, reward);
    }
    
    // =======================================
    // Getter Functions for Staking
    // =======================================
    
    function getValidatorStake(address user) external view returns (uint256) {
        return stakers[user].validatorStake;
    }
    
    function getPoolCreatorStake(address user) external view returns (uint256) {
        return stakers[user].poolCreatorStake;
    }
    
    function getEvaluatorStake(address user) external view returns (uint256) {
        return stakers[user].evaluatorStake;
    }
    
    /**
     * @notice Get the total roles purchased by a user.
     * @param user The address of the user.
     * @return An array of strings representing the roles the user has purchased.
     *         If no roles have been purchased, returns an array with a single element "None".
     */
    function getUserRoles(address user) external view returns (string[] memory) {
        uint256 count = 0;
        if (stakers[user].validatorStake > 0) count++;
        if (stakers[user].poolCreatorStake > 0) count++;
        if (stakers[user].evaluatorStake > 0) count++;
        
        if (count == 0) {
            string[] memory noneArray = new string[](1);
            noneArray[0] = "None";
            return noneArray;
        }
        
        string[] memory roles = new string[](count);
        uint256 index = 0;
        if (stakers[user].validatorStake > 0) {
            roles[index] = "Validator";
            index++;
        }
        if (stakers[user].poolCreatorStake > 0) {
            roles[index] = "PoolCreator";
            index++;
        }
        if (stakers[user].evaluatorStake > 0) {
            roles[index] = "Evaluator";
            index++;
        }
        return roles;
    }
    
    /**
     * @notice Check if contract has sufficient balance to cover all rewards.
     * @return bool True if contract has enough ETH to cover all rewards, false otherwise.
     */
    function hasSufficientRewardBalance() external view returns (bool) {
        return address(this).balance >= totalRewardsOutstanding;
    }
    
    /**
     * @notice Get total outstanding rewards across all users.
     * @return Total amount of rewards that could potentially be claimed.
     */
    function getTotalRewardsOutstanding() external view returns (uint256) {
        return totalRewardsOutstanding;
    }
    
    /**
     * @notice Get the freeze status of a user's roles.
     * @param user The address of the user.
     * @return validatorIsLocked True if the user's Validator role is frozen.
     * @return poolCreatorIsLocked True if the user's PoolCreator role is frozen.
     * @return evaluatorIsLocked True if the user's Evaluator role is frozen.
     */
    function getFreezeStatus(address user) external view returns (bool validatorIsLocked, bool poolCreatorIsLocked, bool evaluatorIsLocked) {
        return (validatorFrozen[user], poolCreatorFrozen[user], evaluatorFrozen[user]);
    }
    function getReward(address user) external view returns (uint256) {
    return rewards[user];
}
}