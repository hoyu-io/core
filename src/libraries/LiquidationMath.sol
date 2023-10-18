// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96Math} from "src/libraries/Q96Math.sol";
import {IntMath} from "src/libraries/IntMath.sol";
import "src/libraries/TickMath.sol";
import "src/libraries/LiquidatedAmounts.sol";

error InsufficientReserve();
error InsufficientLiquidity();
error ZeroPrice();

library LiquidationMath {
    struct ReservesChange {
        uint112 currencyReserve;
        uint112 altcoinReserve;
        int256 currencyAmountInOut;
        int256 altcoinAmountInOut;
        uint256 fractionOut;
        uint256 blockNumber;
        uint256 interestFactor;
    }

    using LiquidatedAmounts for LiquidatedAmounts.Amounts;

    uint256 public constant LOAN_LIMIT_PER_MIL = 78;

    // TODO: reuse same constant value from HoyuPair
    uint256 public constant SWAP_FEE_PER_MIL = 3;
    uint256 public constant SWAP_TAXING_MULTIPLIER_PER_MIL = 1000 - SWAP_FEE_PER_MIL;

    function getLiquidationThresholds(ReservesChange memory data)
        internal
        pure
        returns (uint16 wordPos, uint8 bitPos, uint256 factoredLoanLimit)
    {
        return _getLiquidationThresholds(data, data.currencyReserve, data.altcoinReserve);
    }

    function _getLiquidationThresholds(
        ReservesChange memory data,
        uint256 currencyReserve,
        uint256 altcoinReserve
    ) private pure returns (uint16 wordPos, uint8 bitPos, uint256 factoredLoanLimit) {
        int256 currencyAmountInOut = data.fractionOut > 0
            ? -int256(uint256(Q96Math.asUint(data.fractionOut * currencyReserve)))
            : data.currencyAmountInOut;
        int256 altcoinAmountInOut = data.fractionOut > 0
            ? -int256(uint256(Q96Math.asUint(data.fractionOut * altcoinReserve)))
            : data.altcoinAmountInOut;
        // TODO: require currencyReserve is enough to cover currencyAmountInOut;

        uint256 currencyReserveWithOffset = IntMath.add(currencyReserve, currencyAmountInOut);
        uint256 altcoinReserveWithOffset = IntMath.add(altcoinReserve, altcoinAmountInOut);

        if (currencyReserveWithOffset == 0 || altcoinReserveWithOffset == 0) revert InsufficientReserve();

        uint256 price = Q96Math.div(currencyReserveWithOffset, altcoinReserveWithOffset);
        uint256 factoredPrice = Q96Math.div(price, data.interestFactor);
        uint24 tick = priceTick(factoredPrice);
        (wordPos, bitPos) = tickToPosition(tick);

        factoredLoanLimit = Q96Math.div(
            Q96Math.asQ96(uint160(LOAN_LIMIT_PER_MIL * currencyReserveWithOffset / 1000)), data.interestFactor
        );
    }

    function postLiquidationThresholds(
        ReservesChange memory data,
        LiquidatedAmounts.Amounts memory amounts
    ) internal pure returns (uint16, uint8, uint256) {
        uint256 loansLiquidated =
            Q96Math.asUintCeil(Q96Math.mul(amounts.factoredLoansLiquidated(), data.interestFactor));
        uint256 collateralValue = getAmountOut(amounts.collateralLiquidated, data.altcoinReserve, data.currencyReserve);

        uint256 currencyFromPair;
        uint256 altcoinToPair;
        if (collateralValue <= loansLiquidated) {
            currencyFromPair = collateralValue;
            altcoinToPair = amounts.collateralLiquidated;
        } else {
            currencyFromPair = loansLiquidated;
            altcoinToPair = getAmountIn(loansLiquidated, data.altcoinReserve, data.currencyReserve);
        }

        return _getLiquidationThresholds(
            data, data.currencyReserve - currencyFromPair, data.altcoinReserve + altcoinToPair
        );
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientReserve();
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * SWAP_TAXING_MULTIPLIER_PER_MIL;
        amountIn = Math.ceilDiv(numerator, denominator);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * SWAP_TAXING_MULTIPLIER_PER_MIL;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function priceTick(uint256 factoredPrice) internal pure returns (uint24 tick) {
        if (factoredPrice == 0) revert ZeroPrice();

        uint256 sqrtFactoredPrice = Q96Math.sqrt(factoredPrice);
        tick = TickMath.getTickAtSqrtRatio(uint160(sqrtFactoredPrice));
    }

    function tickToPosition(uint24 tick) internal pure returns (uint16 wordPos, uint8 bitPos) {
        wordPos = uint16(tick >> 8);
        bitPos = uint8(tick & 0xff);
    }
}
