//SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

//solhint-disable no-inline-assembly
library Math {
    // Common scalar for ERC20 and native assets
    uint256 private constant SCALAR = 1e18;

    /**
     * @notice Taken from https://twitter.com/transmissions11/status/1451129626432978944/photo/1
     */
    function fmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            if iszero(or(iszero(x), eq(div(mul(x, y), x), y))) {
                revert(0, 0)
            }

            z := div(mul(x, y), SCALAR)
        }
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
