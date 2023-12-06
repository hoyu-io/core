// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {IHoyuFactory} from "./interfaces/IHoyuFactory.sol";
import {IHoyuVault} from "./interfaces/IHoyuVault.sol";
import {IHoyuPairDeployer} from "./interfaces/IHoyuPairDeployer.sol";
import {IHoyuVaultDeployer} from "./interfaces/IHoyuVaultDeployer.sol";

contract HoyuFactory is IHoyuFactory {
    address private immutable _pairDeployer;
    address private immutable _vaultDeployer;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    address public hoyuToken;
    address private immutable _creator;

    constructor(address pairDeployer, address vaultDeployer) {
        _pairDeployer = pairDeployer;
        _vaultDeployer = vaultDeployer;
        _creator = msg.sender;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address currency, address altcoin) external returns (address pair) {
        if (currency == altcoin) revert IdenticalTokenAddresses();
        if (currency == address(0)) revert ZeroCurrencyAddress();
        if (altcoin == address(0)) revert ZeroAltcoinAddress();
        if (getPair[currency][altcoin] != address(0)) revert PairAlreadyExists();

        bytes32 salt = keccak256(abi.encodePacked(currency, altcoin));

        address vault = IHoyuVaultDeployer(_vaultDeployer).deploy(salt, currency, altcoin);
        pair = IHoyuPairDeployer(_pairDeployer).deploy(salt, currency, altcoin, vault);
        IHoyuVault(vault).initialize(pair);

        getPair[currency][altcoin] = pair;
        allPairs.push(pair);

        emit PairCreated(currency, altcoin, pair, allPairs.length);
    }

    function setHoyuToken(address tokenAddress) external override {
        if (hoyuToken != address(0) || msg.sender != _creator) revert HoyuTokenSetDisallowed();

        hoyuToken = tokenAddress;
    }
}
