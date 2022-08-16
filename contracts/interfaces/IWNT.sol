// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "./IERC20.sol";

/// @notice IWNT stands for Wrapped Native Token Interface
interface IWNT is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}
