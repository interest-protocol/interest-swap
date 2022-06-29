// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./Pair.sol";

contract StablePair is Pair {
    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _f(uint256 x0, uint256 y) private pure returns (uint256) {
        return
            (x0 * ((((y * y) / 1e18) * y) / 1e18)) /
            1e18 +
            (((((x0 * x0) / 1e18) * x0) / 1e18) * y) /
            1e18;
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _d(uint256 x0, uint256 y) private pure returns (uint256) {
        return
            (3 * x0 * ((y * y) / 1e18)) /
            1e18 +
            ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _getY(
        uint256 x0,
        uint256 xy,
        uint256 y
    ) private pure returns (uint256) {
        for (uint256 i = 0; i < 255; i++) {
            uint256 yPrev = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > yPrev) {
                if (y - yPrev <= 1) {
                    return y;
                }
            } else {
                if (yPrev - y <= 1) {
                    return y;
                }
            }
        }
        return y;
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _k(uint256 x, uint256 y) internal view override returns (uint256) {
        uint256 _x = (x * 1e18) / decimals0;
        uint256 _y = (y * 1e18) / decimals1;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
        return (_a * _b) / 1e18; // x3y+y3x >= k
    }

    /**
     * @dev https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
     *
     * @param amountIn The number of `tokenIn` being sold
     * @param tokenIn The token being sold
     * @param _reserve0 current reserves of token0
     * @param _reserve1 current reserves of token1
     * @return amountOut How many tokens of the other tokens were bought
     */
    function _computeAmountOut(
        uint256 amountIn,
        address tokenIn,
        uint256 _reserve0,
        uint256 _reserve1
    ) internal view override returns (uint256 amountOut) {
        uint256 xy = _k(_reserve0, _reserve1);
        _reserve0 = (_reserve0 * 1e18) / decimals0;
        _reserve1 = (_reserve1 * 1e18) / decimals1;
        (uint256 reserveA, uint256 reserveB) = tokenIn == token0
            ? (_reserve0, _reserve1)
            : (_reserve1, _reserve0);
        amountIn = tokenIn == token0
            ? (amountIn * 1e18) / decimals0
            : (amountIn * 1e18) / decimals1;
        uint256 y = reserveB - _getY(amountIn + reserveA, xy, reserveB);
        return (y * (tokenIn == token0 ? decimals1 : decimals0)) / 1e18;
    }
}
