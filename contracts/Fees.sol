// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./interfaces/IERC20.sol";

/**
 *@dev This contract holds all tokens accrued by swap fees by a pair. Each Pair Contract creates a Fees Contract.
 * Only the pair can transfer tokens in and out from it.
 */
contract Fees {
    // The pair contract that created it.
    address private immutable pair;
    // Token0 of the pair
    address private immutable token0;
    // Token1 of the pair
    address private immutable token1;

    constructor(address _token0, address _token1) {
        pair = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    // We need to manually take care of the failure cases because we are doing a low level call.
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
        // Check that it returned the boolean true or no bytes or true in bytes
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "PairHelper: failed to transfer"
        );
    }

    /**
     * @dev The pair calls this function to transfer the fees accrued by LP providers. The amount is calculated in the pair.
     *
     * @param recipient The address that will receive the fees.
     * @param amount0 Fees collected by token0 of the pair.
     * @param amount1 Fees collected by the token1 of the pair.
     *
     * Requirements:
     *
     * - Only the pair can call this function.
     * - 0 amounts will not revert, they will simply have no effect.
     */
    function claimFor(
        address recipient,
        uint256 amount0,
        uint256 amount1
    ) external {
        require(msg.sender == pair, "PairHelper: only the pair");
        if (amount0 > 0) _safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) _safeTransfer(token1, recipient, amount1);
    }
}
