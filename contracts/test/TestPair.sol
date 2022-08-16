// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

contract PairGetAmountError {
    function getAmountOut(address, uint256) external pure returns (uint256) {
        assert(false);
        return 1;
    }
}

contract PairGetAmountWrongData {
    function getAmountOut(address, uint256) external pure returns (bytes20) {
        return bytes20(address(0));
    }
}
