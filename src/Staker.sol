// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts@4.9.5/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts@4.9.5/proxy/Clones.sol";
import { EnumerableMap } from "@openzeppelin/contracts@4.9.5/utils/structs/EnumerableMap.sol";
import { EnumerableSet } from "@openzeppelin/contracts@4.9.5/utils/structs/EnumerableSet.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts@4.9.5/security/ReentrancyGuard.sol";
import { StakerToken } from "./StakerToken.sol";
import { IStakerApp } from "./IStakerApp.sol";
import { IWETH } from "./IWETH.sol";

contract Staker is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    struct User {
        EnumerableSet.AddressSet apps;
        mapping(address => EnumerableMap.AddressToUintMap) appTokenStakes;
    }

    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    uint public constant UNRESTAKE_GAS_LIMIT = 5000000;
    address public immutable STAKER_TOKEN_TEMPLATE;

    EnumerableMap.UintToAddressMap private _tokenStakerToken;
    mapping(address => User) private _users;
    mapping(address => EnumerableSet.AddressSet) private _appUsers;
    mapping(address => EnumerableMap.AddressToUintMap) private _appTokenStakes;

    event Stake (
        address indexed user,
        address indexed app,
        address indexed token,
        uint quantity
    );

    event Unstake (
        address indexed user,
        address indexed app,
        address indexed token,
        uint quantity,
        bool forced
    );

    constructor() {
        STAKER_TOKEN_TEMPLATE = address(new StakerToken(address(this)));
    }

    receive() external payable { }

    function stake(address token, uint quantity, address app) external nonReentrant {
        require(ERC20(token).transferFrom(msg.sender, address(this), quantity), "Unable to transfer token");
        _getStakerToken(token).mint(msg.sender, quantity);
        _stake(app, token, quantity);
    }

    function stakeEth(address app) external payable nonReentrant {
        WETH.deposit{value: msg.value}();
        _getStakerToken(address(WETH)).mint(msg.sender, msg.value);
        _stake(app, address(WETH), msg.value);
    }

    function unstake(address token, uint quantity, address app) external nonReentrant {
        _unstake(app, token, quantity);
        _getStakerToken(token).burn(msg.sender, quantity);
        require(ERC20(token).transfer(msg.sender, quantity), "Unable to transfer token");
    }

    function unstakeEth(uint quantity, address app) external nonReentrant {
        _unstake(app, address(WETH), quantity);
        _getStakerToken(address(WETH)).burn(msg.sender, quantity);
        WETH.withdraw(quantity);
        (bool transferred,) = msg.sender.call{value: quantity}("");
        require(transferred, "Transfer failed");
    }

    function restake(address token, uint quantity, address fromApp, address toApp) external nonReentrant {
        _unstake(fromApp, token, quantity);
        _stake(toApp, token, quantity);
    }

    function _stake(address app, address token, uint quantity) internal {
        User storage user = _users[msg.sender];
        (,uint userStake) = user.appTokenStakes[app].tryGet(token);
        (,uint appStake) = _appTokenStakes[app].tryGet(token);

        require(quantity > 0, "Invalid token quantity");

        user.apps.add(app);
        user.appTokenStakes[app].set(token, userStake + quantity);
        _appTokenStakes[app].set(token, appStake + quantity);
        _appUsers[app].add(msg.sender);

        IStakerApp(app).onStake(msg.sender, token, quantity);

        emit Stake(msg.sender, app, token, quantity);
    }

    function _unstake(address app, address token, uint quantity) internal {
        User storage user = _users[msg.sender];
        (,uint userStake) = user.appTokenStakes[app].tryGet(token);
        (,uint appStake) = _appTokenStakes[app].tryGet(token);

        require(quantity > 0 && quantity <= userStake, "Invalid token quantity");

        if (userStake == quantity) {
            user.appTokenStakes[app].remove(token);
            if (user.appTokenStakes[app].length() == 0) {
                _appUsers[app].remove(msg.sender);
            }
        } else {
            user.appTokenStakes[app].set(token, userStake - quantity);
        }
        _appTokenStakes[app].set(token, appStake - quantity);

        bool forced = false;
        try IStakerApp(app).onUnstake{gas: UNRESTAKE_GAS_LIMIT}(msg.sender, token, quantity) { }
        catch { forced = true; }

        emit Unstake(msg.sender, app, token, quantity, forced);
    }

    function _getStakerToken(address token) internal returns (StakerToken) {
        uint tokenId = _tokenToId(token);
        (bool exists, address stakerToken) = _tokenStakerToken.tryGet(tokenId);
        if (!exists) {
            stakerToken = Clones.clone(STAKER_TOKEN_TEMPLATE);
            StakerToken(stakerToken).initialize(token);
            _tokenStakerToken.set(tokenId, stakerToken);
        }
        return StakerToken(stakerToken);
    }

    function _tokenToId(address token) internal pure returns (uint) {
        return uint(uint160(token));
    }

    function getUserApps(address user) external view returns (address[] memory) {
        return _users[user].apps.values();
    }
    function getUserAppAt(address user, uint index) external view returns (address) {
        return _users[user].apps.at(index);
    }
    function getNumUserApps(address user) external view returns (uint) {
        return _users[user].apps.length();
    }

    function getAppUsers(address app) external view returns (address[] memory) {
        return _appUsers[app].values();
    }
    function getAppUserAt(address app, uint index) external view returns (address) {
        return _appUsers[app].at(index);
    }
    function getNumAppUsers(address app) external view returns (uint) {
        return _appUsers[app].length();
    }

    function getAppStake(address app, address token) external view returns (uint) {
        (,uint appStake) = _appTokenStakes[app].tryGet(token);
        return appStake;
    }
    function getAppStakes(address app) external view returns (address[] memory, uint[] memory) {
        EnumerableMap.AddressToUintMap storage appStakes = _appTokenStakes[app];
        address[] memory tokens = appStakes.keys();
        uint[] memory stakes = new uint[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            stakes[i] = appStakes.get(tokens[i]);
        }
        return (tokens, stakes);
    }
    function getAppStakeAt(address app, uint index) external view returns (address, uint) {
        return _appTokenStakes[app].at(index);
    }
    function getNumAppStakes(address app) external view returns (uint) {
        return _appTokenStakes[app].length();
    }

    function getUserAppStake(address user, address app, address token) external view returns (uint) {
        (,uint userStake) = _users[user].appTokenStakes[app].tryGet(token);
        return userStake;
    }
    function getUserAppStakes(address user, address app) external view returns (address[] memory, uint[] memory) {
        EnumerableMap.AddressToUintMap storage userStakes = _users[user].appTokenStakes[app];
        address[] memory tokens = userStakes.keys();
        uint[] memory stakes = new uint[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            stakes[i] = userStakes.get(tokens[i]);
        }
        return (tokens, stakes);
    }
    function getUserAppStakeAt(address user, address app, uint index) external view returns (address, uint) {
        return _users[user].appTokenStakes[app].at(index);
    }
    function getNumUserAppStakes(address user, address app) external view returns (uint) {
        return _users[user].appTokenStakes[app].length();
    }

    function getStakerToken(address token) external view returns (address) {
        return _tokenStakerToken.get(_tokenToId(token));
    }
}