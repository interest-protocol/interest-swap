// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface IRouter {
    function addLiquidityNativeToken(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountNativeTokenMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountNativeToken,
            uint256 liquidity
        );
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract BrokenBNBReceiver {
    receive() external payable {
        revert("No BNB");
    }

    function addLiquidityBNB(
        IRouter router,
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    ) external payable {
        IERC20(token).approve(address(router), type(uint256).max);
        router.addLiquidityNativeToken{value: msg.value}(
            token,
            stable,
            amountTokenDesired,
            amountTokenMin,
            amountBNBMin,
            to,
            deadline
        );
    }
}
