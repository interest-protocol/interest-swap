// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./Pair.sol";

contract VolatilePair is Pair {
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
        (uint256 reserveA, uint256 reserveB) = tokenIn == token0
            ? (_reserve0, _reserve1)
            : (_reserve1, _reserve0);
        return (amountIn * reserveB) / (reserveA + amountIn);
    }

    function _k(uint256 x, uint256 y) internal pure override returns (uint256) {
        return x * y; // xy >= k
    }
}
