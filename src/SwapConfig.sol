// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts@4.9.5/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts@4.9.5/access/Ownable.sol";

contract SwapConfig is Ownable {
    address private _router;
    function setRouter(address router) external onlyOwner {
        _router = router;
    }
    function getRouter() external view returns (address) {
        return _router;
    }
    function claimEth(address payable recipient) external onlyOwner {
        (bool success,) = recipient.call{ value: address(this).balance }("");
        require(success, "ETH Transfer failed");
    }
    function claimToken(address token, address recipient) external onlyOwner {
        require(IERC20(token).transfer(
            recipient,
            IERC20(token).balanceOf(address(this))
        ), "Token transfer failed");
    }
}
