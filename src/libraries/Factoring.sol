// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96Math} from "src/libraries/Q96Math.sol";

library Factoring {
    error ExcessAmount();

    uint256 public constant BLOCK_INTEREST_RATE = 79228166724881942753771233496; // ~1,000000053 per block, 15% yearly

    function interestFactorAt(uint256 blockNumber) internal pure returns (uint256) {
        return Q96Math.pow(BLOCK_INTEREST_RATE, blockNumber);
    }

    // only to be used only with factoringMultiplier >= Q96Math.ONE
    function factorUp(uint256 amount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(amount, 1 << Q96Math.DOUBLE_FRACTION_BITS, factoringMultiplier, Math.Rounding.Ceil);
    }

    // only to be used only with factoringMultiplier >= Q96Math.ONE
    function factorDown(uint256 amount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(amount, 1 << Q96Math.DOUBLE_FRACTION_BITS, factoringMultiplier);
    }

    function factorQ96Up(uint256 amountQ96, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(amountQ96, Q96Math.ONE, factoringMultiplier, Math.Rounding.Ceil);
    }

    function factorQ96Down(uint256 amountQ96, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(amountQ96, Q96Math.ONE, factoringMultiplier);
    }

    function unfactorUp(uint256 factoredAmount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(factoredAmount, factoringMultiplier, 1 << Q96Math.DOUBLE_FRACTION_BITS, Math.Rounding.Ceil);
    }

    function unfactorDown(uint256 factoredAmount, uint256 factoringMultiplier) internal pure returns (uint256) {
        return Math.mulDiv(factoredAmount, factoringMultiplier, 1 << Q96Math.DOUBLE_FRACTION_BITS);
    }
}
