// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96Math} from "src/libraries/Q96Math.sol";
import {Factoring} from "src/libraries/Factoring.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHoyuPair} from "./interfaces/IHoyuPair.sol";
import {IHoyuVault} from "./interfaces/IHoyuVault.sol";
import {IHoyuFactory} from "./interfaces/IHoyuFactory.sol";
import "src/libraries/TickMath.sol";
import "src/libraries/BitMath.sol";
import "src/libraries/LiquidationMath.sol";
import "src/libraries/LiquidatedAmounts.sol";

contract HoyuVault is ERC4626, IHoyuVault {
    using LiquidationMath for LiquidationMath.ReservesChange;
    using LiquidatedAmounts for LiquidatedAmounts.Amounts;

    uint256 public constant BLOCK_INTEREST_RATE = Factoring.BLOCK_INTEREST_RATE;
    uint256 public constant MIN_FLAT_BORROW_FEE = 5000000;
    uint256 public constant BORROW_FEE_PER_MIL = 5;
    uint256 public constant MINIMUM_SHARES = 10 ** 3;
    uint256 public constant BORROW_LIMIT_PER_MIL = 70;
    uint24 public constant LOAN_COLLATERALIZATION_TICK_OFFSET = 954; // 110% collateralization

    address public immutable factory;
    address public immutable altcoin;
    address public pair;

    uint256 public totalClaimableCollateral;
    uint256 public totalFactoredLoans;

    uint16 public maxTickWordIndex;
    mapping(uint16 => uint256) public tickBitmap;
    mapping(uint24 => uint256) public tickFactoredLoans;
    mapping(uint24 => uint256) public tickCollateral;

    mapping(address => uint256) private _collateralOf;
    mapping(address => uint256) private _factoredLoanOf;
    mapping(address => uint32) private _userLoanBlock;
    mapping(address => uint24) private _userLoanTick;

    mapping(uint24 => uint256) private _tickLiquidations;
    mapping(uint80 => uint256) private _liquidations;

    modifier processingReentrancyGuard() {
        IHoyuPair(pair).lockAndProcessBurn();
        _;
        IHoyuPair(pair).unlock();
    }

    constructor(
        address currency,
        address altcoin_,
        address factory_
    ) ERC4626(IERC20(currency)) ERC20("Hoyu Vault", "HOYV") {
        altcoin = altcoin_;
        factory = factory_;
    }

    function initialize(address pair_) external {
        if (_msgSender() != factory) revert CallerNotFactory();
        pair = pair_;
    }

    function collateralOf(address borrower) external view returns (uint256) {
        uint256 collateral = _collateralOf[borrower];
        if (collateral == 0 || _isLiquidated(borrower)) return 0;

        return collateral;
    }

    function loanOf(address borrower) external view returns (uint256) {
        uint256 factoredLoan = _factoredLoanOf[borrower];
        if (factoredLoan == 0 || _isLiquidated(borrower)) return 0;

        return Factoring.unfactorUp(factoredLoan, _interestFactor());
    }

    function _isLiquidated(address borrower) private view returns (bool) {
        uint24 tick = _userLoanTick[borrower];
        return tick > 0 && uint32(_tickLiquidations[tick]) >= _userLoanBlock[borrower];
    }

    // returning 0 means loan was either not liquidated or liquidation block is no longer known
    function liquidationBlock(address borrower) public view returns (uint32) {
        uint24 tick = _userLoanTick[borrower];
        uint32 loanBlock = _userLoanBlock[borrower];

        uint256 tickLiquidations = _tickLiquidations[tick];
        uint32 liquidationBefore = uint32(tickLiquidations >> 224);

        while (tickLiquidations != 0) {
            if (liquidationBefore >= loanBlock) break;

            uint32 liquidationAfter = uint32(tickLiquidations >> 192);
            if (liquidationBefore < loanBlock && loanBlock <= liquidationAfter) return liquidationAfter;

            liquidationBefore = liquidationAfter;
            tickLiquidations <<= 32;
        }

        return 0;
    }

    function claimableCollateral(uint80 liquidationKey, address account) public view returns (uint256) {
        uint256 liquidation = _liquidations[liquidationKey];
        uint32 liquidatedAt = uint32(liquidationKey >> 48);

        if (liquidation == 0 || liquidatedAt == 0 || liquidatedAt != liquidationBlock(account)) return 0;

        uint256 totalCurrencyLiquidated = liquidation >> 128;
        uint256 totalAltcoinLiquidated = uint128(liquidation);

        uint256 owed = Factoring.unfactorUp(_factoredLoanOf[account], Factoring.interestFactorAt(liquidatedAt));

        uint256 collateralLiquidated =
            Math.mulDiv(owed, totalAltcoinLiquidated, totalCurrencyLiquidated, Math.Rounding.Ceil);
        uint256 collateral = _collateralOf[account];
        if (collateralLiquidated >= collateral) return 0;

        return collateral - collateralLiquidated;
    }

    function totalLoans() public view returns (uint256) {
        return Factoring.unfactorUp(totalFactoredLoans, _interestFactor());
    }

    // TODO: other ERC4626 overrides
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalLoans();
    }

    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256 assets) {
        assets = super.maxWithdraw(owner);
        uint256 availableAssets = IERC20(asset()).balanceOf(address(this));
        if (availableAssets < assets) {
            assets = availableAssets;
        }
    }

    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256 shares) {
        shares = super.maxRedeem(owner);
        uint256 availableAssets = IERC20(asset()).balanceOf(address(this));
        uint256 redeemableShares = _convertToShares(availableAssets, Math.Rounding.Floor);
        if (redeemableShares < shares) {
            shares = redeemableShares;
        }
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626, IERC4626) processingReentrancyGuard returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626, IERC4626) processingReentrancyGuard returns (uint256) {
        return super.mint(shares, receiver);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override(ERC4626, IERC4626) processingReentrancyGuard returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override(ERC4626, IERC4626) processingReentrancyGuard returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (assets == 0 || supply == 0) {
            if (assets <= MINIMUM_SHARES) revert InsufficientAssets();
            return assets - MINIMUM_SHARES;
        }

        return Math.mulDiv(assets, supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (shares == 0) revert InsufficientShares();
            return shares + MINIMUM_SHARES;
        }
        return Math.mulDiv(shares, totalAssets(), supply, rounding);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        bool firstDeposit = totalSupply() == 0;
        super._deposit(caller, receiver, assets, shares);
        if (firstDeposit) {
            _mint(address(0xdead), MINIMUM_SHARES);
        }
    }

    // TODO: possibly want to limit the total amount of collateral deposited, so as not to exeed 112 bit reserve limit after liquidation
    function depositCollateral(uint256 amount, address to) external processingReentrancyGuard {
        // TODO: confirm whether it would be cheaper to just use liquidationBlock instead of _isLiquidated, reusing it inside the if
        if (_isLiquidated(to)) {
            if (_msgSender() != to && liquidationBlock(to) > 0) revert UnclaimedCollateral();
            _clearLiquidatedLoan(to);
        }

        SafeERC20.safeTransferFrom(IERC20(altcoin), _msgSender(), address(this), amount);

        uint256 collateralPrior = _collateralOf[to];
        uint256 collateral = collateralPrior + amount;

        uint256 factoredOwed = _factoredLoanOf[to];
        if (factoredOwed > 0) {
            _adjustLoan(to, factoredOwed, collateralPrior, factoredOwed, collateral);
            // any unhealthy loans should have already been liquidated, depositing extra collateral can only cause a healthier state than before - no additional health check needed
            // TODO: emit loan change event
        }

        _collateralOf[to] = collateral;

        // TODO: consider adding total collateral to event
        emit CollateralDeposit(_msgSender(), to, amount);
    }

    function withdrawCollateral(uint256 amount, address to) external processingReentrancyGuard {
        if (_isLiquidated(_msgSender())) revert LoanLiquidated();

        uint256 collateralPrior = _collateralOf[_msgSender()];
        if (collateralPrior < amount) revert InsufficientCollateral();

        uint256 collateral = collateralPrior - amount;

        uint256 factoredOwed = _factoredLoanOf[_msgSender()];
        if (factoredOwed > 0) {
            uint24 tick = _adjustLoan(_msgSender(), factoredOwed, collateralPrior, factoredOwed, collateral);
            _verifyLoanHealthy(tick, _interestFactor(), false);
            // TODO: emit loan change event
        }

        _collateralOf[_msgSender()] = collateral;

        SafeERC20.safeTransfer(IERC20(altcoin), to, amount);

        emit CollateralWithdraw(_msgSender(), to, amount);
    }

    function takeOutLoan(uint256 amount, address to) external processingReentrancyGuard {
        if (_isLiquidated(_msgSender())) revert LoanLiquidated();

        if (amount == 0) revert InsufficientLoan();

        uint256 borrowFee =
            Math.max(MIN_FLAT_BORROW_FEE, Math.mulDiv(amount, BORROW_FEE_PER_MIL, 1000, Math.Rounding.Ceil));
        address hoyuPair = IHoyuFactory(factory).getPair(asset(), IHoyuFactory(factory).hoyuToken());

        {
            uint256 amountFromVault = hoyuPair == address(0) ? amount : amount + borrowFee;
            if (IERC20(asset()).balanceOf(address(this)) < amountFromVault) revert InsufficientCurrency();
        }

        uint256 interestFactor = _interestFactor();
        uint256 factoredOwed = Factoring.factorUp(amount + borrowFee, interestFactor);
        uint256 collateral = _collateralOf[_msgSender()];

        uint256 factoredOwedPrior = _factoredLoanOf[_msgSender()];
        uint24 tick;

        if (factoredOwedPrior > 0) {
            factoredOwed += factoredOwedPrior;
            tick = _adjustLoan(_msgSender(), factoredOwedPrior, collateral, factoredOwed, collateral);
            // TODO: emit loan change event
        } else {
            tick = _addLoan(factoredOwed, collateral, _msgSender());
        }

        _verifyLoanHealthy(tick, interestFactor, true);
        emit Borrow(_msgSender(), to, amount);

        if (hoyuPair != address(0)) {
            SafeERC20.safeTransfer(IERC20(asset()), hoyuPair, borrowFee);
            // TODO: verify if it is possible to skim before syncing
            IHoyuPair(hoyuPair).sync();
        }
        SafeERC20.safeTransfer(IERC20(asset()), to, amount);
    }

    function repayLoan(uint256 amount, address to) external processingReentrancyGuard {
        if (_isLiquidated(to)) revert LoanLiquidated();

        uint256 factoredOwedPrior = _factoredLoanOf[to];
        if (factoredOwedPrior == 0) revert NoLoan();

        uint256 interestFactor = _interestFactor();

        uint256 owedPrior = Factoring.unfactorUp(factoredOwedPrior, interestFactor);
        uint256 factoredRepayAmount;
        if (amount >= owedPrior) {
            // full repayment
            factoredRepayAmount = factoredOwedPrior;
            amount = owedPrior;
        } else {
            // partial repayment
            factoredRepayAmount = Factoring.factorDown(amount, interestFactor);
        }

        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), amount);

        uint256 collateral = _collateralOf[to];

        if (factoredOwedPrior > factoredRepayAmount) {
            uint256 factoredRemainingOwed = factoredOwedPrior - factoredRepayAmount;
            _adjustLoan(to, factoredOwedPrior, collateral, factoredRemainingOwed, collateral);
            // any unhealthy loans should have already been liquidated, repaying loans can only cause a healthier state than before - no additional health check needed
            // TODO: emit loan change event
        } else {
            _removeLoan(factoredOwedPrior, collateral, to);
        }

        emit RepayBorrow(_msgSender(), to, amount);
    }

    function claimLiquidatedCollateral(uint80 liquidationKey, address to) external processingReentrancyGuard {
        uint256 collateralRefund = claimableCollateral(liquidationKey, _msgSender());
        if (collateralRefund > totalClaimableCollateral) {
            collateralRefund = totalClaimableCollateral;
        }

        if (collateralRefund == 0) revert NoClaimableCollateral();

        _clearLiquidatedLoan(_msgSender());
        totalClaimableCollateral -= collateralRefund;

        SafeERC20.safeTransfer(IERC20(altcoin), to, collateralRefund);
    }

    // the caller should make sure pair reserves are correctly updated at the end of the transaction
    function liquidateLoansByOffset(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        int256 currencyAmountInOut,
        int256 altcoinAmountInOut,
        uint32 blockNumber
    ) external returns (uint112, uint112) {
        if (_msgSender() != pair) revert CallerNotPair();

        if (currencyReserve == 0 || altcoinReserve == 0) {
            return (0, 0);
        }

        LiquidationMath.ReservesChange memory reservesChange = LiquidationMath.ReservesChange(
            currencyReserve,
            altcoinReserve,
            currencyAmountInOut,
            altcoinAmountInOut,
            0,
            blockNumber,
            Factoring.interestFactorAt(blockNumber)
        );

        return _liquidateLoans(reservesChange);
    }

    // the caller should make sure pair reserves are correctly updated at the end of the transaction
    function liquidateLoansByFraction(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        uint256 fractionOut,
        uint32 blockNumber
    ) external returns (uint112, uint112) {
        if (_msgSender() != pair) revert CallerNotPair();

        if (currencyReserve == 0 || altcoinReserve == 0) {
            return (0, 0);
        }

        LiquidationMath.ReservesChange memory reservesChange = LiquidationMath.ReservesChange(
            currencyReserve, altcoinReserve, 0, 0, fractionOut, blockNumber, Factoring.interestFactorAt(blockNumber)
        );

        return _liquidateLoans(reservesChange);
    }

    function _liquidateLoans(LiquidationMath.ReservesChange memory reservesChange) private returns (uint112, uint112) {
        if (totalFactoredLoans == 0) {
            return (0, 0);
        }

        (uint16 minWordPos, uint8 minBitPos, uint256 factoredLoanLimit) = reservesChange.getLiquidationThresholds();
        LiquidatedAmounts.Amounts memory liquidationAmounts = LiquidatedAmounts.create(totalFactoredLoans);

        uint24 topTick;
        uint24 liquidatingTick;
        {
            uint16 wPos = maxTickWordIndex;
            while (wPos >= minWordPos || liquidationAmounts.remainingFactoredLoans > factoredLoanLimit) {
                uint256 word = tickBitmap[wPos];
                uint16 bShift = 0;
                uint8 bPos;

                while (word > 0) {
                    uint8 msb = BitMath.mostSignificantBit(word);
                    bPos = msb - uint8(bShift);

                    // if ((processing last word AND unprocessed bits are outside of liquidation range) OR (processing after last word)) AND loans are not above limit
                    if (
                        ((wPos == minWordPos && bPos < minBitPos) || (wPos < minWordPos))
                            && liquidationAmounts.remainingFactoredLoans <= factoredLoanLimit
                    ) {
                        // reevaluate liquidation end tick
                        (minWordPos, minBitPos, factoredLoanLimit) =
                            reservesChange.postLiquidationThresholds(liquidationAmounts);

                        if (
                            ((wPos == minWordPos && bPos < minBitPos) || (wPos < minWordPos))
                                && liquidationAmounts.remainingFactoredLoans <= factoredLoanLimit
                        ) {
                            // tick under evaluation is not going to be liquidated, finished
                            break;
                        }
                    }

                    liquidatingTick = _positionToTick(wPos, bPos);
                    if (topTick == 0) {
                        topTick = liquidatingTick;
                    }
                    _tickLiquidations[liquidatingTick] =
                        (_tickLiquidations[liquidatingTick] << 32) + reservesChange.blockNumber;
                    liquidationAmounts.liquidate(tickFactoredLoans[liquidatingTick], tickCollateral[liquidatingTick]);
                    bShift += 256 - msb;
                    word <<= 256 - msb;
                }

                if (wPos <= minWordPos && word == 0 && liquidationAmounts.remainingFactoredLoans <= factoredLoanLimit) {
                    // reevaluate liquidation end tick if current word is fully liquidated
                    (minWordPos, minBitPos, factoredLoanLimit) =
                        reservesChange.postLiquidationThresholds(liquidationAmounts);
                }

                if (word == 0) {
                    tickBitmap[wPos] = 0;
                } else {
                    tickBitmap[wPos] &= type(uint256).max >> (256 - minBitPos);
                }

                // TODO: ensure wPos can not underflow, this could require ticks to start at 256
                wPos--;
            }
        }

        if (liquidationAmounts.collateralLiquidated == 0) {
            return (0, 0);
        }

        if (liquidationAmounts.remainingFactoredLoans > 0) {
            uint16 newMaxWordIndex = uint16(liquidatingTick >> 8);
            while (tickBitmap[newMaxWordIndex] == 0) {
                newMaxWordIndex--;
            }
            maxTickWordIndex = newMaxWordIndex;
        }

        uint256 currencyLiquidated;
        uint256 altcoinLiquidated;
        {
            uint256 liquidatedLoans =
                Factoring.unfactorUp(liquidationAmounts.factoredLoansLiquidated(), reservesChange.interestFactor);
            totalFactoredLoans = liquidationAmounts.remainingFactoredLoans;

            (currencyLiquidated, altcoinLiquidated) =
                _moveLiquidationAssets(reservesChange, liquidationAmounts.collateralLiquidated, liquidatedLoans);
        }

        uint80 key = (uint80(reservesChange.blockNumber) << 48) + (uint48(topTick) << 24) + liquidatingTick;
        _liquidations[key] = (currencyLiquidated << 128) + altcoinLiquidated;

        emit Liquidation(reservesChange.blockNumber, topTick, liquidatingTick, currencyLiquidated, altcoinLiquidated);

        // TODO: ensure no overflows, consider moving cast elsewhere
        return (uint112(currencyLiquidated), uint112(altcoinLiquidated));
    }

    function _moveLiquidationAssets(
        LiquidationMath.ReservesChange memory reservesChange,
        uint256 collateralLiquidated,
        uint256 liquidatedLoans
    ) private returns (uint256 pairCurrency, uint256 pairAltcoin) {
        uint256 maxLiquidationReward = LiquidationMath.getAmountOut(
            collateralLiquidated, reservesChange.altcoinReserve, reservesChange.currencyReserve
        );

        if (maxLiquidationReward <= liquidatedLoans) {
            pairCurrency = maxLiquidationReward;
            pairAltcoin = collateralLiquidated;
        } else {
            pairCurrency = liquidatedLoans;
            pairAltcoin =
                LiquidationMath.getAmountIn(pairCurrency, reservesChange.altcoinReserve, reservesChange.currencyReserve);
        }

        // TODO: avoid locking through excessive altcoin amount
        if (pairAltcoin + reservesChange.altcoinReserve > type(uint112).max) revert ExcessiveAltcoinAmount();

        SafeERC20.safeTransfer(IERC20(altcoin), address(pair), pairAltcoin);
        if (collateralLiquidated > pairAltcoin) {
            totalClaimableCollateral += collateralLiquidated - pairAltcoin;
        }

        // TODO: consider getting rid of the cast to uint112
        IHoyuPair(pair).payForLiquidation(uint112(pairCurrency), uint112(pairAltcoin), reservesChange.blockNumber);
    }

    // TODO: save intermediate values
    // TODO: save for varying interest rate
    function _interestFactor() private view returns (uint256) {
        return Factoring.interestFactorAt(block.number);
    }

    function _addLoan(uint256 factoredLoan, uint256 collateral, address borrower) private returns (uint24 tick) {
        // TODO: consider removing the factoredLoan == 0 condition
        // TODO: require(value <= type(uint32).max);
        if (collateral == 0 && factoredLoan > 0) revert InsufficientCollateralization();

        tick = _loanTick(factoredLoan, collateral);

        _activateTick(tick, totalFactoredLoans == 0);

        tickFactoredLoans[tick] += factoredLoan;
        tickCollateral[tick] += collateral;

        totalFactoredLoans += factoredLoan;
        _factoredLoanOf[borrower] = factoredLoan;
        _userLoanBlock[borrower] = uint32(block.number);
        _userLoanTick[borrower] = tick;
    }

    function _removeLoan(uint256 removedFactoredLoan, uint256 unlockedCollateral, address borrower) private {
        uint24 tick = _loanTick(removedFactoredLoan, unlockedCollateral);

        tickFactoredLoans[tick] -= removedFactoredLoan;
        tickCollateral[tick] -= unlockedCollateral;
        totalFactoredLoans -= removedFactoredLoan;
        _factoredLoanOf[borrower] = 0;
        _userLoanBlock[borrower] = 0;
        _userLoanTick[borrower] = 0;

        _deactivateTick(tick);
    }

    function _adjustLoan(
        address borrower,
        uint256 factoredOwedPrior,
        uint256 collateralPrior,
        uint256 factoredOwed,
        uint256 collateral
    ) private returns (uint24 tick) {
        // TODO: require(value <= type(uint32).max);
        if (collateral == 0) revert InsufficientCollateralization();

        if (factoredOwedPrior != factoredOwed) {
            totalFactoredLoans = totalFactoredLoans - factoredOwedPrior + factoredOwed;
            _factoredLoanOf[borrower] = factoredOwed;
            _userLoanBlock[borrower] = uint32(block.number);
        }

        uint24 oldTick = _loanTick(factoredOwedPrior, collateralPrior);
        tick = _loanTick(factoredOwed, collateral);

        if (oldTick == tick) {
            if (factoredOwedPrior != factoredOwed) {
                tickFactoredLoans[oldTick] = tickFactoredLoans[oldTick] - factoredOwedPrior + factoredOwed;
            }
            if (collateralPrior != collateral) {
                tickCollateral[oldTick] = tickCollateral[oldTick] - collateralPrior + collateral;
            }
            return tick;
        }

        tickFactoredLoans[oldTick] -= factoredOwedPrior;
        tickCollateral[oldTick] -= collateralPrior;

        _activateTick(tick, false);
        _deactivateTick(oldTick);

        tickFactoredLoans[tick] += factoredOwed;
        tickCollateral[tick] += collateral;

        _userLoanTick[borrower] = tick;
    }

    function _loanTick(uint256 factoredLoan, uint256 collateral) private pure returns (uint24) {
        uint256 factoredPrice = Math.ceilDiv(factoredLoan, collateral);
        return LiquidationMath.priceTick(factoredPrice) + LOAN_COLLATERALIZATION_TICK_OFFSET;
    }

    function _reservesTick(
        uint256 currencyReserve,
        uint256 altcoinReserve,
        uint256 interestFactor
    ) private pure returns (uint24) {
        uint256 reservesPrice = Q96Math.div(currencyReserve, altcoinReserve);
        uint256 factoredReservesPrice = Q96Math.div(reservesPrice, interestFactor);
        return LiquidationMath.priceTick(factoredReservesPrice);
    }

    function _verifyLoanHealthy(uint24 tick, uint256 interestFactor, bool verifyVaultHealth) private view {
        (uint112 currencyReserve, uint112 altcoinReserve,) = IHoyuPair(pair).getReserves();

        if (verifyVaultHealth) {
            uint256 totalLoans_ = Factoring.unfactorUp(totalFactoredLoans, interestFactor);
            if (totalLoans_ > BORROW_LIMIT_PER_MIL * currencyReserve / 1000) {
                revert ExcessBorrowAmount();
            }
        }

        uint24 reservesTick = _reservesTick(currencyReserve, altcoinReserve, interestFactor);
        if (tick >= reservesTick) revert InsufficientCollateralization();
    }

    function _positionToTick(uint16 wordPos, uint8 bitPos) private pure returns (uint24 tick) {
        tick = (uint24(wordPos) << 8) + bitPos;
    }

    function _activateTick(uint24 tick, bool firstLoan) private {
        (uint16 word, uint8 bit) = LiquidationMath.tickToPosition(tick);

        bool tickWasActive = ((tickBitmap[word] >> bit) & 1) == 1;

        if (tickWasActive) {
            return;
        }

        if (uint32(_tickLiquidations[tick]) >= block.number) revert LiquidationOnSameBlock();

        tickFactoredLoans[tick] = 0;
        tickCollateral[tick] = 0;

        tickBitmap[word] ^= (1 << (bit));

        if (firstLoan || maxTickWordIndex < word) {
            maxTickWordIndex = word;
        }
    }

    function _deactivateTick(uint24 tick) private {
        if (tickFactoredLoans[tick] > 0) return;

        (uint16 word, uint8 bit) = LiquidationMath.tickToPosition(tick);

        tickBitmap[word] &= ~(1 << (bit));

        // no need to reevaluate maxTickWordIndex if there are no more loans
        if (totalFactoredLoans == 0) return;

        if (word == maxTickWordIndex && tickBitmap[word] == 0) {
            uint16 newMaxWordIndex = maxTickWordIndex - 1;
            while (tickBitmap[newMaxWordIndex] == 0) {
                newMaxWordIndex--;
            }
            maxTickWordIndex = newMaxWordIndex;
        }
    }

    function _clearLiquidatedLoan(address account) private {
        _collateralOf[account] = 0;
        _factoredLoanOf[account] = 0;
        _userLoanTick[account] = 0;
        _userLoanBlock[account] = 0;
    }
}
