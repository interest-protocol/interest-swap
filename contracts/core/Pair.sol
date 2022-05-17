// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../interfaces/IERC20.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IPairCallee.sol";
import "../lib/Math.sol";

import "./Fees.sol";

struct Observation {
    uint256 timestamp;
    uint256 reserve0Cumulative;
    uint256 reserve1Cumulative;
}

//solhint-disable not-rely-on-time
//solhint-disable-next-line max-states-count
contract Pair is IERC20 {
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

    string public name;
    string public symbol;
    bool public immutable stable;

    uint256 public totalSupply;

    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public balanceOf;

    //solhint-disable-next-line var-name-mixedcase
    bytes32 private DOMAIN_SEPARATOR;
    bytes32 private constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint256) public nonces;

    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    address public immutable token0;
    address public immutable token1;
    address public immutable feesContract;
    address private immutable factory;

    uint256 private immutable swapFee;

    uint256 private constant WINDOW = 86400; // 24 hours
    uint256 private constant GRANULARITY = 24; // TWAP updates every hour
    uint256 private constant PERIOD_SIZE = WINDOW / GRANULARITY;

    Observation[] public observations;

    uint256 internal immutable decimals0;
    uint256 internal immutable decimals1;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public blockTimestampLast;

    uint256 public reserve0CumulativeLast;
    uint256 public reserve1CumulativeLast;

    uint256 public index0;
    uint256 public index1;

    mapping(address => uint256) public supplyIndex0;
    mapping(address => uint256) public supplyIndex1;

    mapping(address => uint256) public claimable0;
    mapping(address => uint256) public claimable1;

    constructor() {
        factory = msg.sender;
        (address _token0, address _token1, bool _stable) = IFactory(msg.sender)
            .getInitializable();
        (token0, token1, stable) = (_token0, _token1, _stable);
        feesContract = address(new Fees(_token0, _token1));
        swapFee = _stable ? 0.0005e18 : 0.003e18;
        if (_stable) {
            name = string(
                abi.encodePacked(
                    "Int Stable LP - ",
                    IERC20(_token0).symbol(),
                    "/",
                    IERC20(_token1).symbol()
                )
            );
            symbol = string(
                abi.encodePacked(
                    "sLP-",
                    IERC20(_token0).symbol(),
                    "/",
                    IERC20(_token1).symbol()
                )
            );
        } else {
            name = string(
                abi.encodePacked(
                    "Int Volatile LP - ",
                    IERC20(_token0).symbol(),
                    "/",
                    IERC20(_token1).symbol()
                )
            );
            symbol = string(
                abi.encodePacked(
                    "vLP-",
                    IERC20(_token0).symbol(),
                    "/",
                    IERC20(_token1).symbol()
                )
            );
        }

        decimals0 = 10**IERC20(_token0).decimals();
        decimals1 = 10**IERC20(_token1).decimals();

        // populate the array with empty observations (first call only)
        for (uint256 i = observations.length; i < GRANULARITY; i++) {
            observations.push();
        }
    }

    uint256 private _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1, "Pair: Reentrancy");
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function observationLength() external view returns (uint256) {
        return observations.length;
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

    function metadata()
        external
        view
        returns (
            uint256 dec0,
            uint256 dec1,
            uint256 r0,
            uint256 r1,
            bool st,
            address t0,
            address t1
        )
    {
        return (
            decimals0,
            decimals1,
            reserve0,
            reserve1,
            stable,
            token0,
            token1
        );
    }

    // claim accumulated but unclaimed fees (viewable via claimable0 and claimable1)
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        _updateFeesFor(msg.sender);

        claimed0 = claimable0[msg.sender];
        claimed1 = claimable1[msg.sender];

        if (claimed0 > 0 || claimed1 > 0) {
            claimable0[msg.sender] = 0;
            claimable1[msg.sender] = 0;

            Fees(feesContract).claimFor(msg.sender, claimed0, claimed1);

            emit Claim(msg.sender, msg.sender, claimed0, claimed1);
        }
    }

    function tokens() external view returns (address, address) {
        return (token0, token1);
    }

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

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address dst, uint256 amount) external returns (bool) {
        _transferTokens(msg.sender, dst, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        address spender = msg.sender;
        uint256 spenderAllowance = allowance[from][spender];

        if (spender != from && spenderAllowance != type(uint256).max) {
            uint256 newAllowance = spenderAllowance - amount;
            allowance[from][spender] = newAllowance;

            emit Approval(from, spender, newAllowance);
        }

        _transferTokens(from, to, amount);
        return true;
    }

    // produces the cumulative reserves using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativeReserves()
        public
        view
        returns (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,
            uint256 blockTimestamp
        )
    {
        blockTimestamp = block.timestamp;
        reserve0Cumulative = reserve0CumulativeLast;
        reserve1Cumulative = reserve1CumulativeLast;

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        ) = getReserves();

        if (_blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint256 timeElapsed = blockTimestamp - _blockTimestampLast;
            reserve0Cumulative += _reserve0 * timeElapsed;
            reserve1Cumulative += _reserve1 * timeElapsed;
        }
    }

    // returns the amount out corresponding to the amount in for a given token using the moving average over the time
    // range [now - [windowSize, windowSize - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowSize`
    function getTokenPrice(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        Observation memory firstObservation = _getFirstObservationInWindow();

        uint256 timeElapsed = block.timestamp - firstObservation.timestamp;

        require(timeElapsed <= WINDOW, "Pair: Missing observation");
        // should never happen.
        require(
            timeElapsed >= WINDOW - PERIOD_SIZE * 2,
            "Pair: Wrong time elased"
        );

        (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,

        ) = currentCumulativeReserves();

        uint256 _reserve0 = (reserve0Cumulative -
            firstObservation.reserve0Cumulative) / timeElapsed;
        uint256 _reserve1 = (reserve1Cumulative -
            firstObservation.reserve1Cumulative) / timeElapsed;

        amountOut = _computeAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // standard uniswap v2 implementation
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        uint256 _balance0 = IERC20(token0).balanceOf(address(this));
        uint256 _balance1 = IERC20(token1).balanceOf(address(this));
        uint256 _amount0 = _balance0 - _reserve0;
        uint256 _amount1 = _balance1 - _reserve1;

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(_amount0 * _amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(
                (_amount0 * _totalSupply) / _reserve0,
                (_amount1 * _totalSupply) / _reserve1
            );
        }
        require(liquidity > 0, "Pair: low liquidity");
        _mint(to, liquidity);

        _sync(_balance0, _balance1, _reserve0, _reserve1);
        emit Mint(msg.sender, _amount0, _amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // standard uniswap v2 implementation
    function burn(address to)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        (address _token0, address _token1) = (token0, token1);

        uint256 _balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 _balance1 = IERC20(_token1).balanceOf(address(this));

        uint256 _liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = (_liquidity * _balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (_liquidity * _balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "Pair: not enough liquidity");
        _burn(address(this), _liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        _balance0 = IERC20(_token0).balanceOf(address(this));
        _balance1 = IERC20(_token1).balanceOf(address(this));

        _sync(_balance0, _balance1, _reserve0, _reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        require(amount0Out > 0 || amount1Out > 0, "Pair: wrong amount");
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);

        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "Pair: not enough  liquidity"
        );

        uint256 _balance0;
        uint256 _balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            (address _token0, address _token1) = (token0, token1);
            require(to != _token0 && to != _token1, "Pair: invalid to");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0)
                IPairCallee(to).hook(msg.sender, amount0Out, amount1Out, data); // callback, used for flash loans
            _balance0 = IERC20(_token0).balanceOf(address(this));
            _balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = _balance0 > _reserve0 - amount0Out
            ? _balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = _balance1 > _reserve1 - amount1Out
            ? _balance1 - (_reserve1 - amount1Out)
            : 0;
        require(amount0In > 0 || amount1In > 0, "Pair: insufficient amount in");
        {
            address feeTo = IFactory(factory).feeTo();
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            (address _token0, address _token1) = (token0, token1);

            if (feeTo == address(0)) {
                if (amount0In > 0)
                    _collectToken0Fees((amount0In * swapFee) / 1e18); // accrue fees for token0 and move them out of pool
                if (amount1In > 0)
                    _collectToken1Fees((amount1In * swapFee) / 1e18); // accrue fees for token1 and move them out of pool
            } else {
                uint256 fee = (
                    amount0In > 0 ? amount0In : amount1In * swapFee
                ) / 1e18;

                uint256 governorFee = (fee * 0.1e18) / 1e18;

                if (amount0In > 0) {
                    _collectToken0Fees(fee - governorFee); // accrue fees for token0 and move them out of pool
                    _safeTransfer(token0, feeTo, governorFee);
                }
                if (amount1In > 0) {
                    _collectToken1Fees(fee - governorFee); // accrue fees for token1 and move them out of pool
                    _safeTransfer(token1, feeTo, governorFee);
                }
            }

            _balance0 = IERC20(_token0).balanceOf(address(this)); // since we removed tokens, we need to reconfirm balances, can also simply use previous balance - amountIn/ 10000, but doing balanceOf again as safety check
            _balance1 = IERC20(_token1).balanceOf(address(this));
            // The curve, either x3y+y3x for stable pools, or x*y for volatile pools
            require(
                _k(_balance0, _balance1) >= _k(_reserve0, _reserve1),
                "Pair: K error"
            );
        }

        _sync(_balance0, _balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        (address _token0, address _token1) = (token0, token1);
        _safeTransfer(
            _token0,
            to,
            IERC20(_token0).balanceOf(address(this)) - (reserve0)
        );
        _safeTransfer(
            _token1,
            to,
            IERC20(_token1).balanceOf(address(this)) - (reserve1)
        );
    }

    // force reserves to match balances
    function sync() external lock {
        _sync(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }

    function getAmountOut(uint256 amountIn, address tokenIn)
        external
        view
        returns (uint256)
    {
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        amountIn -= (amountIn * swapFee) / 1e18; // remove fee from amount received
        return _computeAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

    function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
        return
            (x0 * ((((y * y) / 1e18) * y) / 1e18)) /
            1e18 +
            (((((x0 * x0) / 1e18) * x0) / 1e18) * y) /
            1e18;
    }

    function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
        return
            (3 * x0 * ((y * y) / 1e18)) /
            1e18 +
            ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    function _getY(
        uint256 x0,
        uint256 xy,
        uint256 y
    ) internal pure returns (uint256) {
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

    function _mint(address recipient, uint256 amount) private {
        _updateFeesFor(recipient); // balances must be updated on mint/burn/transfer
        totalSupply += amount;
        balanceOf[recipient] += amount;
        emit Transfer(address(0), recipient, amount);
    }

    function _burn(address recipient, uint256 amount) internal {
        _updateFeesFor(recipient); // balances must be updated on mint/burn/transfer
        totalSupply -= amount;
        balanceOf[recipient] -= amount;
        emit Transfer(recipient, address(0), amount);
    }

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

    function _sync(
        uint256 balance0,
        uint256 balance1,
        uint256 _reserve0,
        uint256 _reserve1
    ) private {
        uint256 currentTimeStamp = block.timestamp;
        uint256 timeElapsed = currentTimeStamp - blockTimestampLast;

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            reserve0CumulativeLast += _reserve0 * timeElapsed;
            reserve1CumulativeLast += _reserve1 * timeElapsed;
        }

        //solhint-disable-next-line not-rely-on-time
        uint256 index = observationIndexOf(block.timestamp);

        // Get the old observation saved in the current timeslot
        Observation storage observation = observations[index];

        // How much time has passed from observation
        //solhint-disable-next-line not-rely-on-time
        timeElapsed = currentTimeStamp - observation.timestamp;
        // we only want to commit updates once per period (i.e. windowSize / granularity)
        if (timeElapsed > PERIOD_SIZE) {
            observation.timestamp = currentTimeStamp;
            observation.reserve0Cumulative = reserve0CumulativeLast;
            observation.reserve1Cumulative = reserve1CumulativeLast;
        }

        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = currentTimeStamp;
        emit Sync(reserve0, reserve1);
    }

    // Accrue fees on token0
    function _collectToken0Fees(uint256 amount) private {
        _safeTransfer(token0, feesContract, amount); // transfer the fees out to BaseV1Fees
        uint256 _ratio = (amount * 1e18) / totalSupply; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index0 += _ratio;
        }
        emit UpdatedFee(msg.sender, amount, 0);
    }

    // Accrue fees on token1
    function _collectToken1Fees(uint256 amount) private {
        _safeTransfer(token1, feesContract, amount);
        uint256 _ratio = (amount * 1e18) / totalSupply;
        if (_ratio > 0) {
            index1 += _ratio;
        }
        emit UpdatedFee(msg.sender, 0, amount);
    }

    // this function MUST be called on any balance changes, otherwise can be used to infinitely claim fees
    // Fees are segregated from core funds, so fees can never put liquidity at risk
    function _updateFeesFor(address recipient) private {
        uint256 _supplied = balanceOf[recipient]; // get LP balance of `recipient`
        if (_supplied > 0) {
            uint256 _supplyIndex0 = supplyIndex0[recipient]; // get last adjusted index0 for recipient
            uint256 _supplyIndex1 = supplyIndex1[recipient];
            uint256 _index0 = index0; // get global index0 for accumulated fees
            uint256 _index1 = index1;

            supplyIndex0[recipient] = _index0; // update user current position to global position
            supplyIndex1[recipient] = _index1;

            uint256 _delta0 = _index0 - _supplyIndex0; // see if there is any difference that need to be accrued
            uint256 _delta1 = _index1 - _supplyIndex1;

            if (_delta0 > 0) {
                uint256 _share = (_supplied * _delta0) / 1e18; // add accrued difference for each supplied token
                claimable0[recipient] += _share;
            }
            if (_delta1 > 0) {
                uint256 _share = (_supplied * _delta1) / 1e18;
                claimable1[recipient] += _share;
            }
        } else {
            supplyIndex0[recipient] = index0; // new users are set to the default global state
            supplyIndex1[recipient] = index1;
        }
    }

    // returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function _getFirstObservationInWindow()
        private
        view
        returns (Observation memory firstObservation)
    {
        uint256 observationIndex = observationIndexOf(block.timestamp);
        // no overflow issue. if observationIndex + 1 overflows, result is still zero.
        uint256 firstObservationIndex = (observationIndex + 1) % GRANULARITY;
        firstObservation = observations[firstObservationIndex];
    }

    function _transferTokens(
        address from,
        address to,
        uint256 amount
    ) internal {
        _updateFeesFor(from); // update fee position for src
        _updateFeesFor(to); // update fee position for dst

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) private {
        assert(token.code.length > 0);
        //solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "PairHelper: failed to transfer"
        );
    }
}
