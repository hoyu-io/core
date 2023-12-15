// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "src/libraries/BitMath.sol";

library Q96Math {
    uint8 public constant FRACTION_BITS = 96;
    uint8 public constant DOUBLE_FRACTION_BITS = FRACTION_BITS * 2;
    uint256 public constant ONE = 1 << FRACTION_BITS;

    function asQ96(uint160 val) internal pure returns (uint256) {
        return uint256(val) << FRACTION_BITS;
    }

    function asUint(uint256 val) internal pure returns (uint160) {
        return uint160(val >> FRACTION_BITS);
    }

    function asUintCeil(uint256 val) internal pure returns (uint168) {
        return uint168(Math.ceilDiv(val, ONE));
    }

    function pow(uint256 base, uint256 exponent) internal pure returns (uint256 resultUint) {
        // Calculate the first iteration of the loop in advance.
        resultUint = exponent & 1 > 0 ? base : ONE;

        // Equivalent to "for(exponent /= 2; exponent > 0; exponent /= 2)" but faster.
        for (exponent >>= 1; exponent > 0; exponent >>= 1) {
            base = Math.mulDiv(base, base, ONE);

            // Equivalent to "exponent % 2 == 1" but faster.
            if (exponent & 1 > 0) {
                resultUint = Math.mulDiv(resultUint, base, ONE);
            }
        }
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, Q96Math.ONE);
    }

    function mul(uint256 a, uint256 b, Math.Rounding rounding) internal pure returns (uint256) {
        return Math.mulDiv(a, b, Q96Math.ONE, rounding);
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, Q96Math.ONE, b);
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, Q96Math.ONE, b, Math.Rounding.Up);
    }

    function sqrt(uint256 val) internal pure returns (uint256 sqrt_) {
        uint8 msb = BitMath.mostSignificantBit(val);
        uint8 shift = msb < 160 ? 96 : (uint8(255 - msb) & ~uint8(1));
        uint256 shiftedVal = val << shift;
        sqrt_ = Math.sqrt(shiftedVal);
        if (shift < 96) {
            sqrt_ <<= (48 - shift / 2);
        }
    }
}
