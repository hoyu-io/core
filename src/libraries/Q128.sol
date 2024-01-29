// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BitMath} from "src/libraries/BitMath.sol";

library Q128 {
    /// @dev Q128 fraction representing 1
    uint256 internal constant ONE = 1 << 128;

    /// @notice Calculates the square root of a given non-zero Q128.128 number
    function sqrt(uint256 val) internal pure returns (uint256 sqrt_) {
        uint8 msb = BitMath.mostSignificantBit(val);
        uint8 shift = msb < 128 ? 128 : (uint8(255 - msb) & ~uint8(1));
        sqrt_ = Math.sqrt(val << shift);
        if (shift < 128) {
            sqrt_ <<= (64 - shift / 2);
        }
    }
}
