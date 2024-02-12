// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Q96} from "./Q96.sol";
import {Q128} from "./Q128.sol";
import {IntMath} from "./IntMath.sol";
import {Factoring} from "./Factoring.sol";
import {TickMath} from "./TickMath.sol";
import {SwapMath} from "./SwapMath.sol";

struct ReservesChange {
    uint112 currencyReserve;
    uint112 altcoinReserve;
    int256 currencyAmountInOut;
    int256 altcoinAmountInOut;
    uint256 fractionOut;
    uint32 timestamp;
    uint256 interestFactor;
}

library LiquidationMath {
    error InsufficientReserve();

    uint256 internal constant LOAN_LIMIT_PER_MIL = 102;

    function getLiquidationThresholds(ReservesChange memory data)
        internal
        pure
        returns (uint8 wordPos, uint8 bitPos, uint256 factoredLoanLimit)
    {
        return _getLiquidationThresholds(data, data.currencyReserve, data.altcoinReserve);
    }

    function postLiquidationThresholds(
        ReservesChange memory data,
        uint256 factoredLoansLiquidated,
        uint256 collateralLiquidated
    ) internal pure returns (uint8, uint8, uint256) {
        uint256 loansLiquidated = Factoring.unfactorUp(factoredLoansLiquidated, data.interestFactor);
        uint256 collateralValue = SwapMath.getAmountOut(collateralLiquidated, data.altcoinReserve, data.currencyReserve);

        uint256 currencyFromPair;
        uint256 altcoinToPair;
        if (collateralValue <= loansLiquidated) {
            currencyFromPair = collateralValue;
            altcoinToPair = collateralLiquidated;
        } else {
            currencyFromPair = loansLiquidated;
            altcoinToPair = SwapMath.getAmountIn(loansLiquidated, data.altcoinReserve, data.currencyReserve);
        }

        return _getLiquidationThresholds(
            data, data.currencyReserve - currencyFromPair, data.altcoinReserve + altcoinToPair
        );
    }

    function _getLiquidationThresholds(
        ReservesChange memory data,
        uint256 currencyReserve,
        uint256 altcoinReserve
    ) private pure returns (uint8 wordPos, uint8 bitPos, uint256 factoredLoanLimit) {
        int256 currencyAmountInOut = data.fractionOut > 0
            ? -int256((data.fractionOut * currencyReserve) >> Q96.FRACTION_BITS)
            : data.currencyAmountInOut;
        int256 altcoinAmountInOut = data.fractionOut > 0
            ? -int256((data.fractionOut * altcoinReserve) >> Q96.FRACTION_BITS)
            : data.altcoinAmountInOut;

        uint256 currencyReserveWithOffset = IntMath.add(currencyReserve, currencyAmountInOut);
        uint256 altcoinReserveWithOffset = IntMath.add(altcoinReserve, altcoinAmountInOut);

        if (currencyReserveWithOffset == 0 || altcoinReserveWithOffset == 0) revert InsufficientReserve();

        uint256 priceQ128 = Math.mulDiv(currencyReserveWithOffset, Q128.ONE, altcoinReserveWithOffset);
        uint256 factoredPriceQ128 = Math.mulDiv(priceQ128, Q96.ONE, data.interestFactor);
        uint16 tick = TickMath.getTickAtPrice(factoredPriceQ128);
        (wordPos, bitPos) = TickMath.tickPosition(tick);

        factoredLoanLimit =
            Factoring.factorDown(LOAN_LIMIT_PER_MIL * currencyReserveWithOffset / 1000, data.interestFactor);
    }
}
