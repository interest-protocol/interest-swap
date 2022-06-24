// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./interfaces/IFactory.sol";

import "./Pair.sol";

/**
 * @dev Factory creates stable or volatile pairs for two ERC20s.
 * Anyone can create a pair between two ERC20
 * Volatile pair uses the constant product formula x * y = k
 * Stable pair uses the curve formula x3y+y3x >= k
 * This code is based on UniswapV2 and Solidly, all merit goes to them.
 */
contract Factory is IFactory {
    // Treasury address
    address public feeTo;
    // Int Governor.
    address public governor;

    // A list of all pairs deployed by this contract
    address[] public allPairs;
    // Quick way to verify if a pair address has been deployed by this factory
    mapping(address => bool) public isPair;
    // HashMap to quickly access the address of a pair given two tokens and a stable boolean value
    // Can be done Token0 -> Token1 -> Stable or Token1 -> Token0 -> Stable
    mapping(address => mapping(address => mapping(bool => address)))
        public getPair;

    // Pair contract deployed by the factory will read this data in its constructor by calling {getInitializable}
    address private _token0;
    address private _token1;
    bool private _stable;

    constructor() {
        governor = msg.sender;
    }

    /**
     *@return uint256 The number of pairs deployed
     */
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /**
     * @return bytes32 The hash of the creationCode of the pair contract. It is a helper for other contracts to predict create2 addresses
     */
    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(Pair).creationCode);
    }

    /**
     * @return (address, address, bool) The token0, token1 and stable needed for a pair to initialize.
     */
    function getInitializable()
        external
        view
        returns (
            address,
            address,
            bool
        )
    {
        return (_token0, _token1, _stable);
    }

    /**
     * @dev Deploys a pair contract using create2 and the arguments as the salt
     *
     * @param tokenA One of the ERC20 tokens of the new pair to be deployed
     * @param tokenB The second ERC20 token of the pair. Note it should be different than the `tokenA`.
     * @param stable Boolean value that will determine if the pair should use the constant product formula or the curve's formula
     *
     * Requirements:
     *
     * - `tokenA` and `tokenB` must be different
     * - `tokenA` and `tokenB` cannot be the zer0 address
     * - There must be no pair created with `tokenA`, `tokenB` and `stable`.
     */
    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair) {
        // Tokens must be different to create pair
        require(tokenA != tokenB, "Factory: Invalid");
        // Sort the pairs
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        // Make sure they are not the zero address
        require(token0 != address(0), "Factory: Zero address");
        // Make sure this specific pair has not been deployed
        require(
            getPair[token0][token1][stable] == address(0),
            "Factory: Already deployed"
        );

        // Create a salt to deploy with a predeterministic create2 address
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));

        // Assign the data for the pair to the state of the factory, so the pair can call {getInitializable}
        (_token0, _token1, _stable) = (token0, token1, stable);

        // Deploy the pair
        pair = address(new Pair{salt: salt}());

        // Populate the mapping both ways to access the data easier
        getPair[token0][token1][stable] = pair;
        getPair[token1][token0][stable] = pair;

        // Update the list of deployed pairs
        allPairs.push(pair);
        // Update the mapping so people know this pair address has been deployed.
        isPair[pair] = true;

        emit PairCreated(token0, token1, stable, pair, allPairs.length);
    }

    /**
     * @dev Allows the governor to update the treasury address. If the address is the zero address, no fee will be collected.
     *
     * @param _feeTo The new treasury address
     *
     * Requirements:
     *
     * - Only the {governor} can update this value.
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == governor, "Factory: Unauthorized");
        emit NewTreasury(feeTo, _feeTo);
        feeTo = _feeTo;
    }

    /**
     * @dev Allows the governor to update its address
     *
     * @param _governor The new governor address
     *
     * Requirements:
     *
     * - Only the governor can call this function
     * - The new governor cannot be the zero address.
     */
    function setGovernor(address _governor) external {
        require(
            msg.sender == governor && _governor != address(0),
            "Factory: Unauthorized"
        );
        emit NewGovernor(governor, _governor);
        governor = _governor;
    }
}
