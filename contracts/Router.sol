// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./interfaces/IERC20.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IWNT.sol";

import {Route, Amount} from "./lib/DataTypes.sol";
import "./lib/Errors.sol";
import "./lib/Math.sol";

contract Router is IRouter {
    bytes32 private immutable pairCodeHash;

    address public immutable factory;
    //solhint-disable-next-line var-name-mixedcase
    IWNT public immutable WNT;
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    constructor(address _factory, IWNT wnt) {
        factory = _factory;
        pairCodeHash = IFactory(_factory).pairCodeHash();
        WNT = wnt;
    }

    modifier ensure(uint256 deadline) {
        //solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    receive() external payable {
        assert(msg.sender == address(WNT)); // only accept native token from the Wrapped Native contract
    }

    // sorts tokens
    function sortTokens(address tokenA, address tokenB)
        public
        pure
        returns (address token0, address token1)
    {
        if (tokenA == tokenB) revert SameAddress();
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address tokenA,
        address tokenB,
        bool stable
    ) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1, stable)),
                            pairCodeHash // init code hash
                        )
                    )
                )
            )
        );
    }

    // Fetches stable and volatile pair for two tokens
    function getPairs(address tokenA, address tokenB)
        public
        view
        returns (address volatilePair, address stablePair)
    {
        (volatilePair, stablePair) = (
            pairFor(tokenA, tokenB, false),
            pairFor(tokenA, tokenB, true)
        );
    }

    // fetches and sorts the reserves for a pair
    function getReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) public view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IPair(
            pairFor(tokenA, tokenB, stable)
        ).getReserves();

        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // performs {_getBestAmount} in a pair
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (Amount memory amount) {
        (address volatilePair, address stablePair) = getPairs(
            tokenIn,
            tokenOut
        );

        return _getBestAmount(tokenIn, amountIn, stablePair, volatilePair);
    }

    // performs chained {_getBestAmount} calculations on any number of pairs
    function getAmountsOut(uint256 amount, Route[] memory routes)
        public
        view
        returns (Amount[] memory amounts)
    {
        if (routes.length == 0) revert InvalidPath();
        if (amount == 0) revert ZeroAmount();

        unchecked {
            amounts = new Amount[](routes.length + 1);

            amounts[0] = Amount(amount, false);

            for (uint256 i; i < routes.length; i++) {
                (address volatilePair, address stablePair) = getPairs(
                    routes[i].from,
                    routes[i].to
                );

                if (
                    IFactory(factory).isPair(volatilePair) ||
                    IFactory(factory).isPair(stablePair)
                ) {
                    amounts[i + 1] = _getBestAmount(
                        routes[i].from,
                        amounts[i].amount,
                        stablePair,
                        volatilePair
                    );
                }
            }
        }
    }

    function isPair(address pair) external view returns (bool) {
        return IFactory(factory).isPair(pair);
    }

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired
    )
        external
        view
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        address _pair = IFactory(factory).getPair(tokenA, tokenB, stable);
        // handle the case where pair does not exist
        (uint256 reserveA, uint256 reserveB) = (0, 0);
        uint256 _totalSupply = 0;

        if (_pair != address(0)) {
            _totalSupply = IERC20(_pair).totalSupply();
            (reserveA, reserveB) = getReserves(tokenA, tokenB, stable);
        }
        if (reserveA == 0 && reserveB == 0) {
            uint256 minAmount = Math.min(amountADesired, amountBDesired);

            (amountA, amountB) = (
                stable ? minAmount : amountADesired,
                stable ? minAmount : amountBDesired
            );

            liquidity = stable
                ? Math.sqrt(minAmount * minAmount) - MINIMUM_LIQUIDITY
                : Math.sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
        } else {
            uint256 amountBOptimal = _quoteLiquidity(
                amountADesired,
                reserveA,
                reserveB
            );

            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
                liquidity = Math.min(
                    (amountA * _totalSupply) / reserveA,
                    (amountB * _totalSupply) / reserveB
                );
            } else {
                uint256 amountAOptimal = _quoteLiquidity(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
                liquidity = Math.min(
                    (amountA * _totalSupply) / reserveA,
                    (amountB * _totalSupply) / reserveB
                );
            }
        }
    }

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity
    ) external view returns (uint256 amountA, uint256 amountB) {
        address _pair = IFactory(factory).getPair(tokenA, tokenB, stable);

        // Cannot remove liquidity if the pair does not exist
        if (_pair == address(0)) {
            return (0, 0);
        }

        (uint256 reserveA, uint256 reserveB) = getReserves(
            tokenA,
            tokenB,
            stable
        );
        uint256 _totalSupply = IERC20(_pair).totalSupply();

        // If  you pass a liquidity > total supply it will return wrong value.
        amountA = (liquidity * reserveA) / _totalSupply; // using balances ensures pro-rata distribution
        amountB = (liquidity * reserveB) / _totalSupply; // using balances ensures pro-rata distribution
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            stable,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pair = pairFor(tokenA, tokenB, stable);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IPair(pair).mint(to);
    }

    function addLiquidityNativeToken(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountNativeTokenMin,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountNativeToken,
            uint256 liquidity
        )
    {
        (amountToken, amountNativeToken) = _addLiquidity(
            token,
            address(WNT),
            stable,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountNativeTokenMin
        );
        address pair = pairFor(token, address(WNT), stable);
        _safeTransferFrom(token, msg.sender, pair, amountToken);

        WNT.deposit{value: amountNativeToken}();
        assert(WNT.transfer(pair, amountNativeToken));

        liquidity = IPair(pair).mint(to);

        // refund dust eth, if any
        if (msg.value > amountNativeToken)
            _safeTransferNativeToken(msg.sender, msg.value - amountNativeToken);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = pairFor(tokenA, tokenB, stable);

        _safeTransferFrom(pair, msg.sender, pair, liquidity); // send liquidity to pair

        (uint256 amount0, uint256 amount1) = IPair(pair).burn(to);
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        if (amountAMin > amountA) revert InsufficientAmountA();
        if (amountBMin > amountB) revert InsufficientAmountB();
    }

    function removeLiquidityNativeToken(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountNativeTokenMin,
        address to,
        uint256 deadline
    )
        public
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountNativeToken)
    {
        (amountToken, amountNativeToken) = removeLiquidity(
            token,
            address(WNT),
            stable,
            liquidity,
            amountTokenMin,
            amountNativeTokenMin,
            address(this),
            deadline
        );
        _safeTransfer(token, to, amountToken);
        WNT.withdraw(amountNativeToken);
        _safeTransferNativeToken(to, amountNativeToken);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB) {
        IPair(pairFor(tokenA, tokenB, stable)).permit(
            msg.sender,
            address(this),
            approveMax ? type(uint256).max : liquidity,
            deadline,
            v,
            r,
            s
        );

        (amountA, amountB) = removeLiquidity(
            tokenA,
            tokenB,
            stable,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
    }

    function removeLiquidityNativeTokenWithPermit(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountNativeTokenMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountNativeToken) {
        IPair(pairFor(token, address(WNT), stable)).permit(
            msg.sender,
            address(this),
            approveMax ? type(uint256).max : liquidity,
            deadline,
            v,
            r,
            s
        );

        (amountToken, amountNativeToken) = removeLiquidityNativeToken(
            token,
            stable,
            liquidity,
            amountTokenMin,
            amountNativeTokenMin,
            to,
            deadline
        );
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (Amount[] memory amounts) {
        unchecked {
            amounts = getAmountsOut(amountIn, routes);

            if (amountOutMin > amounts[amounts.length - 1].amount)
                revert InsufficientOutput();

            _safeTransferFrom(
                routes[0].from,
                msg.sender,
                pairFor(routes[0].from, routes[0].to, amounts[1].stable),
                amountIn
            );
            _swap(amounts, routes, to);
        }
    }

    function swapExactNativeTokenForTokens(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (Amount[] memory amounts) {
        unchecked {
            if (routes[0].from != address(WNT)) revert InvalidRoute();

            amounts = getAmountsOut(msg.value, routes);

            if (amountOutMin > amounts[amounts.length - 1].amount)
                revert InsufficientOutput();

            WNT.deposit{value: msg.value}();
            assert(
                WNT.transfer(
                    pairFor(routes[0].from, routes[0].to, amounts[1].stable),
                    msg.value
                )
            );
            _swap(amounts, routes, to);
        }
    }

    function swapExactTokensForNativeToken(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (Amount[] memory amounts) {
        unchecked {
            if (routes[routes.length - 1].to != address(WNT))
                revert InvalidRoute();

            amounts = getAmountsOut(amountIn, routes);
            uint256 lastIndex = amounts.length - 1;

            if (amountOutMin > amounts[lastIndex].amount)
                revert InsufficientOutput();

            _safeTransferFrom(
                routes[0].from,
                msg.sender,
                pairFor(routes[0].from, routes[0].to, amounts[1].stable),
                amountIn
            );
            _swap(amounts, routes, address(this));
            WNT.withdraw(amounts[lastIndex].amount);
            _safeTransferNativeToken(to, amounts[lastIndex].amount);
        }
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        Amount[] memory amounts,
        Route[] memory routes,
        address _to
    ) private {
        unchecked {
            for (uint256 i; i < routes.length; i++) {
                (address token0, ) = sortTokens(routes[i].from, routes[i].to);

                uint256 amountOut = amounts[i + 1].amount;

                (uint256 amount0Out, uint256 amount1Out) = routes[i].from ==
                    token0
                    ? (uint256(0), amountOut)
                    : (amountOut, uint256(0));

                address to = i < routes.length - 1
                    ? pairFor(
                        routes[i + 1].from,
                        routes[i + 1].to,
                        amounts[i + 2].stable
                    )
                    : _to;

                IPair(
                    pairFor(routes[i].from, routes[i].to, amounts[i + 1].stable)
                ).swap(amount0Out, amount1Out, to, new bytes(0));
            }
        }
    }

    function _getBestAmount(
        address tokenIn,
        uint256 amountIn,
        address stablePair,
        address volatilePair
    ) private view returns (Amount memory) {
        uint256 amountStable;
        uint256 amountVolatile;

        if (IFactory(factory).isPair(stablePair))
            amountStable = IPair(stablePair).getAmountOut(tokenIn, amountIn);

        if (IFactory(factory).isPair(volatilePair))
            amountVolatile = IPair(volatilePair).getAmountOut(
                tokenIn,
                amountIn
            );

        return
            amountStable > amountVolatile
                ? Amount(amountStable, true)
                : Amount(amountVolatile, false);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) private {
        assert(token.code.length != 0);
        //solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        if (!success || !(data.length == 0 || abi.decode(data, (bool))))
            revert TransferFailed();
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) private {
        assert(token.code.length > 0);
        //solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                value
            )
        );

        if (!success || !(data.length == 0 || abi.decode(data, (bool))))
            revert TransferFromFailed();
    }

    function _safeTransferNativeToken(address to, uint256 value) private {
        //solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = to.call{value: value}("");
        if (!success) revert NativeTokenTransferFailed();
    }

    // given some amount of an asset and pair reserves, returns the optimal amount of reserves to add for the token asset
    function _quoteLiquidity(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) private pure returns (uint256 amountB) {
        if (amountA == 0) revert ZeroAmount();
        if (reserveA == 0 || reserveB == 0) revert NoLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private returns (uint256 amountA, uint256 amountB) {
        if (amountAMin > amountADesired) revert InvalidAmountA();
        if (amountBMin > amountBDesired) revert InvalidAmountB();

        // create the pair if it doesn't exist yet
        address _pair = IFactory(factory).getPair(tokenA, tokenB, stable);
        if (_pair == address(0)) {
            _pair = IFactory(factory).createPair(tokenA, tokenB, stable);
        }
        (uint256 reserveA, uint256 reserveB) = getReserves(
            tokenA,
            tokenB,
            stable
        );
        if (reserveA == 0 && reserveB == 0) {
            uint256 minAmount = Math.min(amountADesired, amountBDesired);
            (amountA, amountB) = stable
                ? (minAmount, minAmount)
                : (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = _quoteLiquidity(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                if (amountBMin > amountBOptimal) revert InsufficientAmountB();

                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = _quoteLiquidity(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                if (amountAMin > amountAOptimal) revert InsufficientAmountA();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
}
