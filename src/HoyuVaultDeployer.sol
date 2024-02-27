// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

import {HoyuVault} from "./HoyuVault.sol";
import {IHoyuVaultDeployer} from "./interfaces/IHoyuVaultDeployer.sol";

contract HoyuVaultDeployer is IHoyuVaultDeployer {
    address private _factory;

    constructor() {
        _factory = msg.sender;
    }

    modifier onlyFactory() {
        if (msg.sender != _factory) revert IHoyuVaultDeployer.CallerNotFactory();
        _;
    }

    function deploy(bytes32 salt, address currency, address altcoin) external onlyFactory returns (address vault) {
        vault = address(new HoyuVault{salt: salt}(currency, altcoin, msg.sender, _name(currency), _symbol(currency)));
    }

    // only meant to be used once during initial factory deployment to set owner to factory address
    function setFactory(address factory) external onlyFactory {
        _factory = factory;
    }

    function _name(address currency) private view returns (string memory) {
        // encoded currency.name() call
        return _parse(currency, hex"06fdde03", "Hoyu ", "Hoyu Currency");
    }

    function _symbol(address currency) private view returns (string memory) {
        // encoded currency.symbol() call
        return _parse(currency, hex"95d89b41", "h", "hCUR");
    }

    function _parse(
        address currency,
        bytes memory callBytes,
        string memory prefix,
        string memory fallbackName
    ) private view returns (string memory) {
        (bool success, bytes memory encoded) = currency.staticcall(callBytes);
        if (success && encoded.length > 0) {
            string memory parsed = abi.decode(encoded, (string));
            if (bytes(parsed).length > 0) return string.concat(prefix, parsed);
        }
        return fallbackName;
    }
}
