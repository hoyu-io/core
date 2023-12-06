// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IHoyuVault is IERC4626 {
    event CollateralDeposit(address indexed sender, address indexed to, uint256 deposit);
    event CollateralWithdraw(
        address indexed sender, address indexed to, uint256 withdrawnAmount, uint256 remainingAmount
    );
    // TODO: possibly add total amout owed by all accounts
    event TakeOutLoan(address indexed sender, address indexed to, uint256 loanAmount, uint256 accountOwed);
    event RepayLoan(address indexed sender, address indexed to, uint256 repaidAmount, uint256 accountOwed);
    event Liquidation(
        uint32 indexed blockNumber,
        uint24 indexed tickFrom,
        uint24 indexed tickTo,
        uint256 loansLiquidated,
        uint256 collateralLiquidated
    );

    error CallerNotPair();
    error CallerNotFactory();
    error InsufficientAssets();
    error InsufficientShares();
    error InsufficientCollateral();
    error InsufficientCurrency();
    error InsufficientLoan();
    error NoLoan();
    error ExcessiveAltcoinAmount();
    error InsufficientCollateralization();
    error ExcessBorrowAmount();
    error LiquidationOnSameBlock();
    error NoClaimableCollateral();
    error UnclaimedCollateral();
    error LoanLiquidated();

    function BLOCK_INTEREST_RATE() external pure returns (uint256);
    function IMMEDIATE_INTEREST_RATE() external pure returns (uint256);
    function MINIMUM_SHARES() external pure returns (uint256);
    function BORROW_LIMIT_PER_MIL() external pure returns (uint256);
    function LOAN_COLLATERALIZATION_TICK_OFFSET() external pure returns (uint24);

    function factory() external view returns (address);
    function pair() external view returns (address);
    function altcoin() external view returns (address);

    function totalLoans() external view returns (uint256);
    function totalFactoredLoans() external view returns (uint256);
    function maxTickWordIndex() external view returns (uint16);
    function tickBitmap(uint16 word) external view returns (uint256);
    function tickFactoredLoans(uint24 tick) external view returns (uint256);
    function tickCollateral(uint24 tick) external view returns (uint256);
    function totalClaimableCollateral() external view returns (uint256);

    function collateralOf(address account) external view returns (uint256);
    function loanOf(address account) external view returns (uint256);
    function liquidationBlock(address account) external view returns (uint32);
    function claimableCollateral(uint80 liquidationKey, address account) external view returns (uint256);

    function depositCollateral(uint256 amount, address to) external;
    function withdrawCollateral(uint256 amount, address to) external;
    function takeOutLoan(uint256 amount, address to) external;
    function repayLoan(uint256 amount, address to) external;
    function claimLiquidatedCollateral(uint80 liquidationKey, address to) external;

    function liquidateLoansByOffset(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        int256 currencyAmountInOut,
        int256 altcoinAmountInOut,
        uint32 blockNumber
    ) external returns (uint256 currencyLiquidated, uint256 altcoinLiquidated);

    function liquidateLoansByFraction(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        uint256 fractionOut,
        uint32 blockNumber
    ) external returns (uint256 currencyLiquidated, uint256 altcoinLiquidated);

    function initialize(address pair) external;
}
