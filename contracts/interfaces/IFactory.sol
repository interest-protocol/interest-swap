// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IFactory {
    function getInitializable()
        external
        view
        returns (
            address,
            address,
            bool
        );

    function governor() external view returns (address);

    function feeTo() external view returns (address);
}
