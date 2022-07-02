// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./errors/PairErrors.sol";

import "./interfaces/IFactory.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IPairCallee.sol";

import "./lib/Math.sol";
import {Observation} from "./lib/DataTypes.sol";
import "./lib/Address.sol";

//solhint-disable var-name-mixedcase
//solhint-disable not-rely-on-time
contract Pair is IPair {
    /*//////////////////////////////////////////////////////////////
                              Libs
    //////////////////////////////////////////////////////////////*/

    using Address for address;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    string public name;
    string public symbol;
    //solhint-disable-next-line const-name-snakecase
    uint8 public constant decimals = 18;

    /*//////////////////////////////////////////////////////////////
                              ERC20 State
    //////////////////////////////////////////////////////////////*/

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                              EIP-2612 State
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant _TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    mapping(address => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                              Pair Metada
    //////////////////////////////////////////////////////////////*/

    address public immutable token0; // First token of the pair
    address public immutable token1; // Second token of the pair

    address private immutable factory; // Contract that deployed this pair

    // Save one unit of token0 and token1 respectively
    uint256 internal immutable decimals0;
    uint256 internal immutable decimals1;

    // Data about reserves of token0 and token1 respectively
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public blockTimestampLast;

    // Accumulate the reserves * timestamp to calculate a TWAP
    uint256 public reserve0CumulativeLast;
    uint256 public reserve1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    /*//////////////////////////////////////////////////////////////
                              Swap Storage
    //////////////////////////////////////////////////////////////*/

    // If true a pair follows the curve formula
    bool public immutable stable;
    uint256 private immutable swapFee; // Fee charged during swaps.
    // Minimum amount of tokens to avoid 0 divisions.
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    /*//////////////////////////////////////////////////////////////
                              TWAP storage
    //////////////////////////////////////////////////////////////*/

    // Settings for the TWAP
    uint256 private constant WINDOW = 15 minutes;
    uint256 private constant GRANULARITY = 5; // TWAP updates every 3 minutes
    uint256 private constant PERIOD_SIZE = 3 minutes;

    // Reserve observations for the TWAP
    Observation[] public observations;

    /*//////////////////////////////////////////////////////////////
                              Constructor
    //////////////////////////////////////////////////////////////*/
    constructor() {
        // Pair will be deployed by a factory
        factory = msg.sender;

        // Save init data to storage to save gas due to yul optimizer
        (token0, token1, stable) = IFactory(msg.sender).getInitializable();

        // Save gas
        uint256 fee;

        string memory token0Symbol = token0.safeSymbol();
        string memory token1Symbol = token1.safeSymbol();

        if (stable) {
            // e.g. Int Stable LP USDC/USDT
            name = string(
                abi.encodePacked(
                    "Int Stable LP - ",
                    token0Symbol,
                    "/",
                    token1Symbol
                )
            );
            fee = 0.0005e18;
            // e.g. vILP-USDC/USDT
            symbol = string(
                abi.encodePacked("sILP-", token0Symbol, "/", token1Symbol)
            );
        } else {
            // e.g. Int Stable LP USDC/USDT
            name = string(
                abi.encodePacked(
                    "Int Volatile LP - ",
                    token0Symbol,
                    "/",
                    token1Symbol
                )
            );

            fee = 0.003e18;

            // e.g. vILP-USDC/USDT
            symbol = string(
                abi.encodePacked("vILP-", token0Symbol, "/", token1Symbol)
            );
        }

        // Set the swap fee. 0.05% for stable swaps and 0.3% for volatile swaps
        swapFee = fee;

        unchecked {
            // Set decimals in terms of 1 unit
            decimals0 = 10**token0.safeDecimals();
            decimals1 = 10**token1.safeDecimals();
        }

        // Need to call {GRANULATIRY times}
        // populate the observations array with empty observations
        observations.push();
        observations.push();
        observations.push();
        observations.push();
        observations.push();

        _HASHED_NAME = keccak256(bytes(name));
        _HASHED_VERSION = keccak256(bytes("1"));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _computeDomainSeparator(
            _TYPE_HASH,
            _HASHED_NAME,
            _HASHED_VERSION
        );
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 Logic
    //////////////////////////////////////////////////////////////*/

    ///@notice Returns the DOMAIN_SEPARATOR
    //solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            block.chainid == _CACHED_CHAIN_ID
                ? _CACHED_DOMAIN_SEPARATOR
                : _computeDomainSeparator(
                    _TYPE_HASH,
                    _HASHED_NAME,
                    _HASHED_VERSION
                );
    }

    ///@notice Makes a new DOMAIN_SEPARATOR if the chainid changes.
    function _computeDomainSeparator(
        bytes32 typeHash,
        bytes32 nameHash,
        bytes32 versionHash
    ) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    typeHash,
                    nameHash,
                    versionHash,
                    block.chainid,
                    address(this)
                )
            );
    }

    // standard permit function
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        //solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert Pair__PermitExpired();
        unchecked {
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                            ),
                            owner,
                            spender,
                            value,
                            nonces[owner]++,
                            deadline
                        )
                    )
                )
            );

            address recoveredAddress = ecrecover(digest, v, r, s);

            if (recoveredAddress == address(0) || recoveredAddress != owner)
                revert Pair__InvalidSignature();

            allowance[owner][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev ERC20 standard approve.
     *
     * @param spender Address that will be allowed to spend in behalf o the `msg.sender`
     * @param amount The number of tokens the `spender` can spend from the `msg.sender`
     * @return bool true if successful
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @dev ERC20 standard transfer
     *
     * @param to The address that will receive the tokens
     * @param amount The number of tokens to send
     * @return bool true if successful
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    /**
     * @dev ERC20 standard transferFrom
     * @notice If the allowance is the max uint256, we consider an infinite allowance.
     *
     * @param from The address that will have his tokens spend
     * @param to The address that will receive the tokens
     * @param amount The number of tokens to send
     * @return bool true if successful
     *
     * Requirements:
     *
     * `msg.sender` must have enough allowance from the `from` address.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max)
            allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        Security Modifier
    //////////////////////////////////////////////////////////////*/

    // Basic nonreentrancy guard
    uint256 private _unlocked = 1;
    modifier lock() {
        if (_unlocked != 1) revert Pair__Reentrancy();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              TWAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the total number of observations stored in this pair. Note: that an earlier index observation does not mean it happened beforehand.
     * @return uint256 The number of observations
     */
    function observationLength() external view returns (uint256) {
        return observations.length;
    }

    /**
     * @dev returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
     *
     * @return firstObservation the first observation of the current epoch considering the TWAP is up to date.
     */
    function getFirstObservationInWindow()
        public
        view
        returns (Observation memory firstObservation)
    {
        unchecked {
            uint256 observationIndex = observationIndexOf(block.timestamp);
            // no overflow issue. if observationIndex + 1 overflows, result is still zero.
            uint256 firstObservationIndex = (observationIndex + 1) %
                GRANULARITY;
            firstObservation = observations[firstObservationIndex];
        }
    }

    /**
     * @dev A helper function to find the index of a timestamp
     *
     * @param timestamp The function returns in which index the data for this timestamp is saved on {pairObservations}.
     * @return index The index of the `timestamp` in {pairObservations}.
     */
    function observationIndexOf(uint256 timestamp)
        public
        pure
        returns (uint256)
    {
        // Split the total time by the period size to get a time slot.
        // If {WINDOW_SIZE} is 24 hours, {GRANULARITY} is 4 hours and {PERIOD_SIZE} is 6 hours.
        // E.g. In a `timestamp` of 72 hours, if we divide by a period size of 6 would give us 12.
        // 12 % 4 would give us index 0.
        unchecked {
            return (timestamp / PERIOD_SIZE) % GRANULARITY;
        }
    }

    /**
     * @dev Calculates the current cumulative reserves without updating the state to save gas.
     */
    function currentCumulativeReserves()
        public
        view
        returns (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,
            uint256 blockTimestamp
        )
    {
        // Save gas
        blockTimestamp = block.timestamp;
        reserve0Cumulative = reserve0CumulativeLast;
        reserve1Cumulative = reserve1CumulativeLast;

        // Get the last recorded reserves by the pair.
        // if time has elapsed since the last update on the pair, mock the accumulated price values

        uint256 _blockTimestampLast = blockTimestampLast;

        if (_blockTimestampLast != blockTimestamp) {
            // overflow is desired
            unchecked {
                uint256 timeElapsed = blockTimestamp - _blockTimestampLast;

                reserve0Cumulative += reserve0 * timeElapsed;
                reserve1Cumulative += reserve1 * timeElapsed;
            }
        }
    }

    /**
     * @dev Calculates a price in the opposite token of `tokenIn` by using a record of the cumulative reserves.
     *
     * @param tokenIn Caller should pass either token0 or token1 for proper caculation. We will return the price of the other token.
     * @param amountIn How many units of `tokenIn` we wish to trade for.
     * @return amountOut  the amount out corresponding to the amount in for a given token using the moving average over the time
     * range [now - [windowSize, windowSize - periodSize * 2], now]
     * update must have been called for the bucket corresponding to timestamp `now - windowSize`. Every 2 hours in the swap function.
     */
    function getTokenPrice(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        // Find the first observation in the 24 hour window.
        Observation memory firstObservation = getFirstObservationInWindow();

        // Find out how much time has passed since the last observation. Should be less than 24 hours or the price is stale.
        uint256 timeElapsed;

        unchecked {
            timeElapsed = block.timestamp - firstObservation.timestamp;
            // Only happens if the pair has low trading activity.
            if (timeElapsed > WINDOW) revert Pair__MissingObservation();

            // should never happen if the case above passes.
            assert(timeElapsed >= WINDOW - PERIOD_SIZE * 2);
        }
        // Get the current cumulative reserves.
        (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,

        ) = currentCumulativeReserves();

        // Calculate a time-weighted average reserve amounts based on an older observation and current
        uint256 _reserve0;

        uint256 _reserve1;

        unchecked {
            _reserve0 =
                (reserve0Cumulative - firstObservation.reserve0Cumulative) /
                timeElapsed;

            _reserve1 =
                (reserve1Cumulative - firstObservation.reserve1Cumulative) /
                timeElapsed;
        }

        // Calculate he price in the opposite token
        amountOut = _computeAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

    /**
     * @dev Returns both tokens sorted
     */
    function tokens() external view returns (address, address) {
        return (token0, token1);
    }

    /*//////////////////////////////////////////////////////////////
                            Pair View
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns relevant metadata of this pair.
     */
    function metadata()
        external
        view
        returns (
            address t0,
            address t1,
            bool st,
            uint256 fee,
            uint256 r0,
            uint256 r1,
            uint256 dec0,
            uint256 dec1
        )
    {
        return (
            token0,
            token1,
            stable,
            swapFee,
            reserve0,
            reserve1,
            decimals0,
            decimals1
        );
    }

    /*//////////////////////////////////////////////////////////////
                            DEX Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev It returns the last record of the reserves held by this pair.
     */
    function getReserves()
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /*//////////////////////////////////////////////////////////////
                            DEX Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev this low-level function should be called from a contract which performs important safety checks
     *
     * @notice  standard uniswap v2 implementation
     *
     * @param to The user who will receive the LP tokens for this pair representing the liquidity just added.
     * @return liquidity Amount of LP tokens minted
     *
     * Requirements:
     *
     * - Nonreentrant guard
     * - Assumes the user has sent enough tokens beforehand.
     */
    function mint(address to) external lock returns (uint256 liquidity) {
        // Save current to {_sync} after changes
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);

        // Get current balance in the contract.
        uint256 _balance0 = token0.currentBalance();
        uint256 _balance1 = token1.currentBalance();

        // Difference between current balance and reserves is the new liquidity added in token0 and token1.
        uint256 _amount0 = _balance0 - _reserve0;
        uint256 _amount1 = _balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        // gas savings
        uint256 _totalSupply = totalSupply;

        // If it is the first time liquidity has been added to the pair. We need to have a minimum liquidity to avoid 0 divisions.
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(_amount0 * _amount1) - MINIMUM_LIQUIDITY;
            // Burn the minimum liquidity
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // If there is current liquidity already, mint tokens based on current reserves and supply
            liquidity = Math.min(
                (_amount0 * _totalSupply) / _reserve0,
                (_amount1 * _totalSupply) / _reserve1
            );
        }

        // Must provide enough liquidity
        if (liquidity == 0) revert Pair__NoLiquidity();

        // Send the LP tokens
        _mint(to, liquidity);

        // Update the observations and current reserves value.
        _sync(_balance0, _balance1, _reserve0, _reserve1);
        if (feeOn) kLast = _k(reserve0, reserve1);
        emit Mint(msg.sender, _amount0, _amount1);
    }

    /**
     * @dev  this low-level function should be called from a contract which performs important safety checks
     * standard uniswap v2 implementation
     *
     * @param to Address that will receive the token0 and token1.
     * @return amount0 amount1 The number of token0 and token1 removed
     */
    function burn(address to)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        // Save current reserves in memory to save gas
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        // Save current tokens in memory
        (address _token0, address _token1) = (token0, token1);

        // Get the current balance of token0 and token1 to know how much to send
        uint256 _balance0 = _token0.currentBalance();
        uint256 _balance1 = _token1.currentBalance();

        // Find out how many tokens the user wishes to remove
        uint256 tokensToBurn = balanceOf[address(this)];

        // Save gas
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply;
        // Calculate how much liquidity to be removed
        amount0 = (tokensToBurn * _balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (tokensToBurn * _balance1) / _totalSupply; // using balances ensures pro-rata distribution

        if (amount0 == 0 && amount1 == 0) revert Pair__NoTokensToBurn();

        // Burn the tokens sent without updating the fees as pair keeps no fees.
        _burn(address(this), tokensToBurn);

        // Send the tokens
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);

        _balance0 = _token0.currentBalance();
        _balance1 = _token1.currentBalance();

        // Update the observations and reserves.
        _sync(_balance0, _balance1, _reserve0, _reserve1);
        if (feeOn) kLast = _k(reserve0, reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @dev this low-level function should be called from a contract which performs important safety checks
     * It assumes the user has sent enough tokens to swap.
     * Can also be used to get a flash loan by passing the data field
     *
     * @param amount0Out How many token0 the caller wishes to get
     * @param amount1Out How many token1 the caller wishes to get
     * @param to The recipient of the token
     * @param data Can be used to get a flash loan
     *
     * Requirements:
     *
     * - Non Reentrant guard.
     * - User must have sent token before hand and declare how many of the other tokens he wishes
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert Pair__NoZeroTrades();

        // Save current reserves in memory
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);

        // Cannot wish to buy more than the current reserves
        if (amount0Out > _reserve0 || amount1Out > _reserve1)
            revert Pair__NoLiquidity();

        uint256 _balance0;
        uint256 _balance1;
        {
            // Saves tokens in memory to save gas
            (address _token0, address _token1) = (token0, token1);
            // Make sure the to is not one of the tokens
            if (to == _token0 || _token1 == to) revert Pair__InvalidReceiver();

            if (amount0Out > 0) _token0.safeTransfer(to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _token1.safeTransfer(to, amount1Out); // optimistically transfer tokens
            // In case of a flash loan, we pass the the information about this
            if (data.length > 0)
                IPairCallee(to).hook(msg.sender, amount0Out, amount1Out, data); // callback, used for flash loans

            // Record the balance after sending the tokens out.
            _balance0 = _token0.currentBalance();
            _balance1 = _token1.currentBalance();
        }

        // Find out how many tokens was send to the pair
        uint256 amount0In = _balance0 > _reserve0 - amount0Out
            ? _balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = _balance1 > _reserve1 - amount1Out
            ? _balance1 - (_reserve1 - amount1Out)
            : 0;

        // Throw if no tokens were sent
        if (amount0In == 0 && amount1In == 0)
            revert Pair__InsufficientAmountIn();

        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            (address _token0, address _token1) = (token0, token1);

            // Get current balances of the tokens of this pair.
            _balance0 = _token0.currentBalance(); // since we removed tokens, we need to reconfirm balances, can also simply use previous balance - amountIn/ 10000, but doing balanceOf again as safety check
            _balance1 = _token1.currentBalance();
            // The curve, either x3y+y3x for stable pools, or x*y for volatile pools

            // Value in the pool must be greater or equal after the swap.
            if (
                _k(_reserve0, _reserve1) >
                _k(
                    _balance0 - amount0In.fmul(swapFee),
                    _balance1 - amount1In.fmul(swapFee)
                )
            ) revert Pair__K();
        }
        // Update the observations and the reserves.
        _sync(_balance0, _balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @dev Forces the reserves and balances to match. Can be used to rescue tokens.
     *
     * @param to The address that will get the outstanding tokens.
     *
     * Requirements:
     *
     * Non-reentrant
     */
    function skim(address to) external lock {
        token0.safeTransfer(to, token0.currentBalance() - reserve0);
        token1.safeTransfer(to, token1.currentBalance() - reserve1);
    }

    /**
     * @dev Updates the current reserves to match the balances
     *
     * Requirements:
     *
     * Non-reentrant
     */
    function sync() external lock {
        _sync(
            token0.currentBalance(),
            token1.currentBalance(),
            reserve0,
            reserve1
        );
    }

    /**
     * @dev Calculate how many tokens a swap will return
     *
     * @param tokenIn The token to be swaped for the other
     * @param amountIn Number of tokens used to buy the other token
     * @return uint256 The number of tokens received after the swap
     */
    function getAmountOut(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        unchecked {
            // Remove the fee
            amountIn -= amountIn.fmul(swapFee); // remove fee from amount received
        }
        return _computeAmountOut(amountIn, tokenIn, reserve0, reserve1);
    }

    // From uniswap
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint256 _reserve0, uint256 _reserve1)
        private
        returns (bool feeOn)
    {
        address feeTo = IFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast > 0) {
                uint256 rootK = Math.sqrt(_k(_reserve0, _reserve1));
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = (rootK * 5) + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast > 0) {
            kLast = 0;
        }
    }

    /**
     * @dev Update the observations, the reserve cumulatives and reserves.
     *
     * @param balance0 current balance of token0
     * @param balance1 current balance of token1
     * @param _reserve0 previous reserve for token0
     * @param _reserve1 previous reserve for token1
     *
     */
    function _sync(
        uint256 balance0,
        uint256 balance1,
        uint256 _reserve0,
        uint256 _reserve1
    ) private {
        // Save gas current timesamp
        uint256 currentTimeStamp = block.timestamp;
        // Time since last _sync call
        uint256 timeElapsed = currentTimeStamp - blockTimestampLast;

        // If time has passed and there are reserves, we update the reserve cumulatives
        if (timeElapsed != 0 && _reserve0 != 0 && _reserve1 != 0) {
            // Overflow is desired
            unchecked {
                reserve0CumulativeLast += _reserve0 * timeElapsed;
                reserve1CumulativeLast += _reserve1 * timeElapsed;
            }
        }

        // Get the index for the observation for this time slot.
        //solhint-disable-next-line not-rely-on-time
        uint256 index = observationIndexOf(block.timestamp);

        // Get the old observation saved in the current timeslot. Note the storage
        Observation storage observation = observations[index];

        unchecked {
            // How much time has passed from the old observation
            //solhint-disable-next-line not-rely-on-time
            timeElapsed = currentTimeStamp - observation.timestamp;
        }

        // If more time has passed since the last update, we need to update the observation.
        if (timeElapsed > PERIOD_SIZE) {
            // update the observation
            observation.timestamp = currentTimeStamp;
            observation.reserve0Cumulative = reserve0CumulativeLast;
            observation.reserve1Cumulative = reserve1CumulativeLast;
        }

        // Update the reserves.
        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = currentTimeStamp;
        emit Sync(reserve0, reserve1);
    }

    /*//////////////////////////////////////////////////////////////
                        Mint/Burn Private Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice It mints an `amount` of tokens to the `to` address.
     *
     * @param to The address that will receive new tokens
     * @param amount The number of tokens to mint
     */
    function _mint(address to, uint256 amount) private {
        totalSupply += amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice It burns an `amount` of tokens from the `from` address.
     *
     * @param from The address that will get its tokens burned
     * @param amount The number of tokens to burn
     */
    function _burn(address from, uint256 amount) private {
        balanceOf[from] -= amount;

        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    /*//////////////////////////////////////////////////////////////
                            K Invariant LOGIC
    //////////////////////////////////////////////////////////////*/

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _k(uint256 x, uint256 y) private view returns (uint256) {
        if (!stable) return x * y; // xy >= k

        uint256 _x = (x * 1e18) / decimals0;
        uint256 _y = (y * 1e18) / decimals1;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
        return (_a * _b) / 1e18; // x3y+y3x >= k
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _f(uint256 x0, uint256 y) private pure returns (uint256) {
        return
            (x0 * ((((y * y) / 1e18) * y) / 1e18)) /
            1e18 +
            (((((x0 * x0) / 1e18) * x0) / 1e18) * y) /
            1e18;
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _d(uint256 x0, uint256 y) private pure returns (uint256) {
        return
            (3 * x0 * ((y * y) / 1e18)) /
            1e18 +
            ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _getY(
        uint256 x0,
        uint256 xy,
        uint256 y
    ) private pure returns (uint256) {
        for (uint256 i = 0; i < 255; i = _uncheckedInc(i)) {
            uint256 yPrev = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > yPrev) {
                if (y - yPrev <= 1) {
                    return y;
                }
            } else {
                if (yPrev - y <= 1) {
                    return y;
                }
            }
        }
        return y;
    }

    /**
     * @dev https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
     *
     * @param amountIn The number of `tokenIn` being sold
     * @param tokenIn The token being sold
     * @param _reserve0 current reserves of token0
     * @param _reserve1 current reserves of token1
     * @return uint256 How many tokens of the other tokens were bought
     */
    function _computeAmountOut(
        uint256 amountIn,
        address tokenIn,
        uint256 _reserve0,
        uint256 _reserve1
    ) private view returns (uint256) {
        if (stable) {
            uint256 xy = _k(_reserve0, _reserve1);
            _reserve0 = (_reserve0 * 1e18) / decimals0;
            _reserve1 = (_reserve1 * 1e18) / decimals1;
            (uint256 reserveA, uint256 reserveB) = tokenIn == token0
                ? (_reserve0, _reserve1)
                : (_reserve1, _reserve0);
            amountIn = tokenIn == token0
                ? (amountIn * 1e18) / decimals0
                : (amountIn * 1e18) / decimals1;
            uint256 y = reserveB - _getY(amountIn + reserveA, xy, reserveB);
            return (y * (tokenIn == token0 ? decimals1 : decimals0)) / 1e18;
        } else {
            (uint256 reserveA, uint256 reserveB) = tokenIn == token0
                ? (_reserve0, _reserve1)
                : (_reserve1, _reserve0);
            return (amountIn * reserveB) / (reserveA + amountIn);
        }
    }

    /**
     *@notice Helper to optimize gas to increment a number
     */
    function _uncheckedInc(uint256 i) private pure returns (uint256 y) {
        //solhint-disable-next-line no-inline-assembly
        assembly {
            y := add(i, 1)
        }
    }
}
