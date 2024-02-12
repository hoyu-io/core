// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

interface IHoyuCallee {
    function hoyuCall(address sender, uint256 loanAmount, bytes calldata data) external;
}
