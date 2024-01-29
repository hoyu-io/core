// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

// Modified from Uniswap v2-periphery (https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol)

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

library SwapMath {
    error InsufficientReserve();
    error InsufficientLiquidity();

    uint256 internal constant SWAP_FEE_PER_MIL = 3;
    uint256 internal constant SWAP_TAXING_MULTIPLIER_PER_MIL = 1000 - SWAP_FEE_PER_MIL;

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
}
