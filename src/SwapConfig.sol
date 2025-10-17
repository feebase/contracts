// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts@4.9.5/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import { IWETH } from "./IWETH.sol";

contract SwapConfig is Ownable {
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    address private _router;
    function setRouter(address router) external onlyOwner {
        _router = router;
    }
    function getRouter() external view returns (address) {
        return _router;
    }
    receive () external payable {
        WETH.deposit{value: msg.value}();
    }
    function sendToken(address token, address recipient) external onlyOwner {
        require(IERC20(token).transfer(
            recipient,
            IERC20(token).balanceOf(address(this))
        ), "Token transfer failed");
    }
    function sendTokenQuantity(address token, address recipient, uint quantity) external onlyOwner {
        require(IERC20(token).transfer(
            recipient,
            quantity
        ), "Token transfer failed");
    }
    function approveSpenderQuantity(address token, address spender, uint quantity) external onlyOwner {
        IERC20(token).approve(
            spender,
            quantity
        );
    }
    function approveSpender(address token, address spender) external onlyOwner {
        IERC20(token).approve(
            spender,
            type(uint256).max
        );
    }
}
