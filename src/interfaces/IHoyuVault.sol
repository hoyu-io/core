// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IHoyuVault is IERC4626 {
    event CollateralDeposit(address indexed sender, address indexed to, uint256 amount);
    event CollateralWithdraw(address indexed sender, address indexed to, uint256 amount);
    event Borrow(address indexed sender, address indexed to, uint256 amount);
    event RepayBorrow(address indexed sender, address indexed to, uint256 amount);
    event Liquidation(
        uint32 indexed liquidationTime,
        uint16 indexed tickFrom,
        uint16 indexed tickTo,
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
    error LiquidationOnSameTimestamp();
    error NoClaimableCollateral();
    error UnclaimedCollateral();
    error LoanLiquidated();

    function INTEREST_RATE() external pure returns (uint256);
    function MIN_FLAT_BORROW_FEE() external pure returns (uint256);
    function BORROW_FEE_PER_MIL() external pure returns (uint256);
    function MINIMUM_SHARES() external pure returns (uint256);
    function BORROW_LIMIT_PER_MIL() external pure returns (uint256);
    function LOAN_TICK_OFFSET() external pure returns (uint16);

    function factory() external view returns (address);
    function pair() external view returns (address);
    function altcoin() external view returns (address);

    function totalLoans() external view returns (uint256);
    function totalFactoredLoans() external view returns (uint256);
    function wordBitmap() external view returns (uint256);
    function tickBitmap(uint8 word) external view returns (uint256);
    function tickFactoredLoans(uint16 tick) external view returns (uint256);
    function tickCollateral(uint16 tick) external view returns (uint256);
    function totalClaimableCollateral() external view returns (uint256);

    function collateralOf(address account) external view returns (uint256);
    function loanOf(address account) external view returns (uint256);
    function liquidationTimestamp(address account) external view returns (uint32);
    function claimableCollateral(uint64 liquidationKey, address account) external view returns (uint256);

    function depositCollateral(uint256 amount, address to) external;
    function withdrawCollateral(uint256 amount, address to) external;
    function takeOutLoan(uint256 amount, address to) external;
    function repayLoan(uint256 amount, address to) external;
    function claimLiquidatedCollateral(uint64 liquidationKey, address to) external;

    function liquidateLoansByOffset(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        int256 currencyAmountInOut,
        int256 altcoinAmountInOut,
        uint32 timestamp
    ) external returns (uint112 currencyLiquidated, uint112 altcoinLiquidated);

    function liquidateLoansByFraction(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        uint256 fractionOut,
        uint32 timestamp
    ) external returns (uint112 currencyLiquidated, uint112 altcoinLiquidated);

    function initialize(address pair) external;
}
