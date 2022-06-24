// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

interface IFees {
    function claimFor(
        address recipient,
        uint256 amount0,
        uint256 amount1
    ) external;
}
