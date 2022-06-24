// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;

import "../interfaces/IPair.sol";
import "../interfaces/IPairCallee.sol";
import "../interfaces/IERC20.sol";

//solhint-disable
contract FlashLoan is IPairCallee {
    event Hook(address sender, uint256 amount0, uint256 amount1, bytes data);

    IPair public pair;

    constructor(IPair _pair) {
        pair = _pair;
    }

    function loan(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external {
        pair.swap(amount0Out, amount1Out, to, data);
    }

    function hook(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        IERC20(pair.token0()).transfer(
            address(pair),
            IERC20(pair.token0()).balanceOf(address(this))
        );
        IERC20(pair.token1()).transfer(
            address(pair),
            IERC20(pair.token1()).balanceOf(address(this))
        );
        emit Hook(sender, amount0, amount1, data);
    }
}
