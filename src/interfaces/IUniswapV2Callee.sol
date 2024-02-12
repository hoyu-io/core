// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 currencyAmount,
        uint256 altcoinAmount,
        bytes calldata data
    ) external;
}
