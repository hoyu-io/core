// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

library LiquidatedAmounts {
    struct Amounts {
        uint256 totalFactoredLoans;
        uint256 remainingFactoredLoans;
        uint256 collateralLiquidated;
    }

    function create(uint256 totalFactoredLoans) internal pure returns (Amounts memory) {
        return Amounts(totalFactoredLoans, totalFactoredLoans, 0);
    }

    function liquidate(
        Amounts memory amounts,
        uint256 factoredLoansLiquidated_,
        uint256 collateralLiquidated
    ) internal pure returns (Amounts memory) {
        amounts.remainingFactoredLoans -= factoredLoansLiquidated_;
        amounts.collateralLiquidated += collateralLiquidated;
        return amounts;
    }

    function factoredLoansLiquidated(Amounts memory amounts) internal pure returns (uint256) {
        return amounts.totalFactoredLoans - amounts.remainingFactoredLoans;
    }
}
