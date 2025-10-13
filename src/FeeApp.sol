// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts@4.9.5/proxy/Clones.sol";
import { Ownable} from "@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import { IERC20} from "@openzeppelin/contracts@4.9.5/token/ERC20/IERC20.sol";
import { EnumerableSet} from "@openzeppelin/contracts@4.9.5/utils/structs/EnumerableSet.sol";
import { EnumerableMap } from "@openzeppelin/contracts@4.9.5/utils/structs/EnumerableMap.sol";
import { SwapConfig } from "./SwapConfig.sol";
import { IStakerApp } from "./IStakerApp.sol";
import { FeePool } from "./FeePool.sol";
import { IWETH } from "./IWETH.sol";

contract FeeApp is IStakerApp, Ownable {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    address public immutable REWARD_TOKEN;
    address public immutable STAKER;
    address public immutable SWAP_CONFIG;

    uint private _maxPools;
    address private _poolTemplate;
    EnumerableSet.UintSet private _durations;
    EnumerableSet.AddressSet private _tokens;
    mapping(address => EnumerableSet.AddressSet) private _userPools;
    mapping(address => EnumerableSet.AddressSet) private _tokenPools;
    mapping(address => EnumerableSet.AddressSet) private _tokenStakers;
    mapping(address => mapping(address => uint)) private _userTokenStakes;
    mapping(address => mapping(address => uint)) private _userClaimedTokenFees;
    mapping(address => mapping(uint => address)) private _poolByTokenAndDuration;

    modifier onlyStaker {
        require(msg.sender == STAKER, "Only Staker");
        _;
    }

    constructor(address rewardToken, address staker, address swapConfig) {
        REWARD_TOKEN = rewardToken;
        STAKER = staker;
        SWAP_CONFIG = swapConfig;
        _poolTemplate = address(new FeePool(address(this), rewardToken, swapConfig));
        _maxPools = 6;
        _durations.add(7);
        _durations.add(30);
        _durations.add(60);
        _durations.add(90);
        _durations.add(180);
        _durations.add(365);
    }

    receive() external payable {}

    function createPool(address stakeToken, uint duration) external onlyOwner returns (address) {
        require(_poolByTokenAndDuration[stakeToken][duration] == address(0), "Pool already exists");
        require(_durations.contains(duration), "Unsupported Reward Duration");
        require(_tokenPools[stakeToken].length() < _maxPools, "Pool limit reached");

        address payable pool = payable(Clones.clone(_poolTemplate));
        FeePool(pool).init(duration * (1 days));
        FeePool(pool).stake(address(this), 1); // token amount so funds are never lost

        _poolByTokenAndDuration[stakeToken][duration] = pool;
        _tokenPools[stakeToken].add(pool);
        _tokens.add(stakeToken);

        return pool;
    }

    function onStake(address user, address token, uint quantity) external onlyStaker {
        address[] memory pools = _tokenPools[token].values();
        require(pools.length > 0, "No pools for token");

        EnumerableSet.AddressSet storage userPools = _userPools[user];
        uint stake = _userTokenStakes[user][token];
        uint newBalance = stake + quantity;

        for (uint i = 0; i < pools.length; i++) {
            address payable pool = payable(pools[i]);
            if (userPools.contains(pool)) {
                FeePool(pool).stake(user, quantity);
            } else {
                userPools.add(pool);
                FeePool(pool).stake(user, newBalance);
            }
        }
        _userTokenStakes[user][token] = newBalance;
        _tokenStakers[token].add(user);
    }

    function onUnstake(address user, address token, uint quantity) external onlyStaker {
        address[] memory pools = _tokenPools[token].values();

        EnumerableSet.AddressSet storage userPools = _userPools[user];
        uint stake = _userTokenStakes[user][token];
        require(quantity <= stake, "Invalid unstake amount");
        uint newBalance = stake - quantity;

        for (uint i = 0; i < pools.length; i++) {
            address payable pool = payable(pools[i]);
            if (userPools.contains(pool)) {
                FeePool(pool).withdraw(user, quantity);
            }
        }
        _userTokenStakes[user][token] = newBalance;
        if (newBalance == 0) {
            _tokenStakers[token].remove(user);
        }
    }

    function syncPools(address[] memory tokens) external {
        EnumerableSet.AddressSet storage userPools = _userPools[msg.sender];

        for (uint j = 0; j < tokens.length; j++) {
            address token = tokens[j];
            uint stake = _userTokenStakes[msg.sender][token];
            if (stake > 0) {
                address[] memory pools = _tokenPools[token].values();
                for (uint i = 0; i < pools.length; i++) {
                    address payable pool = payable(pools[i]);
                    if (!userPools.contains(pool)) {
                        userPools.add(pool);
                        FeePool(pool).stake(msg.sender, stake);
                    }
                }
            }
        }
    }

    function _claim(address user, address[] memory pools) internal returns (uint earnings) {
        for (uint i = 0; i < pools.length; i++) {
            earnings += FeePool(payable(pools[i])).payReward(user);
        }
    }

    function _pay(address user, uint quantity) internal {
        if (quantity > 0) {
            if (REWARD_TOKEN == address(WETH)) {
                WETH.withdraw(quantity);
                (bool transferred,) = payable(user).call{value: quantity}("");
                require(transferred, "Transfer failed");
            } else {
                require(IERC20(REWARD_TOKEN).transfer(user, quantity), "Unable to transfer tokens");
            }
        }
    }

    function claimTokenFees(address user, address[] memory tokens, address recipient) external returns (uint fees) {
        require(msg.sender == user || (msg.sender == owner() && user == address(this)), "Invalid user");
        for (uint i = 0; i < tokens.length; i++) {
            uint tokenFees = _claim(user, _tokenPools[tokens[i]].values());
            _userClaimedTokenFees[user][tokens[i]] += tokenFees;
            fees += tokenFees;
        }
        _pay(recipient, fees);
    }

    function claimProtocolFees(address recipient) external onlyOwner returns (uint fees) {
        fees = IERC20(REWARD_TOKEN).balanceOf(address(this));
        _pay(recipient, fees);
        return fees;
    }
    function setMaxPools(uint maxPools) external onlyOwner {
        require(maxPools > 0, "Invalid value");
        _maxPools = maxPools;
    }
    function addDuration(uint duration) external onlyOwner {
        require(duration > 0 && duration < 5000, "Invalid duration");
        _durations.add(duration);
    }
    function removeDuration(uint duration) external onlyOwner {
        _durations.remove(duration);
    }
    function setPoolTemplate(address poolTemplate) external onlyOwner {
        _poolTemplate = poolTemplate;
    }

    function getUnclaimedTokenFees(address user, address token) external view returns (uint fees) {
        address[] memory pools = _tokenPools[token].values();
        for (uint i = 0; i < pools.length; i++) {
            fees += FeePool(payable(pools[i])).earned(user);
        }
    }
    function getClaimedTokenFees(address user, address token) external view returns (uint fees) {
        return _userClaimedTokenFees[user][token];
    }

    function getTokens() external view returns (address[] memory) {
        return _tokens.values();
    }
    function getTokenAt(uint index) external view returns (address) {
        return _tokens.at(index);
    }
    function getNumTokens() external view returns (uint) {
        return _tokens.length();
    }

    function getUserPools(address user) external view returns (address[] memory) {
        return _userPools[user].values();
    }
    function getUserPoolAt(address user, uint index) external view returns (address) {
        return _userPools[user].at(index);
    }
    function getNumUserPools(address user) external view returns (uint) {
        return _userPools[user].length();
    }

    function getTokenPools(address token) external view returns (address[] memory) {
        return _tokenPools[token].values();
    }
    function getTokenPoolAt(address token, uint index) external view returns (address) {
        return _tokenPools[token].at(index);
    }
    function getNumTokenPools(address token) external view returns (uint) {
        return _tokenPools[token].length();
    }

    function getTokenStakers(address token) external view returns (address[] memory) {
        return _tokenStakers[token].values();
    }
    function getTokenStakerAt(address token, uint index) external view returns (address) {
        return _tokenStakers[token].at(index);
    }
    function getNumTokenStakers(address token) external view returns (uint) {
        return _tokenStakers[token].length();
    }

    function getPoolByTokenAndDuration(address token, uint duration) external view returns (address pool) {
        pool = _poolByTokenAndDuration[token][duration];
        require(pool != address(0), "Pool not found");
    }
    function getPoolByTokenAndDurationUnchecked(address token, uint duration) external view returns (address pool) {
        pool = _poolByTokenAndDuration[token][duration];
    }
    function getDurations() external view returns (uint[] memory) {
        return _durations.values();
    }
    function isDurationValid(uint duration) external view returns (bool) {
        return _durations.contains(duration);
    }

    function getPoolTemplate() external view returns (address) {
        return _poolTemplate;
    }
}
