// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

library UniswapMath {
    function encodePriceSqrt(uint256 amountTokenA, uint256 amountTokenB) internal pure returns (uint160) {
        // sqrtPriceX96 = sqrt(amountTokenB / amountTokenA) * 2^96
        return uint160((sqrt((amountTokenB * (2**192)) / amountTokenA)));
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}