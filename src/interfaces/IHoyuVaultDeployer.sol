// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

interface IHoyuVaultDeployer {
    error CallerNotFactory();

    function deploy(bytes32 salt, address currency, address altcoin) external returns (address vault);
    function setFactory(address factory) external;
}
