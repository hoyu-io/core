// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

interface IHoyuPairDeployer {
    error CallerNotFactory();

    function deploy(bytes32 salt, address currency, address altcoin, address vault) external returns (address pair);
    function setFactory(address factory) external;
}
