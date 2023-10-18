// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Context} from "openzeppelin-contracts/contracts/utils/Context.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IHoyuBurnRewardStore} from "./interfaces/IHoyuBurnRewardStore.sol";

contract HoyuBurnRewardStore is IHoyuBurnRewardStore, Context {
    address private _pair;
    address private _currency;
    address private _altcoin;

    constructor(address currency, address altcoin) {
        _pair = _msgSender();
        _currency = currency;
        _altcoin = altcoin;
    }

    function payOutRewards(uint256 currencyAmount, uint256 altcoinAmount, address recipient) external {
        if (_msgSender() != _pair) revert CallerNotPair();

        SafeERC20.safeTransfer(IERC20(_currency), recipient, currencyAmount);
        SafeERC20.safeTransfer(IERC20(_altcoin), recipient, altcoinAmount);
    }
}
