// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IV4Router.sol";

interface IUniswapV4Router is IV4Router {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint deadline) external payable;
}
