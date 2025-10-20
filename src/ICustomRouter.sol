// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICustomRouter {
    function swap(address recipient, address token, uint quantity, bytes memory data) external payable returns (uint);
}
