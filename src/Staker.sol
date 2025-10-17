// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts@4.9.5/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts@4.9.5/token/ERC20/IERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts@4.9.5/utils/structs/EnumerableSet.sol";
import { EnumerableMap } from "@openzeppelin/contracts@4.9.5/utils/structs/EnumerableMap.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts@4.9.5/security/ReentrancyGuard.sol";
import { StakeCredit } from "./StakeCredit.sol";
import { SwapConfig } from "./SwapConfig.sol";
import { FeePool } from "./FeePool.sol";

contract Staker is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    address public immutable STAKER;
    address public immutable SWAP_CONFIG;

    address private _poolTemplate;
    address private _stakeCreditTemplate;

    EnumerableSet.AddressSet private _listedTokens;
    mapping(bytes32 => address) private _poolByKey;
    mapping(address => address) private _tokenStakeCredit;
    mapping(address => EnumerableSet.AddressSet) private _tokenListedPools;
    mapping(address => EnumerableSet.AddressSet) private _tokenStakers;

    struct Account {
        EnumerableSet.AddressSet delegates;
        EnumerableMap.AddressToUintMap tokenStakes;
        mapping(address => EnumerableSet.AddressSet) tokenPools;
    }
    struct Pool {
        address stakeToken;
        address rewardToken;
        uint rewardDuration;
        uint stakes;
        bool errors;
    }

    mapping(address => Account) private _accounts;
    mapping(address => Pool) private _pools;

    event ClaimFee (
        address indexed account,
        address indexed pool,
        address indexed token,
        uint quantity,
        uint timestamp
    );

    event Stake (
        address indexed user,
        address indexed token,
        uint quantity,
        uint timestamp
    );

    event Unstake (
        address indexed user,
        address indexed token,
        uint quantity,
        uint timestamp
    );

    modifier isAuthorized(address user) {
        require(
            msg.sender == user || (
                address(this) == user && msg.sender == owner()
            ),
            "Invalid account"
        );
        _;
    }

    constructor(address staker, address swapConfig) {
        STAKER = staker;
        SWAP_CONFIG = swapConfig;
        _poolTemplate = address(new FeePool(address(this), swapConfig));
        _stakeCreditTemplate = address(new StakeCredit(address(this)));
    }

    function createPool(address stakeToken, address rewardToken, uint rewardDurationDays) external returns (address) {
        bytes32 poolKey = _getPoolKey(stakeToken, rewardToken, rewardDurationDays);
        require(_poolByKey[poolKey] == address(0), "Pool already exists");

        address payable pool = payable(Clones.clone(_poolTemplate));
        FeePool(pool).init(rewardToken, rewardDurationDays * (1 days));
        FeePool(pool).stake(address(this), 1); // smallest amount, funds are never trapped if nobody else stakes

        _poolByKey[poolKey] = pool;
        _pools[pool] = Pool({
            stakeToken: stakeToken,
            rewardToken: rewardToken,
            rewardDuration: rewardDurationDays,
            stakes: 0,
            errors: false
        });
        return pool;
    }

    function stake(
        address user,
        address token,
        uint quantity,
        address[] memory customPools
    ) external nonReentrant isAuthorized(user) {
        require(quantity > 0, "Invalid token quantity");
        require(IERC20(token).transferFrom(user, address(this), quantity), "Unable to stake token");
        _getStakeCredit(token).mint(user, quantity);

        Account storage account = _accounts[user];
        (bool staking, uint stakes) = account.tokenStakes.tryGet(token);
        account.tokenStakes.set(token, stakes + quantity);

        if (staking) {
            // Add stake to the account's existing pools
            address[] memory pools = account.tokenPools[token].values();
            for (uint i = 0; i < pools.length; i++) {
                address payable pool = payable(pools[i]);
                FeePool(pool).stake(user, quantity);
                _pools[pool].stakes += quantity;
            }
        } else {
            _tokenStakers[token].add(user);
        }

        if (customPools.length > 0) {
            joinPools(user, customPools);
        } else {
            joinPools(user, _tokenListedPools[token].values());
        }

        emit Stake(user, token, quantity, block.timestamp);
    }

    function unstake(
        address user,
        address token,
        uint quantity
    ) public nonReentrant isAuthorized(user) {
        _getStakeCredit(token).burn(user, quantity);
        Account storage account = _accounts[user];
        EnumerableSet.AddressSet storage tokenPools = account.tokenPools[token];
        uint stakes = account.tokenStakes.get(token);
        bool unstakeAll = quantity == stakes;
        require(quantity > 0 && quantity <= stakes, "Invalid token quantity");

        address[] memory pools = tokenPools.values();
        if (unstakeAll) {
            leavePools(user, pools, false);
            _tokenStakers[token].remove(user);
        } else {
            for (uint i = 0; i < pools.length; i++) {
                address payable pool = payable(pools[i]);
                try FeePool(pool).unstake(user, quantity) { }
                catch {
                    _pools[pool].errors = true;
                }
                _pools[pool].stakes -= quantity;
            }
        }
        account.tokenStakes.set(token, stakes - quantity);

        require(IERC20(token).transfer(user, quantity), "Unable to transfer tokens");

        emit Unstake(user, token, quantity, block.timestamp);
    }

    function joinPools(
        address user,
        address[] memory pools
    ) public isAuthorized(user) {
        Account storage account = _accounts[user];
        EnumerableMap.AddressToUintMap storage tokenStakes = account.tokenStakes;
        for (uint i = 0; i < pools.length; i++) {
            address payable pool = payable(pools[i]);
            address token = _pools[pool].stakeToken;
            (,uint quantity) = tokenStakes.tryGet(token);
            if (quantity > 0 && account.tokenPools[token].add(pool)) {
                FeePool(pool).stake(user, quantity);
                _pools[pool].stakes += quantity;
            }
        }
    }

    function leavePools(
        address user,
        address[] memory pools,
        bool useGasCap
    ) public isAuthorized(user) {
        Account storage account = _accounts[user];
        EnumerableMap.AddressToUintMap storage tokenStakes = account.tokenStakes;
        for (uint i = 0; i < pools.length; i++) {
            address payable pool = payable(pools[i]);
            address token = _pools[pool].stakeToken;
            (,uint quantity) = tokenStakes.tryGet(token);
            if (quantity > 0 && account.tokenPools[token].remove(pool)) {
                if (useGasCap) {
                    try FeePool(pool).unstake{ gas: 1000000 }(user, quantity) { }
                    catch {
                        _pools[pool].errors = true;
                    }
                } else {
                    try FeePool(pool).unstake(user, quantity) { }
                    catch {
                        _pools[pool].errors = true;
                    }
                }
                _pools[pool].stakes -= quantity;
            }
        }
        claimPoolRewards(user, pools, useGasCap);
    }

    function claimPoolRewards(
        address user,
        address[] memory pools,
        bool useGasCap
    ) public isAuthorized(user) {
        for (uint i = 0; i < pools.length; i++) {
            address payable pool = payable(pools[i]);
            if (useGasCap) {
                try FeePool(pool).claimReward{ gas: 1000000 }(user) returns (address token, uint quantity) {
                    if (quantity > 0) {
                        emit ClaimFee(user, pool, token, quantity, block.timestamp);
                    }
                } catch {
                    _pools[pool].errors = true;
                }
            } else {
                try FeePool(pool).claimReward(user) returns (address token, uint quantity) {
                    if (quantity > 0) {
                        emit ClaimFee(user, pool, token, quantity, block.timestamp);
                    }
                }
                catch {
                    _pools[pool].errors = true;
                }
            }
        }
    }

    function claimRewards(address user, address token) external {
        address[] memory pools = _accounts[user].tokenPools[token].values();
        claimPoolRewards(user, pools, false);
    }

    function forceClaimRewards(address user, address token) external {
        address[] memory pools = _accounts[user].tokenPools[token].values();
        claimPoolRewards(user, pools, true);
    }

    function forceUnstake(address user, address token) external {
        uint stakes = _accounts[user].tokenStakes.get(token);
        address[] memory pools = _accounts[user].tokenPools[token].values();
        require(stakes > 0, "Token not staked");
        leavePools(user, pools, true);
        unstake(user, token, stakes);
    }

    function addDelegate(address delegate) external {
        _accounts[msg.sender].delegates.add(delegate);
    }

    function removeDelegate(address delegate) external {
        _accounts[msg.sender].delegates.remove(delegate);
    }

    function listPool(address pool) external onlyOwner {
        address token = _pools[pool].stakeToken;
        require(token != address(0), "Pool not found");
        _tokenListedPools[token].add(pool);
        _listedTokens.add(token);
    }

    function delistPool(address pool) external onlyOwner {
        address token = _pools[pool].stakeToken;
        _tokenListedPools[token].remove(pool);
        if (_tokenListedPools[token].length() == 0) {
            _listedTokens.remove(token);
        }
    }

    function _getPoolKey(address stakeToken, address rewardToken, uint rewardDurationDays) internal pure returns (bytes32) {
        return keccak256(abi.encode(stakeToken, rewardToken, rewardDurationDays));
    }

    function _getStakeCredit(address token) internal returns (StakeCredit) {
        address stakeCredit = _tokenStakeCredit[token];
        if (stakeCredit != address(0)) {
            stakeCredit = Clones.clone(_stakeCreditTemplate);
            StakeCredit(stakeCredit).initialize(token);
            _tokenStakeCredit[token] = stakeCredit;
        }
        return StakeCredit(stakeCredit);
    }

    function setPoolTemplate(address poolTemplate) external onlyOwner {
        _poolTemplate = poolTemplate;
    }

    function setStakeCreditTemplate(address stakeCreditTemplate) external onlyOwner {
        _stakeCreditTemplate = stakeCreditTemplate;
    }

    function getPoolTemplate() external view returns (address) {
        return _poolTemplate;
    }

    function getStakeCreditTemplate() external view returns (address) {
        return _stakeCreditTemplate;
    }

    function getStakeCredit(address token) external view returns (address) {
        return _tokenStakeCredit[token];
    }

    // -- Pools
    function getPoolAddress(address stakeToken, address rewardToken, uint rewardDurationDays) external view returns (address) {
        bytes32 poolKey = _getPoolKey(stakeToken, rewardToken, rewardDurationDays);
        address pool = _poolByKey[poolKey];
        require(pool != address(0), "Pool not found");
        return pool;
    }
    function getPoolAddressUnchecked(address stakeToken, address rewardToken, uint rewardDurationDays) external view returns (address) {
        bytes32 poolKey = _getPoolKey(stakeToken, rewardToken, rewardDurationDays);
        return _poolByKey[poolKey];
    }
    function getPool(address pool) external view returns (Pool memory) {
        return _pools[pool];
    }
    function getPoolDestructured(address pool) external view returns (
        address stakeToken,
        address rewardToken,
        uint rewardDuration,
        uint stakes,
        bool errors
    ) {
        return (
            _pools[pool].stakeToken,
            _pools[pool].rewardToken,
            _pools[pool].rewardDuration,
            _pools[pool].stakes,
            _pools[pool].errors
        );
    }

    // -- Listed Tokens (Tokens with Listed Pools)
    function isListedToken(address token) external view returns (bool) {
        return _listedTokens.contains(token);
    }
    function getListedTokens() external view returns (address[] memory) {
        return _listedTokens.values();
    }
    function getListedTokenAt(uint index) external view returns (address) {
        return _listedTokens.at(index);
    }
    function getListedTokenCount() external view returns (uint) {
        return _listedTokens.length();
    }

    // -- Listed Pools
    function isListedPool(address token, address pool) external view returns (bool) {
        return _tokenListedPools[token].contains(pool);
    }
    function getListedPools(address token) external view returns (address[] memory) {
        return _tokenListedPools[token].values();
    }
    function getListedPoolAt(address token, uint index) external view returns (address) {
        return _tokenListedPools[token].at(index);
    }
    function getListedPoolCount(address token) external view returns (uint) {
        return _tokenListedPools[token].length();
    }

    // -- User Pools
    function hasJoinedPool(address user, address token, address pool) external view returns (bool) {
        return _accounts[user].tokenPools[token].contains(pool);
    }
    function getJoinedPools(address user, address token) external view returns (address[] memory) {
        return _accounts[user].tokenPools[token].values();
    }
    function getJoinedPoolAt(address user, address token, uint index) external view returns (address) {
        return _accounts[user].tokenPools[token].at(index);
    }
    function getJoinedPoolCount(address user, address token) external view returns (uint) {
        return _accounts[user].tokenPools[token].length();
    }

    // -- Token Stakers
    function isStaker(address token, address user) external view returns (bool) {
        return _tokenStakers[token].contains(user);
    }
    function getStakers(address token) external view returns (address[] memory) {
        return _tokenStakers[token].values();
    }
    function getStakerAt(address token, uint index) external view returns (address) {
        return _tokenStakers[token].at(index);
    }
    function getStakerCount(address token) external view returns (uint) {
        return _tokenStakers[token].length();
    }

    // -- User Delegates
    function isDelegate(address user, address delegate) external view returns (bool) {
        return _accounts[user].delegates.contains(delegate);
    }
    function getDelegates(address user) external view returns (address[] memory) {
        return _accounts[user].delegates.values();
    }
    function getDelegates(address user, uint index) external view returns (address) {
        return _accounts[user].delegates.at(index);
    }
    function getDelegateCount(address user) external view returns (uint) {
        return _accounts[user].delegates.length();
    }

    // -- User Token Stakes
    function getStake(address user, address token) external view returns (uint) {
        (,uint stakes) = _accounts[user].tokenStakes.tryGet(token);
        return stakes;
    }
    function getStakes(address user) external view returns (address[] memory tokens, uint[] memory stakes) {
        EnumerableMap.AddressToUintMap storage tokenStakes = _accounts[user].tokenStakes;
        tokens = tokenStakes.keys();
        stakes = new uint[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            stakes[i] = tokenStakes.get(tokens[i]);
        }
        return (tokens, stakes);
    }
    function getStakeAt(address user, uint index) external view returns (address, uint) {
        return _accounts[user].tokenStakes.at(index);
    }
    function getStakeCount(address user) external view returns (uint) {
        return _accounts[user].tokenStakes.length();
    }
}
