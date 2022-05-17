// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./Pair.sol";

contract Factory {
    address public feeTo;
    address public governor;
    mapping(address => mapping(address => mapping(bool => address)))
        public getPair;
    address[] public allPairs;
    mapping(address => bool) public isPair;

    address private _temp0;
    address private _temp1;
    bool private _temp;

    event PairCreated(
        address indexed token0,
        address indexed token1,
        bool stable,
        address pair,
        uint256
    );

    constructor() {
        governor = msg.sender;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(Pair).creationCode);
    }

    function getInitializable()
        external
        view
        returns (
            address,
            address,
            bool
        )
    {
        return (_temp0, _temp1, _temp);
    }

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair) {
        require(tokenA != tokenB, "Factory: Invalid"); // BaseV1: IDENTICAL_ADDRESSES
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        require(token0 != address(0), "Factory: Zero address");
        require(getPair[token0][token1][stable] == address(0), "PE");
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));

        (_temp0, _temp1, _temp) = (token0, token1, stable);

        pair = address(new Pair{salt: salt}());
        getPair[token0][token1][stable] = pair;
        getPair[token1][token0][stable] = pair;

        allPairs.push(pair);
        isPair[pair] = true;

        emit PairCreated(token0, token1, stable, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == governor, "Factory: Unauthorized");
        feeTo = _feeTo;
    }

    function setGovernor(address _governor) external {
        require(
            msg.sender == governor && governor != address(0),
            "Factory: Unauthorized"
        );
        governor = _governor;
    }
}
