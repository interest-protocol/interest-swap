// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

//solhint-disable
contract Helper {
    function sortTokens(address tokenA, address tokenB)
        public
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "Router: Same address");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Router: Zero address");
    }
}
