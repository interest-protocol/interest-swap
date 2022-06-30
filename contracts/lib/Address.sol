//SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "../interfaces/IERC20.sol";

import "./Errors.sol";

library Address {
    function returnDataToString(bytes memory data)
        internal
        pure
        returns (string memory)
    {
        if (data.length >= 64) {
            return abi.decode(data, (string));
        } else if (data.length == 32) {
            uint8 i = 0;
            while (i < 32 && data[i] != 0) {
                i++;
            }
            bytes memory bytesArray = new bytes(i);
            for (i = 0; i < 32 && data[i] != 0; i++) {
                bytesArray[i] = data[i];
            }
            return string(bytesArray);
        } else {
            return "???";
        }
    }

    /// @notice Provides a safe ERC20.symbol version which returns '???' as fallback string.
    /// @param token The address of the ERC-20 token contract.
    /// @return (string) Token symbol.
    function safeSymbol(address token) internal view returns (string memory) {
        require(token.code.length > 0, "Address: not a contract");

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(IERC20.symbol.selector)
        );
        return success ? returnDataToString(data) : "???";
    }

    /// @notice Provides a safe ERC20.decimals version which returns '18' as fallback value.
    /// @param token The address of the ERC-20 token contract.
    /// @return (uint8) Token decimals.
    function safeDecimals(address token) internal view returns (uint8) {
        require(token.code.length > 0, "Address: not a contract");

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(IERC20.decimals.selector)
        );
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

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
        if (!success || !(data.length == 0 || abi.decode(data, (bool))))
            revert TransferFailed();
    }

    /**
     * @dev Returns the current balance of an ERC20 held by this contract.
     *
     * @param token The address of the ERC20 we will check the balance
     * @return uint256 The current balance of the contract
     */
    function currentBalance(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
