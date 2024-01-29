// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96} from "src/libraries/Q96.sol";

library Factoring {
    uint256 internal constant INTEREST_RATE = 79228162865149129476592432509; // multiplier of ~1.000000004429 per second, 15% yearly interest

    function interestFactorAt(uint256 time) internal pure returns (uint256) {
        return Q96.pow(INTEREST_RATE, time);
    }

    /// @notice Only to be used only with factoringMultiplier >= Q96.ONE
    function factorUp(uint256 amount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(amount, 1 << Q96.DOUBLE_FRACTION_BITS, factoringMultiplier, Math.Rounding.Ceil);
    }

    /// @notice Only to be used only with factoringMultiplier >= Q96.ONE
    function factorDown(uint256 amount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(amount, 1 << Q96.DOUBLE_FRACTION_BITS, factoringMultiplier);
    }

    function unfactorUp(uint256 factoredAmount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(factoredAmount, factoringMultiplier, 1 << Q96.DOUBLE_FRACTION_BITS, Math.Rounding.Ceil);
    }
}
