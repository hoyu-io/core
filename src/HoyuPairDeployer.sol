// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

import {HoyuPair} from "./HoyuPair.sol";
import {IHoyuPairDeployer} from "./interfaces/IHoyuPairDeployer.sol";

contract HoyuPairDeployer is IHoyuPairDeployer {
    address private _factory;

    constructor() {
        _factory = msg.sender;
    }

    modifier onlyFactory() {
        if (msg.sender != _factory) revert IHoyuPairDeployer.CallerNotFactory();
        _;
    }

    function deploy(
        bytes32 salt,
        address currency,
        address altcoin,
        address vault
    ) external onlyFactory returns (address pair) {
        pair = address(new HoyuPair{salt: salt}(currency, altcoin, vault, msg.sender));
    }

    function setFactory(address factory) external onlyFactory {
        _factory = factory;
    }
}
