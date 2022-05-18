//SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../interfaces/IERC20.sol";

library Address {
    /**
     * @dev Safe version of the {ERC20 transfer} that reverts on failure.
     *
     * @param token The address of the ERC20
     * @param to The address that will receive the ERC20 tokens
     * @param amount The number of `token` that will be sent to the `to` address.
     *
     * Requirements:
     *
     * - The `token` must be a contract.
     * - {ERC20 transfer} must return the boolean true and no data or true in the data
     */
    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        require(token.code.length > 0, "Address: not a contract");
        //solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        // Check that it returned the boolean true or no bytes or true in bytes
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Address: failed to transfer"
        );
    }
}
