# Hoyu

Welcome to the GitHub repository of Hoyu. Hoyu is a DeFi protocol uniting lending and trading markets to give every token new utility as safe collateral.

## Overview

Smart contracts in this repo allow creating linked trading markets (of the uniV2/k=x\*y type) and lending markets for any token pair with no external dependencies such as oracles or liquidators.
  -  Enables creation of trading and lending markets for any token pair.
  -  Supports token swapping between any paired tokens.
  -  Allows users to deposit one token as collateral and borrow the paired token.
  -  Automates liquidation processes, which are triggered during specific events such as swaps and syncs on the trading market side.

## License
This project is licensed under the [GPL-3.0 License](https://www.gnu.org/licenses/gpl-3.0.en.html)

## Manual Deployment
Take the following steps to manually deploy the required infrastructure:
  1.  Deploy the PairDeployer contract
  1.  Deploy the VaultDeployer contract
  1.  Deploy the HoyuFactory contract, use the addresses of PairDeployer and VaultDeployer as parameters
  1.  Call transferOwnership on PairDeployer, use address of HoyuFactory as parameter
  1.  Call transferOwnership on VaultDeployer, use address of HoyuFactory as parameter
  1.  Call setFeeTo on HoyuFactory, use own wallet address as parameter


## Important Note

This software is in active development and made public for experimental purposes. It is NOT recommended for production use, especially in applications involving real-world funds. Use at your own risk.

## Learn more and join Hoyu's community

  -  [Blog](https://blog.hoyu.io/): Unpack technical nuances
  -  [Telegram](https://t.me/hoyu_community): Join the friendly discussions
  -  [X (née Twitter)](https://x.com/hoyu_io): Follow to stay up to date
