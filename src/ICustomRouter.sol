// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICustomRouter {
    function swap(
        address inputToken,
        uint inputQuantity,
        address outputToken,
        address recipient,
        bytes memory data
    ) external payable returns (uint);
}