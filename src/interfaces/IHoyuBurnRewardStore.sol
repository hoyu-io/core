// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

interface IHoyuBurnRewardStore {
    error CallerNotPair();

    function payOutRewards(uint256 currencyAmount, uint256 altcoinAmount, address recipient) external;
}
