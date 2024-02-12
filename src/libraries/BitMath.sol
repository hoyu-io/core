// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

// Modified from Uniswap solidity-lib (https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/BitMath.sol)

library BitMath {
    error NoSetBits();

    // returns the 0 indexed position of the most significant bit of the input x
    // s.t. x >= 2**msb and x < 2**(msb+1)
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert NoSetBits();

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            r += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            r += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            r += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            r += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            r += 2;
        }
        if (x >= 0x2) r += 1;
    }

    function getBit(uint256 word, uint8 bit) internal pure returns (bool) {
        return word & (1 << bit) != 0;
    }

    function setBit(uint256 word, uint8 bit) internal pure returns (uint256) {
        return word | (1 << bit);
    }

    function unsetBit(uint256 word, uint8 bit) internal pure returns (uint256) {
        return word & ~(1 << bit);
    }
}
