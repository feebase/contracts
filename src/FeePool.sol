// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts@4.9.5/token/ERC20/extensions/IERC20Metadata.sol";
import { SwapConfig } from "./SwapConfig.sol";
import { ICustomRouter } from "./ICustomRouter.sol";
import { IWETH } from "./IWETH.sol";

contract FeePool {
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    address public immutable STAKER;
    address public immutable FEE_POOL_TEMPLATE;
    SwapConfig public immutable SWAP_CONFIG;

    IERC20Metadata public rewardToken;
    uint256 public rewardScalar;
    uint256 public rewardDuration;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalStakes;
    mapping(address => uint256) public userStakes;
    mapping(address => uint256) private _userRewardPerTokenPaid;
    mapping(address => uint256) private _userPaidRewards;
    mapping(address => uint256) private _userUnpaidRewards;

    bool private _withdrawing;

    event AddReward(
        uint256 quantity,
        uint256 timestamp
    );

    event ClaimReward(
        address indexed user,
        uint quantity,
        uint timestamp
    );

    event Stake(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event Unstake(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    modifier updateReward(address user) {
        rewardPerTokenStored = getRewardPerToken();
        lastUpdateTime = getLastTimeRewardApplicable();
        if (user != address(0)) {
            _userUnpaidRewards[user] = getUnpaidRewards(user);
            _userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyStaker() {
        require(msg.sender == STAKER, "Only Staker");
        _;
    }

    constructor(address staker, address swapConfig) {
        FEE_POOL_TEMPLATE = address(this);
        STAKER = staker;
        SWAP_CONFIG = SwapConfig(swapConfig);
    }

    function init(address token, uint duration) external {
        require(duration > 0, "Invalid Duration");
        require(rewardDuration == 0, "Already Initialized");
        rewardDuration = duration;
        rewardToken = IERC20Metadata(token);
        uint decimals = rewardToken.decimals();
        rewardScalar = decimals < 18 ? (10 ** (18 - decimals)) : 1;
    }

    function stake(address user, uint256 amount) external onlyStaker updateReward(user) {
        require(amount > 0, "Cannot stake 0");
        totalStakes += amount;
        userStakes[user] += amount;
        emit Stake(user, amount, block.timestamp);
    }

    function unstake(address user, uint256 amount) public onlyStaker updateReward(user) {
        require(amount > 0, "Cannot unstake 0");
        totalStakes -= amount;
        userStakes[user] -= amount;
        emit Unstake(user, amount, block.timestamp);
    }

    function claimReward(address user) public onlyStaker updateReward(user) returns (address, uint256) {
        address recipient = user == STAKER ? address(SWAP_CONFIG) : user;
        uint256 quantity = _userUnpaidRewards[user];
        if (quantity > 0) {
            _userUnpaidRewards[user] = 0;
            _userPaidRewards[user] += quantity;
            if (address(rewardToken) == address(WETH)) {
                _withdrawing = true;
                WETH.withdraw(quantity);
                _withdrawing = false;
                (bool transferred,) = payable(recipient).call{value: quantity}("");
                require(transferred, "Transfer failed");
            } else {
                require(rewardToken.transfer(recipient, quantity), "Unable to transfer tokens");
            }
            emit ClaimReward(user, quantity, block.timestamp);
        }
        return (address(rewardToken), quantity);
    }

    receive() external payable {
        if (!_withdrawing) {
            addEthReward(new bytes(0));
        }
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
        uint balanceBefore = rewardToken.balanceOf(address(this));
        address router = SWAP_CONFIG.getRouter();
        IERC20(token).approve(router, quantity);
        ICustomRouter(router).swap(address(this), token, quantity, data);
        _addReward(rewardToken.balanceOf(address(this)) - balanceBefore);
    }

    function _addReward(uint256 reward) internal updateReward(address(0)) {
        require(reward > 0, "Invalid reward");
        reward *= rewardScalar;
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardDuration;
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the getUnpaidRewards and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balanceScaled = rewardToken.balanceOf(address(this)) * rewardScalar;
        require(rewardRate <= (balanceScaled / rewardDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;
        emit AddReward(reward / rewardScalar, block.timestamp);
    }

    function getLastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function getRewardPerToken() public view returns (uint256) {
        if (totalStakes == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (
            (getLastTimeRewardApplicable() - lastUpdateTime)
            * rewardRate
            * 1e18
            / totalStakes
        );
    }

    function getUnpaidRewards(address user) public view returns (uint256) {
        return (
            userStakes[user]
            * (getRewardPerToken() - _userRewardPerTokenPaid[user])
            / 1e18
            / rewardScalar
        ) + _userUnpaidRewards[user];
    }

    function getPaidRewards(address user) external view returns (uint256) {
        return _userPaidRewards[user];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardDuration / rewardScalar;
    }
}
