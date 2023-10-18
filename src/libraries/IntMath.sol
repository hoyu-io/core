// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

library IntMath {
    function add(uint256 unsigned, int256 signed) internal pure returns (uint256) {
        if (signed < 0) {
            return unsigned - uint256(-signed);
        } else {
            return unsigned + uint256(signed);
        }
    }

    // TODO: does not handle type(int256).min correctly, consider adjusting
    function sub(uint256 minuend, uint256 subtrahend) internal pure returns (int256) {
        if (minuend >= subtrahend) {
            return int256(minuend - subtrahend);
        } else {
            return -int256(subtrahend - minuend);
        }
    }
}
