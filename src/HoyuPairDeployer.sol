// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {HoyuPair} from "./HoyuPair.sol";
import {IHoyuPairDeployer} from "./interfaces/IHoyuPairDeployer.sol";

contract HoyuPairDeployer is Ownable, IHoyuPairDeployer {
    constructor() Ownable(_msgSender()) {}

    function deploy(
        bytes32 salt,
        address currency,
        address altcoin,
        address vault
    ) external onlyOwner returns (address pair) {
        pair = address(new HoyuPair{salt: salt}(currency, altcoin, vault, owner()));
    }
}
