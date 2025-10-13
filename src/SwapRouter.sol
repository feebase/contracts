// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts@4.9.5/token/ERC20/IERC20.sol";
import { Ownable} from "@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import { ISwapRouter } from "../Uniswap/ISwapRouter.sol";
import { IUniswapV4Router, IV4Router } from "../UniswapV4/interfaces/IUniswapV4Router.sol";
import { IAllowanceTransfer } from "../UniswapV4/interfaces/IAllowanceTransfer.sol";
import { Actions } from "../UniswapV4/libraries/Actions.sol";
import { PoolKey } from "../UniswapV4/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "../UniswapV4/types/Currency.sol";
import { IHooks } from "../UniswapV4/interfaces/IHooks.sol";
import { Commands } from "../UniswapV4/libraries/Commands.sol";
import { ICustomRouter } from "./ICustomRouter.sol";
import { IWETH } from "./IWETH.sol";

contract SwapRouter is ICustomRouter, Ownable {
    using CurrencyLibrary for Currency;

    IAllowanceTransfer public constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IUniswapV4Router public constant UNISWAP_V4_ROUTER = IUniswapV4Router(0x6fF5693b99212Da76ad316178A184AB56D299b43);
    ISwapRouter public constant UNISWAP_V3_ROUTER = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    address private _treasury;

    uint public constant ROUTE_WRAP = 1;
    uint public constant ROUTE_UNIV3 = 3;
    uint public constant ROUTE_UNIV4 = 4;

    struct Route {
        uint version;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        address hook;
    }

    mapping(address => Route) private _routes;

    constructor(address treasury) {
        _treasury = treasury;

        Route storage route = _routes[address(0)];
        route.version = ROUTE_WRAP;
        route.tokenOut = address(WETH);
    }

    receive() external payable {}

    function swap(address recipient, address token, uint quantity, bytes memory /*data*/) external payable returns (uint) {
        if (quantity > 0) {
            if (token == address(0)) {
                require(quantity == msg.value, "ETH sent mismatches input");
            } else {
                require(msg.value == 0, "Unable to swap ETH and token simultaneously");
                require(IERC20(token).transferFrom(msg.sender, address(this), quantity), "Unable to transfer tokens");
            } 
        } else {
            revert("No funding specified");
        }
        Route memory route;
        while (token != address(USDC)) {
            route = _routes[token];
            // Convert all ETH to WETH inputs
            if (route.version == ROUTE_WRAP) {
                WETH.deposit{ value: _balance(token) }();
            } else if (route.version == ROUTE_UNIV3) {
                _swapUniswapV3(route, _balance(token));
            } else if (route.version == ROUTE_UNIV4) {
                _swapUniswapV4(route, _balance(token));
            } else {
                revert("Route not found");
            }
            token = route.tokenOut;
        }
        uint balance = _balance(address(USDC));
        uint fee = balance / 100;
        if (balance > 0) {
            USDC.transfer(recipient, balance - fee);
        }
        if (fee > 0) {
            USDC.transfer(_treasury, fee);
        }
        return balance - fee;
    }

    function _isEth(address token) internal pure returns (bool) {
        return token == address(0);
    }

    function _balance(address token) internal view returns (uint) {
        return _isEth(token) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _swapUniswapV3(Route memory route, uint amountIn) internal {
        IERC20(route.tokenIn).approve(address(UNISWAP_V3_ROUTER), type(uint256).max);
        UNISWAP_V3_ROUTER.exactInputSingle{ value: _isEth(route.tokenIn) ? amountIn : 0 }(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: route.tokenIn,
                tokenOut: route.tokenOut,
                fee: route.fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapUniswapV4(Route memory route, uint amountIn) internal {
        bool zeroForOne = true;
        address token0 = route.tokenIn;
        address token1 = route.tokenOut;
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            zeroForOne = false;
        }

        PoolKey memory key = PoolKey(
            Currency.wrap(token0),
            Currency.wrap(token1),
            route.fee,
            route.tickSpacing,
            IHooks(route.hook)
        );

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, 0);

        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        if (_isEth(route.tokenIn)) {
            UNISWAP_V4_ROUTER.execute{ value: amountIn }(commands, inputs, block.timestamp);
        } else {
            IERC20(route.tokenIn).approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(address(route.tokenIn), address(UNISWAP_V4_ROUTER), type(uint160).max, type(uint48).max);
            UNISWAP_V4_ROUTER.execute(commands, inputs, block.timestamp);
        }
    }

    function setRoute(
        uint version, 
        address tokenIn, 
        address tokenOut, 
        uint24 fee, 
        int24 tickSpacing, 
        address hook
    ) external onlyOwner {
        require(version == ROUTE_UNIV3 || version == ROUTE_UNIV4, "Invalid version");
        require(tokenIn != address(0), "tokenIn must be non-zero");
        _routes[tokenIn] = Route({
            version: version,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            tickSpacing: tickSpacing,
            hook: hook
        });
    }
    function setTreasury(address treasury) external onlyOwner {
        _treasury = treasury;
    }

    function getRoute(address tokenIn) external view returns (Route memory) {
        return _routes[tokenIn];
    }
    function getTreasury() external view returns (address) {
        return _treasury;
    }
}