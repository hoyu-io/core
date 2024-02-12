// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

/// @notice Returns current block.timestamp as a uint32 value
function timestamp() view returns (uint32) {
    return uint32(block.timestamp);
}
