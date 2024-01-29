// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

library IntMath {
    /// @notice Lowest supported signed parameter is type(int256).min + 1
    function add(uint256 unsigned, int256 signed) internal pure returns (uint256) {
        if (signed < 0) {
            return unsigned - uint256(-signed);
        } else {
            return unsigned + uint256(signed);
        }
    }

    /// @notice Lowest supported output result is type(int256).min + 1
    function sub(uint256 minuend, uint256 subtrahend) internal pure returns (int256) {
        if (minuend >= subtrahend) {
            return SafeCast.toInt256(minuend - subtrahend);
        } else {
            return -SafeCast.toInt256(subtrahend - minuend);
        }
    }
}
