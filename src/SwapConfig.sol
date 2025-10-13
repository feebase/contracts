// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts@4.9.5/access/Ownable.sol";

contract SwapConfig is Ownable {
    address private _router;
    function setRouter(address router) external onlyOwner {
        _router = router;
    }
    function getRouter() external view returns (address) {
        return _router;
    }
}