// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

// Modified from PaulRBerg prb-math (https://github.com/PaulRBerg/prb-math/blob/57667c5113d800fdcf6fd13966dbd84c6b79de70/src/ud60x18/Math.sol)

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library Q96 {
    uint8 internal constant FRACTION_BITS = 96;
    uint8 internal constant DOUBLE_FRACTION_BITS = FRACTION_BITS * 2;

    /// @dev Q96 fraction representing 1
    uint256 internal constant ONE = 1 << FRACTION_BITS;

    /// @notice Raises baseX96 to the power of exponent.
    /// @param baseX96 The base as an X96 number.
    /// @param exponent The exponent as an uint256.
    /// @return resultX96 The result as an X96 number.
    function pow(uint256 baseX96, uint256 exponent) internal pure returns (uint256 resultX96) {
        resultX96 = exponent & 1 > 0 ? baseX96 : ONE;
        for (exponent >>= 1; exponent > 0; exponent >>= 1) {
            baseX96 = Math.mulDiv(baseX96, baseX96, ONE);
            if (exponent & 1 > 0) {
                resultX96 = Math.mulDiv(resultX96, baseX96, ONE);
            }
        }
    }
}
