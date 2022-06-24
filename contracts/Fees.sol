// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./interfaces/IFees.sol";

import "./lib/Address.sol";

/**
 *@dev This contract holds all tokens accrued by swap fees by a pair. Each Pair Contract creates a Fees Contract.
 * Only the pair can transfer tokens in and out from it.
 */
contract Fees is IFees {
    using Address for address;

    // The pair contract that created it.
    address private immutable pair;
    // Token0 of the pair
    address private immutable token0;
    // Token1 of the pair
    address private immutable token1;

    /**
     * @param _token0 The token0 of the pair who created this contract
     * @param _token1 The token1 of the pair who created this contract
     */
    constructor(address _token0, address _token1) {
        // This contract is meant to be created by a Pair
        pair = msg.sender;
        token0 = _token0;
        token1 = _token1;
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
        require(msg.sender == pair, "Fees: only the pair");
        if (amount0 > 0) token0.safeTransfer(recipient, amount0);
        if (amount1 > 0) token1.safeTransfer(recipient, amount1);
    }
}
