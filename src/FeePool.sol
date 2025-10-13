// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts@4.9.5/token/ERC20/extensions/IERC20Metadata.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts@4.9.5/security/ReentrancyGuard.sol";
import { SwapConfig } from "./SwapConfig.sol";
import { ICustomRouter } from "./ICustomRouter.sol";
import { IWETH } from "./IWETH.sol";

contract FeePool is ReentrancyGuard {
    /* ========== STATE VARIABLES ========== */
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    address public immutable FEE_APP;
    address public immutable FEE_POOL_TEMPLATE;
    IERC20Metadata public immutable REWARD_TOKEN;
    uint public immutable REWARD_TOKEN_SCALAR;
    SwapConfig public immutable SWAP_CONFIG;

    uint256 public rewardsDuration;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    constructor(address stakingApp, address rewardToken, address swapConfig) {
        FEE_POOL_TEMPLATE = address(this);
        FEE_APP = stakingApp;
        REWARD_TOKEN = IERC20Metadata(rewardToken);
        SWAP_CONFIG = SwapConfig(swapConfig);
        uint decimals = REWARD_TOKEN.decimals();
        REWARD_TOKEN_SCALAR = decimals < 18 ? (10 ** (18 - decimals)) : 1;
    }

    function init(uint duration) external {
        require(duration > 0 && rewardsDuration == 0, "Already Initialized");
        rewardsDuration = duration;
    }

    /* ========== VIEWS ========== */
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (
            (lastTimeRewardApplicable() - lastUpdateTime) 
            * rewardRate 
            * 1e18 
            / _totalSupply
        );
    }

    function earned(address user) public view returns (uint256) {
        return (
            _balances[user] 
            * (rewardPerToken() - userRewardPerTokenPaid[user]) 
            / 1e18 
            / REWARD_TOKEN_SCALAR
        ) + rewards[user];

    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration / REWARD_TOKEN_SCALAR;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(address user, uint256 amount) external nonReentrant onlyFeeApp updateReward(user) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[user] += amount;
        emit Staked(user, amount, block.timestamp);
    }

    function withdraw(address user, uint256 amount) public nonReentrant onlyFeeApp updateReward(user) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[user] -= amount;
        emit Withdrawn(user, amount, block.timestamp);
    }

    function payReward(address user) public onlyFeeApp nonReentrant updateReward(user) returns (uint256) {
        uint256 reward = rewards[user];
        if (reward > 0) {
            rewards[user] = 0;
            REWARD_TOKEN.transfer(user, reward);
            emit RewardPaid(user, reward, block.timestamp);
        }
        return reward;
    }

    receive() external payable {
        addEthReward(new bytes(0));
    }

    function addEthReward(bytes memory data) public payable {
        WETH.deposit{value: msg.value}();
        swapAndAddReward(address(WETH), msg.value, data);
    }

    function addTokenReward(address token, uint quantity, bytes memory data) public {
        require(IERC20(token).transferFrom(msg.sender, address(this), quantity), "Unable to transfer token");
        swapAndAddReward(token, quantity, data);
    }

    function swapAndAddReward(address token, uint quantity, bytes memory data) public {
        uint balanceBefore = REWARD_TOKEN.balanceOf(address(this));
        address router = SWAP_CONFIG.getRouter();
        IERC20(token).approve(router, quantity);
        ICustomRouter(router).swap(address(this), token, quantity, data);
        _addReward(REWARD_TOKEN.balanceOf(address(this)) - balanceBefore);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _addReward(uint256 reward) internal updateReward(address(0)) {
        require(reward > 0, "Invalid reward");
        reward *= REWARD_TOKEN_SCALAR;
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balanceScaled = REWARD_TOKEN.balanceOf(address(this)) * REWARD_TOKEN_SCALAR;
        require(rewardRate <= (balanceScaled / rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward / REWARD_TOKEN_SCALAR, block.timestamp);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address user) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (user != address(0)) {
            rewards[user] = earned(user);
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyFeeApp() {
        require(msg.sender == FEE_APP, "Only Fee App");
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward, uint256 timestamp);
    event Staked(address indexed user, uint256 amount, uint256 timestamp);
    event Withdrawn(address indexed user, uint256 amount, uint256 timestamp);
    event RewardPaid(address indexed user, uint256 reward, uint256 timestamp);
}