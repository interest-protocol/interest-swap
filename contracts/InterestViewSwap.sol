// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./interfaces/IERC20.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPair.sol";

import "./DataTypes.sol";

interface InterestViewBalancesInterface {
    function getUserBalances(address account, address[] calldata tokens)
        external
        view
        returns (uint256 nativeBalance, uint256[] memory balances);

    function getUserBalanceAndAllowance(
        address user,
        address spender,
        address token
    ) external view returns (uint256 allowance, uint256 balance);

    function getUserBalancesAndAllowances(
        address user,
        address spender,
        address[] calldata tokens
    )
        external
        view
        returns (uint256[] memory allowances, uint256[] memory balances);
}

struct ERC20Metadata {
    string name;
    string symbol;
    uint256 decimals;
}

struct PairMetadata {
    ERC20Metadata token0Metadata;
    ERC20Metadata token1Metadata;
    address token0;
    address token1;
    bool isStable;
    uint256 reserve0;
    uint256 reserve1;
}

contract InterestViewSwap {
    IFactory private immutable factory;
    IRouter private immutable router;
    InterestViewBalancesInterface private immutable viewBalances;

    constructor(IRouter _router, InterestViewBalancesInterface _viewBalances) {
        router = _router;
        factory = IFactory(_router.factory());
        viewBalances = _viewBalances;
    }

    function getERC20Metadata(IERC20 token)
        public
        view
        returns (ERC20Metadata memory)
    {
        string memory name = token.name();
        string memory symbol = token.symbol();
        uint256 decimals = token.decimals();

        return ERC20Metadata(name, symbol, decimals);
    }

    function getPairData(IPair pair, address account)
        external
        view
        returns (
            PairMetadata memory pairMetadata,
            uint256[] memory allowances,
            uint256[] memory balances
        )
    {
        if (factory.isPair(address(pair))) {
            (
                address t0,
                address t1,
                bool isStable,
                ,
                uint256 r0,
                uint256 r1,
                ,

            ) = pair.metadata();

            pairMetadata = PairMetadata(
                getERC20Metadata(IERC20(t0)),
                getERC20Metadata(IERC20(t1)),
                t0,
                t1,
                isStable,
                r0,
                r1
            );

            address[] memory tokens = new address[](3);
            tokens[0] = address(pair);
            tokens[1] = t0;
            tokens[2] = t1;

            (allowances, balances) = viewBalances.getUserBalancesAndAllowances(
                account,
                address(router),
                tokens
            );
        }
    }

    function getAmountsOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address[] calldata bases
    ) external view returns (address base, uint256 amountOut) {
        Amount memory amountStruct = router.getAmountOut(
            amountIn,
            tokenIn,
            tokenOut
        );

        amountOut = amountStruct.amount;

        for (uint256 i; i < bases.length; i++) {
            address _base = bases[i];

            Route[] memory route = new Route[](2);

            route[0] = Route({from: tokenIn, to: _base});
            route[1] = Route({from: _base, to: tokenOut});

            Amount[] memory amounts = router.getAmountsOut(amountIn, route);
            if (amounts.length < 3) continue;
            uint256 _amount = amounts[amounts.length - 1].amount;

            if (_amount > amountOut) {
                amountOut = _amount;
                base = _base;
            }
        }
    }

    function getAmountsIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address[] calldata bases
    ) external view returns (address base, uint256 amountOut) {
        (address volatilePair, address stablePair) = router.getPairs(
            tokenIn,
            tokenOut
        );
        Amount memory amountStruct = _getWorstAmount(
            tokenIn,
            amountIn,
            stablePair,
            volatilePair
        );

        amountOut = amountStruct.amount;

        for (uint256 i; i < bases.length; i++) {
            address _base = bases[i];

            Route[] memory route = new Route[](2);

            route[0] = Route({from: tokenIn, to: _base});
            route[1] = Route({from: _base, to: tokenOut});

            Amount[] memory amounts = _getAmountsIn(amountIn, route);
            if (amounts.length < 3) continue;
            uint256 _amount = amounts[amounts.length - 1].amount;

            if (_amount < amountOut && _amount != 0) {
                amountOut = _amount;
                base = _base;
            }
        }
    }

    function _getAmountsIn(uint256 amount, Route[] memory routes)
        private
        view
        returns (Amount[] memory amounts)
    {
        unchecked {
            amounts = new Amount[](routes.length + 1);

            amounts[0] = Amount(amount, false);

            for (uint256 i; i < routes.length; i++) {
                (address volatilePair, address stablePair) = router.getPairs(
                    routes[i].from,
                    routes[i].to
                );

                if (
                    IFactory(factory).isPair(volatilePair) ||
                    IFactory(factory).isPair(stablePair)
                ) {
                    amounts[i + 1] = _getWorstAmount(
                        routes[i].from,
                        amounts[i].amount,
                        stablePair,
                        volatilePair
                    );
                }
            }
        }
    }

    function _getWorstAmount(
        address tokenIn,
        uint256 amountIn,
        address stablePair,
        address volatilePair
    ) private view returns (Amount memory) {
        uint256 amountStable;
        uint256 amountVolatile;

        if (IFactory(factory).isPair(stablePair)) {
            (bool success, bytes memory data) = stablePair.staticcall(
                abi.encodeWithSelector(
                    IPair.getAmountOut.selector,
                    tokenIn,
                    amountIn
                )
            );

            if (success && data.length == 32)
                amountStable = abi.decode(data, (uint256));
        }

        if (IFactory(factory).isPair(volatilePair)) {
            (bool success, bytes memory data) = volatilePair.staticcall(
                abi.encodeWithSelector(
                    IPair.getAmountOut.selector,
                    tokenIn,
                    amountIn
                )
            );

            if (success && data.length == 32)
                amountVolatile = abi.decode(data, (uint256));
        }

        return
            amountStable < amountVolatile && amountStable != 0
                ? Amount(amountStable, true)
                : Amount(amountVolatile, false);
    }
}
