// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {HoyuVault} from "./HoyuVault.sol";
import {IHoyuVaultDeployer} from "./interfaces/IHoyuVaultDeployer.sol";

contract HoyuVaultDeployer is Ownable, IHoyuVaultDeployer {
    constructor() Ownable(_msgSender()) {}

    function deploy(bytes32 salt, address currency, address altcoin) external onlyOwner returns (address vault) {
        vault = address(new HoyuVault{salt: salt}(currency, altcoin, owner()));
    }
}
