// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IFactory {
    function allPairsLength() external view returns (uint256);

    function isPair(address pair) external view returns (bool);

    function pairCodeHash() external pure returns (bytes32);

    function getPair(
        address tokenA,
        address token,
        bool stable
    ) external view returns (address);

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);

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
