// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

// Modified from Uniswap v3-core (https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol)

import {Q128} from "./Q128.sol";

library TickMath {
    /// @notice Calculates an uint16 tick for a given Q128.128 price
    function getTickAtPrice(uint256 priceX128) internal pure returns (uint16 tick) {
        if (priceX128 == 0) return 0;

        uint256 ratio = Q128.sqrt(priceX128);

        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        int256 log2_ = (int256(msb) - 128) << 64;

        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log2_ := or(log2_, shl(55, f))
        }

        int256 logSqrt100271 = log2_ * 9444732965739290427392; // 128.128 number
        int16 intTick = int16(logSqrt100271 >> 128);

        unchecked {
            tick = uint16(intTick - type(int16).min);
        }
    }

    function tickPosition(uint16 tick) internal pure returns (uint8 wordPos, uint8 bitPos) {
        wordPos = uint8(tick >> 8);
        bitPos = uint8(tick & 0xff);
    }
}
