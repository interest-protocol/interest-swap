// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../interfaces/IERC20.sol";

contract Fees {
    address private immutable pair;
    address private immutable token0;
    address internal immutable token1;

    constructor(address _token0, address _token1) {
        pair = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) private {
        assert(token.code.length > 0);
        //solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "PairHelper: failed to transfer"
        );
    }

    function claimFor(
        address recipient,
        uint256 amount0,
        uint256 amount1
    ) external {
        require(msg.sender == pair, "PairHelper: only the pair");
        if (amount0 > 0) _safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) _safeTransfer(token0, recipient, amount1);
    }
}
