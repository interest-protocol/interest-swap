// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./interfaces/IERC20.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IPairCallee.sol";

import "./lib/Math.sol";
import "./lib/Address.sol";

import "./Fees.sol";
import "hardhat/console.sol";

struct Observation {
    uint256 timestamp;
    uint256 reserve0Cumulative;
    uint256 reserve1Cumulative;
}

//solhint-disable not-rely-on-time
//solhint-disable-next-line max-states-count
contract Pair is IERC20 {
    using Address for address;
    using Math for uint256;

    event UpdatedFee(address indexed sender, uint256 amount0, uint256 amount1);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint256 reserve0, uint256 reserve1);
    event Claim(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );

    // ERC20 Metadata
    string public name;
    string public symbol;

    // If true a pair follows the curve formula
    bool public immutable stable;

    // ERC20 Interface
    uint256 public totalSupply;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public balanceOf;

    // Permit Function
    //solhint-disable-next-line var-name-mixedcase
    bytes32 private DOMAIN_SEPARATOR;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
    mapping(address => uint256) public nonces;

    // Minimum amount of tokens to avoid 0 divisions.
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    address public immutable token0; // First token of the pair
    address public immutable token1; // Second token of the pair
    address public immutable feesContract; // Holds the fees collected by this pair
    address private immutable factory; // Contract that deployed this pair

    uint256 private immutable swapFee; // Fee charged during swapping.

    // Settings for the TWAP
    uint256 private constant WINDOW = 86400; // 24 hours
    uint256 private constant GRANULARITY = 12; // TWAP updates every 2 hour
    uint256 private constant PERIOD_SIZE = WINDOW / GRANULARITY;

    // Reserve observations for the TWAP
    Observation[] public observations;

    // Save one unit of token0 and token1 respectively
    uint256 private immutable decimals0;
    uint256 private immutable decimals1;

    // Data about reserves of token0 and token1 respectively
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public blockTimestampLast;

    // Accumulate the reserves * timestamp to calculate a TWAP
    uint256 public reserve0CumulativeLast;
    uint256 public reserve1CumulativeLast;

    // Current total fees collected by this pair for token0 and token1 respectively
    uint256 public index0;
    uint256 public index1;

    // How many fees a user has been paid already for token0 and token1 respectively
    mapping(address => uint256) public supplyIndex0;
    mapping(address => uint256) public supplyIndex1;

    // How many fees a user can collect
    mapping(address => uint256) public claimable0;
    mapping(address => uint256) public claimable1;

    constructor() {
        // Pair will be deployed by a factory
        factory = msg.sender;

        // Save init data in memory to save gas
        (address _token0, address _token1, bool _stable) = IFactory(msg.sender)
            .getInitializable();

        // Update the global state
        (token0, token1, stable) = (_token0, _token1, _stable);

        // Deploy the feesContract
        feesContract = address(new Fees(_token0, _token1));

        // Set the swap fee. 0.05% for stable swaps and 0.3% for volatile swaps
        swapFee = _stable ? 0.0005e18 : 0.003e18;

        string memory _name = string(
            abi.encodePacked(
                _stable ? "Int Stable LP - " : "Int Volatile LP - ",
                _token0.safeSymbol(),
                "/",
                _token1.safeSymbol()
            )
        );

        // Set the name and symbol of the LP token
        name = _name;

        symbol = string(
            abi.encodePacked(
                _stable ? "sILP-" : "vILP-",
                _token0.safeSymbol(),
                "/",
                _token1.safeSymbol()
            )
        );

        // Set decimals in terms of 1 unit
        decimals0 = 10**_token0.safeDecimals();
        decimals1 = 10**_token1.safeDecimals();

        // populate the array with empty observations
        for (uint256 i = observations.length; i < GRANULARITY; i++) {
            observations.push();
        }

        // set up the domain_separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(_name)),
                keccak256("v1"),
                block.chainid,
                address(this)
            )
        );
    }

    // Basic nonreentrancy guard
    uint256 private _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1, "Pair: Reentrancy");
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

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
        uint256 observationIndex = observationIndexOf(block.timestamp);
        // no overflow issue. if observationIndex + 1 overflows, result is still zero.
        uint256 firstObservationIndex = (observationIndex + 1) % GRANULARITY;
        firstObservation = observations[firstObservationIndex];
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
        returns (uint256 index)
    {
        // Split the total time by the period size to get a time slot.
        // If {WINDOW_SIZE} is 24 hours, {GRANULARITY} is 4 hours and {PERIOD_SIZE} is 6 hours.
        // E.g. In a `timestamp` of 72 hours, if we divide by a period size of 6 would give us 12.
        // 12 % 4 would give us index 0.
        return (timestamp / PERIOD_SIZE) % GRANULARITY;
    }

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

    /**
     * @dev Collect the fees earned by a LP provider.
     */
    function claimFees() external {
        // Update fees calculations before sending.
        _updateFeesFor(msg.sender);

        uint256 claimed0 = claimable0[msg.sender];
        uint256 claimed1 = claimable1[msg.sender];

        // Only send if there are any fees to be collected
        if (claimed0 > 0 || claimed1 > 0) {
            // Consider the fees paid
            claimable0[msg.sender] = 0;
            claimable1[msg.sender] = 0;

            // Send the fees to the `msg.sender`.
            Fees(feesContract).claimFor(msg.sender, claimed0, claimed1);

            emit Claim(msg.sender, msg.sender, claimed0, claimed1);
        }
    }

    /**
     * @dev Returns both tokens sorted
     */
    function tokens() external view returns (address, address) {
        return (token0, token1);
    }

    /**
     * @dev It returns the last record of the reserves held by this pair.
     */
    function getReserves()
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /**
     * @dev ERC20 standard decimals.
     */
    function decimals() external pure returns (uint8) {
        return 18;
    }

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
        // Abstract the logic to {_transfer} to avoid duplicating code.
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @dev ERC20 standard transferFrom
     * Note If the allowance is the max uint256, we consider an infinite allowance.
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
        address spender = msg.sender;
        uint256 spenderAllowance = allowance[from][spender];

        // If the spender is the owner of the account, he behaves like the {transfer} function
        // We consider the max uint256 infinite allowanc
        if (spender != from && spenderAllowance != type(uint256).max) {
            uint256 newAllowance = spenderAllowance - amount;
            allowance[from][spender] = newAllowance;

            emit Approval(from, spender, newAllowance);
        }

        _transfer(from, to, amount);
        return true;
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
        (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        ) = getReserves();

        if (_blockTimestampLast != blockTimestamp) {
            uint256 timeElapsed = blockTimestamp - _blockTimestampLast;
            // overflow is desired
            unchecked {
                reserve0Cumulative += _reserve0 * timeElapsed;
                reserve1Cumulative += _reserve1 * timeElapsed;
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
        uint256 timeElapsed = block.timestamp - firstObservation.timestamp;

        // Only happens if the pair has low trading activity.
        require(timeElapsed <= WINDOW, "Pair: Missing observation");

        // should never happen if the case above passes.
        assert(timeElapsed >= WINDOW - PERIOD_SIZE * 2);

        // Get the current cumulative reserves.
        (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,

        ) = currentCumulativeReserves();

        // Calculate a time-weighted average reserve amounts based on an older observation and current
        uint256 _reserve0 = (reserve0Cumulative -
            firstObservation.reserve0Cumulative) / timeElapsed;

        uint256 _reserve1 = (reserve1Cumulative -
            firstObservation.reserve1Cumulative) / timeElapsed;

        // Calculate he price in the opposite token
        amountOut = _computeAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

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
        // Save current reserves in memory to save gas
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);

        // Get current balance in the contract.
        uint256 _balance0 = token0.currentBalance();
        uint256 _balance1 = token1.currentBalance();

        // Difference between current balance and reserves is the new liquidity added in token0 and token1.
        uint256 _amount0 = _balance0 - _reserve0;
        uint256 _amount1 = _balance1 - _reserve1;

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
        require(liquidity > 0, "Pair: low liquidity");
        // Send the LP tokens
        _mint(to, liquidity);

        // Update the observations and current reserves value.
        _sync(_balance0, _balance1, _reserve0, _reserve1);
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
        uint256 _liquidity = balanceOf[address(this)];

        // Save gas
        uint256 _totalSupply = totalSupply;
        // Calculate how much liquidity to be removed
        amount0 = (_liquidity * _balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (_liquidity * _balance1) / _totalSupply; // using balances ensures pro-rata distribution

        // There must have been tokens sent to this contract to remove liquidity
        require(amount0 > 0 && amount1 > 0, "Pair: not enough liquidity");

        // Burn the tokens sent without updating the fees as pair keeps no fees.
        _burn(address(this), _liquidity);

        // Send the tokens
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);

        _balance0 = _token0.currentBalance();
        _balance1 = _token1.currentBalance();

        // Update the observations and reserves.
        _sync(_balance0, _balance1, _reserve0, _reserve1);
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
        require(amount0Out > 0 || amount1Out > 0, "Pair: No zero amount");

        // Save current reserves in memory
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);

        // Cannot wish to buy more than the current reserves
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "Pair: not enough  liquidity"
        );

        uint256 _balance0;
        uint256 _balance1;
        {
            // Saves tokens in memory to save gas
            (address _token0, address _token1) = (token0, token1);
            // Make sure the to is not one of the tokens
            require(to != _token0 && to != _token1, "Pair: invalid to");

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
        require(amount0In > 0 || amount1In > 0, "Pair: insufficient amount in");
        {
            // Save feeTo address in memory to save gas
            address feeTo = IFactory(factory).feeTo();

            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            (address _token0, address _token1) = (token0, token1);

            // If feeTo is the address zero, the protocol takes no fees.
            if (feeTo == address(0)) {
                // We only charge the sender not the recipient
                if (amount0In > 0) _collectToken0Fees(amount0In.bmul(swapFee)); // accrue fees for token0 and move them out of pool
                if (amount1In > 0) _collectToken1Fees(amount1In.bmul(swapFee)); // accrue fees for token1 and move them out of pool
            } else {
                if (amount0In > 0) {
                    uint256 fee = amount0In.bmul(swapFee);
                    uint256 governorFee = fee.bmul(0.15e18);
                    _collectToken0Fees(fee - governorFee); // accrue fees for token0 and move them out of pool
                    token0.safeTransfer(feeTo, governorFee); // Send the fee to the governor
                }
                if (amount1In > 0) {
                    uint256 fee = amount1In.bmul(swapFee);
                    uint256 governorFee = fee.bmul(0.15e18);
                    _collectToken1Fees(fee - governorFee); // accrue fees for token1 and move them out of pool
                    token1.safeTransfer(feeTo, governorFee);
                }
            }

            // Get current balances of the tokens of this pair.
            _balance0 = _token0.currentBalance(); // since we removed tokens, we need to reconfirm balances, can also simply use previous balance - amountIn/ 10000, but doing balanceOf again as safety check
            _balance1 = _token1.currentBalance();
            // The curve, either x3y+y3x for stable pools, or x*y for volatile pools

            // Value in the pool must be greater or equal after the swap.
            require(
                _k(_balance0, _balance1) >= _k(_reserve0, _reserve1),
                "Pair: K error"
            );
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
        (address _token0, address _token1) = (token0, token1);
        _token0.safeTransfer(to, _token0.currentBalance() - reserve0);
        _token1.safeTransfer(to, _token1.currentBalance() - reserve1);
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
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        // Remove the fee
        amountIn -= amountIn.bmul(swapFee); // remove fee from amount received
        return _computeAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
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
        require(deadline >= block.timestamp, "Pair: Expired");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
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

        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "Pair: invalid signature"
        );

        allowance[owner][spender] = value;

        emit Approval(owner, spender, value);
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _f(uint256 x0, uint256 y) private pure returns (uint256) {
        return
            (x0 * ((((y * y) / 1e18) * y) / 1e18)) /
            1e18 +
            (((((x0 * x0) / 1e18) * x0) / 1e18) * y) /
            1e18;
    }

    // Token from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
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
        for (uint256 i = 0; i < 255; i++) {
            uint256 prevY = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > prevY) {
                if (y - prevY <= 1) {
                    return y;
                }
            } else {
                if (prevY - y <= 1) {
                    return y;
                }
            }
        }
        return y;
    }

    // Taken from https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
    function _k(uint256 x, uint256 y) private view returns (uint256) {
        if (stable) {
            uint256 _x = (x * 1e18) / decimals0;
            uint256 _y = (y * 1e18) / decimals1;
            uint256 _a = (_x * _y) / 1e18;
            uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
            return (_a * _b) / 1e18; // x3y+y3x >= k
        } else {
            return x * y; // xy >= k
        }
    }

    /**
     * @dev Mints the tokens to a recipient
     *
     * @param recipient The address that will receive the tokens
     * @param amount The number of tokens to mint.
     */
    function _mint(address recipient, uint256 amount) private {
        // First update his current rewards
        _updateFeesFor(recipient);
        totalSupply += amount;
        balanceOf[recipient] += amount;
        emit Transfer(address(0), recipient, amount);
    }

    /**
     * @dev Burns the tokens of an address. It is always the address of this contract.
     *
     * @param recipient The address that will have its tokens burned.
     * @param amount The number of tokens to burn.
     */
    function _burn(address recipient, uint256 amount) private {
        // First update the current rewards. Sanity check
        _updateFeesFor(recipient);
        totalSupply -= amount;
        balanceOf[recipient] -= amount;
        emit Transfer(recipient, address(0), amount);
    }

    /**
     * @dev https://github.com/solidlyexchange/solidly/blob/master/contracts/BaseV1-core.sol
     *
     * @param amountIn The number of `tokenIn` being sold
     * @param tokenIn The token being sold
     * @param _reserve0 current reserves of token0
     * @param _reserve1 current reserves of token1
     * @return amountOut How many tokens of the other tokens were bought
     */
    function _computeAmountOut(
        uint256 amountIn,
        address tokenIn,
        uint256 _reserve0,
        uint256 _reserve1
    ) private view returns (uint256 amountOut) {
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
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
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

        // How much time has passed from the old observation
        //solhint-disable-next-line not-rely-on-time
        timeElapsed = currentTimeStamp - observation.timestamp;
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

    /**
     * @dev Send fees to the feesContract and update the total fees accrued by this contract per token.
     *
     * @param amount The amount of fees to send for token0.
     */
    function _collectToken0Fees(uint256 amount) private {
        token0.safeTransfer(feesContract, amount);
        uint256 _ratio = amount.bdiv(totalSupply);
        if (_ratio > 0) {
            index0 += _ratio;
        }
        emit UpdatedFee(msg.sender, amount, 0);
    }

    /**
     * @dev Send fees to the feesContract and update the total fees accrued by this contract per token.
     *
     * @param amount The amount of fees to send for token1.
     */
    function _collectToken1Fees(uint256 amount) private {
        token1.safeTransfer(feesContract, amount);
        uint256 _ratio = amount.bdiv(totalSupply);
        if (_ratio > 0) {
            index1 += _ratio;
        }
        emit UpdatedFee(msg.sender, 0, amount);
    }

    /**
     * @dev this function MUST be called on any balance changes, otherwise can be used to infinitely claim fees
     *
     * @notice Fees are segregated from core funds, so fees can never put liquidity at risk
     *
     * @param recipient The address that will have his fee rewards updated.
     */
    function _updateFeesFor(address recipient) private {
        // get LP balance of `recipient`
        uint256 _supplied = balanceOf[recipient];
        if (_supplied > 0) {
            // get last adjusted index0 and index1 for recipient. how much he has been paid already.
            uint256 _supplyIndex0 = supplyIndex0[recipient];
            uint256 _supplyIndex1 = supplyIndex1[recipient];

            // Save in memory how much each token should be paid.
            uint256 _index0 = index0;
            uint256 _index1 = index1;

            // Consider the user fully paid
            supplyIndex0[recipient] = _index0;
            supplyIndex1[recipient] = _index1;

            // Check if the user has been fully paid already.
            uint256 _delta0 = _index0 - _supplyIndex0;
            uint256 _delta1 = _index1 - _supplyIndex1;

            // If he is not fully paid. Check how he is owed.
            if (_delta0 > 0) {
                // He is owed a % of the difference between the current rewards and his last paid rewards based on supply.
                uint256 _share = _supplied.bmul(_delta0);
                claimable0[recipient] += _share;
            }
            if (_delta1 > 0) {
                uint256 _share = _supplied.bmul(_delta1);
                claimable1[recipient] += _share;
            }
        } else {
            // New users are considered fully paid.
            supplyIndex0[recipient] = index0;
            supplyIndex1[recipient] = index1;
        }
    }

    /**
     * @dev Logic of the ERC20 transfer with a call to update the rewards of `from` and `to`.
     *
     * @param from The address sending the tokens
     * @param to The address receiving the tokens
     * @param amount The number of tokens being sent.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        // Update the rewards
        _updateFeesFor(from);
        _updateFeesFor(to);

        // Update the balances.
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
    }
}
