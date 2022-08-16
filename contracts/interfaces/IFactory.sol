// SPDX-License-Identifier: MIT
pragma solidity >=0.8.9;

interface IFactory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        bool stable,
        address pair,
        uint256
    );

    event NewTreasury(address indexed oldTreasury, address indexed newTreasury);

    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);

    function feeTo() external view returns (address);

    function governor() external view returns (address);

    function allPairs(uint256) external view returns (address);

    function isPair(address pair) external view returns (bool);

    function getPair(
        address tokenA,
        address token,
        bool stable
    ) external view returns (address);

    function allPairsLength() external view returns (uint256);

    function pairCodeHash() external pure returns (bytes32);

    function getInitializable()
        external
        view
        returns (
            address,
            address,
            bool
        );

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);

    function setFeeTo(address _feeTo) external;

    function setGovernor(address _governor) external;
}
