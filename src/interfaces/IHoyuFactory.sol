// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

interface IHoyuFactory {
    event PairCreated(address indexed currency, address indexed altcoin, address pair, uint256);

    error IdenticalTokenAddresses();
    error ZeroCurrencyAddress();
    error ZeroAltcoinAddress();
    error PairAlreadyExists();
    error HoyuTokenSetDisallowed();

    function createPair(address currency, address altcoin) external returns (address pair);
    function getPair(address currency, address altcoin) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function setHoyuToken(address) external;
    function hoyuToken() external view returns (address);
}
