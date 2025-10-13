// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakerApp {
    function onStake(address user, address token, uint quantity) external;
    function onUnstake(address user, address token, uint quantity) external;
}