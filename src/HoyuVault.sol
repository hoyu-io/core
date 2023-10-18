// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96Math} from "src/libraries/Q96Math.sol";
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

// TODO: keep only needed properties and update code to actually update and use them
struct TickData {
    bool hasActiveTicks;
    uint16 minTickWord;
    uint8 minTickBit;
    uint24 minTick;
    uint16 maxTickWord;
    uint8 maxTickBit;
    uint24 maxTick;
    mapping(uint16 => uint256) tickBitmap;
}

contract HoyuVault is ERC4626, IHoyuVault {
    using LiquidationMath for LiquidationMath.ReservesChange;
    using LiquidatedAmounts for LiquidatedAmounts.Amounts;

    // TODO: change from 20% yearly interest to something more reasonable
    uint256 public constant BLOCK_INTEREST_RATE = 79228168007078404159181067972; // ~1.00000007
    // TODO: change to a logical value eventually, currently roughly 1 day worth of interest at 20% yearly interest
    uint256 public constant IMMEDIATE_INTEREST_RATE = 79267720646452247531225451463; // ~1.0005
    uint256 public constant MINIMUM_SHARES = 10 ** 3;
    uint256 public constant BORROW_LIMIT_PER_MIL = 70;
    uint24 public constant LOAN_COLLATERALIZATION_TICK_OFFSET = 954; // 110% collateralization

    address public immutable factory;
    address public immutable altcoin;
    address public pair;

    TickData private _tickData;

    uint256 private _totalFactoredLoans;
    mapping(address => uint256) private _collateralOf;
    mapping(address => uint256) private _factoredLoanOf;
    mapping(address => uint256) private _userLoanBlock;
    mapping(address => uint24) private _userLoanTick;

    mapping(uint24 => uint256) private _tickFactoredLoans;
    mapping(uint24 => uint256) private _tickCollateral;
    mapping(uint24 => uint256) private _lastTickLiquidation;

    // TODO: processBurns on all necessary ERC4626 functions
    // TODO: emulate processBurns on all necessary ERC4626 view functions
    modifier processBurns() {
        IHoyuPair(pair).processBurnUntilBlock(block.number);
        _;
    }

    modifier clearLiquidatedLoan(address account) {
        uint256 factoredLoan = _factoredLoanOf[account];
        if (factoredLoan > 0) {
            uint24 loanTick = _userLoanTick[account];
            uint256 tickLastLiquidated = _lastTickLiquidation[loanTick];
            if (tickLastLiquidated >= _userLoanBlock[account]) {
                _collateralOf[account] = 0;
                _factoredLoanOf[account] = 0;
            }
        }
        _;
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
        if (collateral == 0) {
            return 0;
        }

        uint256 factoredLoan = _factoredLoanOf[borrower];
        if (factoredLoan > 0) {
            uint24 tick = _userLoanTick[borrower];
            uint256 tickLastLiquidated = _lastTickLiquidation[tick];
            if (tickLastLiquidated >= _userLoanBlock[borrower]) {
                return 0;
            }
        }

        return collateral;
    }

    function loanOf(address borrower) external view returns (uint256) {
        if (isLiquidated(borrower)) {
            return 0;
        }

        uint256 factoredLoan = _factoredLoanOf[borrower];
        if (factoredLoan == 0) return 0;

        return Q96Math.asUintCeil(Q96Math.mul(_factoredLoanOf[borrower], _interestFactor()));
    }

    function isLiquidated(address borrower) public view returns (bool) {
        uint256 factoredLoan = _factoredLoanOf[borrower];
        if (factoredLoan == 0) {
            return false;
        }

        uint24 tick = _userLoanTick[borrower];
        uint256 tickLastLiquidated = _lastTickLiquidation[tick];
        if (tickLastLiquidated >= _userLoanBlock[borrower]) {
            return true;
        }

        return false;
    }

    function totalLoans() public view returns (uint256) {
        return Q96Math.asUintCeil(Q96Math.mul(_totalFactoredLoans, _interestFactor()));
    }

    // TODO: verify overrides are correct
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 loanedValue = Q96Math.asUintCeil(Q96Math.mul(_totalFactoredLoans, _interestFactor()));
        return IERC20(asset()).balanceOf(address(this)) + loanedValue;
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
        uint256 redeemableShares = _convertToShares(availableAssets, Math.Rounding.Down);
        if (redeemableShares < shares) {
            shares = redeemableShares;
        }
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626, IERC4626) processBurns returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) processBurns returns (uint256) {
        return super.mint(shares, receiver);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override(ERC4626, IERC4626) processBurns returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override(ERC4626, IERC4626) processBurns returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function _initialConvertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        if (assets <= MINIMUM_SHARES) revert InsufficientAssets();
        return assets - MINIMUM_SHARES;
    }

    function _initialConvertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        if (shares == 0) revert InsufficientShares();
        return shares + MINIMUM_SHARES;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        bool firstDeposit = totalSupply() == 0;
        super._deposit(caller, receiver, assets, shares);
        if (firstDeposit) {
            _mint(address(0xdead), MINIMUM_SHARES);
        }
    }

    // TODO: possibly want to limit the total amount of collateral deposited, so as not to exeed 112 bit reserve limit after liquidation
    function depositCollateral(uint256 amount, address to) external processBurns clearLiquidatedLoan(to) {
        SafeERC20.safeTransferFrom(IERC20(altcoin), msg.sender, address(this), amount);

        uint256 collateralPrior = _collateralOf[to];
        uint256 collateral = collateralPrior + amount;

        uint256 factoredOwed = _factoredLoanOf[to];
        if (factoredOwed > 0) {
            _removeLoan(factoredOwed, collateralPrior, to);
            uint24 tick = _addLoan(factoredOwed, collateral, to);
            uint256 interestFactor = _interestFactor();
            // TODO: _verifyLoanHealty is likely not needed here, to be confirmed
            _verifyLoanHealty(tick, interestFactor, false);
            // TODO: emit loan change event
        }

        _collateralOf[to] = collateral;

        emit CollateralDeposit(_msgSender(), to, amount);
    }

    function withdrawCollateral(uint256 amount, address to) external processBurns clearLiquidatedLoan(_msgSender()) {
        uint256 collateralPrior = _collateralOf[_msgSender()];
        if (collateralPrior < amount) revert InsufficientCollateral();

        uint256 collateral = collateralPrior - amount;

        uint256 factoredOwed = _factoredLoanOf[_msgSender()];
        if (factoredOwed > 0) {
            _removeLoan(factoredOwed, collateralPrior, _msgSender());
            uint24 tick = _addLoan(factoredOwed, collateral, _msgSender());
            uint256 interestFactor = _interestFactor();
            _verifyLoanHealty(tick, interestFactor, false);
            // TODO: emit loan change event
        }

        _collateralOf[_msgSender()] = collateral;

        SafeERC20.safeTransfer(IERC20(altcoin), to, amount);

        emit CollateralWithdraw(_msgSender(), to, amount, _collateralOf[_msgSender()]);
    }

    function takeOutLoan(uint256 amount, address to) external processBurns clearLiquidatedLoan(_msgSender()) {
        if (amount == 0) revert InsufficientLoan();
        if (IERC20(asset()).balanceOf(address(this)) < amount) revert InsufficientCurrency();

        SafeERC20.safeTransfer(IERC20(asset()), to, amount);

        uint256 owed = amount * IMMEDIATE_INTEREST_RATE;
        uint256 interestFactor = _interestFactor();
        uint256 factoredOwed = Q96Math.ceilDiv(owed, interestFactor);
        uint256 collateral = _collateralOf[_msgSender()];

        uint256 factoredOwedPrior = _factoredLoanOf[_msgSender()];
        if (factoredOwedPrior > 0) {
            _removeLoan(factoredOwedPrior, collateral, _msgSender());
            factoredOwed += factoredOwedPrior;
            // TODO: emit event reflecting loan change
        }

        uint24 tick = _addLoan(factoredOwed, collateral, _msgSender());
        _verifyLoanHealty(tick, interestFactor, true);

        emit TakeOutLoan(_msgSender(), to, amount, Q96Math.asUintCeil(_q96LoanOf(_msgSender(), interestFactor)));
    }

    function repayLoan(uint256 amount, address to) external processBurns clearLiquidatedLoan(to) {
        uint256 factoredOwedPrior = _factoredLoanOf[to];
        if (factoredOwedPrior == 0) revert NoLoan();

        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), amount);

        uint256 interestFactor = _interestFactor();
        uint256 factoredRepayAmount = Q96Math.div(Q96Math.asQ96(uint160(amount)), interestFactor);
        uint256 collateral = _collateralOf[to];

        _removeLoan(factoredOwedPrior, collateral, to);

        if (factoredOwedPrior > factoredRepayAmount) {
            uint256 factoredRemainingOwed = factoredOwedPrior - factoredRepayAmount;
            _addLoan(factoredRemainingOwed, collateral, to);
            // any unhealthy loans should have already been liquidated, repaying loans can only cause a healthier state than before - no additional health check needed
            // TODO: emit loan change event
        }

        emit RepayLoan(_msgSender(), to, amount, Q96Math.asUintCeil(_q96LoanOf(to, interestFactor)));
    }

    // TODO: consider checking if blockNumber is valid
    function liquidateLoansByOffset(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        int256 currencyAmountInOut,
        int256 altcoinAmountInOut,
        uint256 blockNumber
    ) external returns (uint256, uint256) {
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
            _interestFactorAt(blockNumber)
        );

        return _liquidateLoans(reservesChange);
    }

    // TODO: consider checking if blockNumber is valid
    function liquidateLoansByFraction(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        uint256 fractionOut,
        uint256 blockNumber
    ) external returns (uint256, uint256) {
        if (_msgSender() != pair) revert CallerNotPair();

        if (currencyReserve == 0 || altcoinReserve == 0) {
            return (0, 0);
        }

        LiquidationMath.ReservesChange memory reservesChange = LiquidationMath.ReservesChange(
            currencyReserve, altcoinReserve, 0, 0, fractionOut, blockNumber, _interestFactorAt(blockNumber)
        );

        return _liquidateLoans(reservesChange);
    }

    function _liquidateLoans(LiquidationMath.ReservesChange memory reservesChange) private returns (uint256, uint256) {
        // TODO: use _tickData.hasActiveTicks to exit early if no active ticks
        (uint16 minWordPos, uint8 minBitPos, uint256 factoredLoanLimit) = reservesChange.getLiquidationThresholds();

        LiquidatedAmounts.Amounts memory liquidationAmounts = LiquidatedAmounts.create(_totalFactoredLoans);

        uint16 wPos = _tickData.maxTickWord;
        while (wPos >= minWordPos || liquidationAmounts.remainingFactoredLoans > factoredLoanLimit) {
            uint256 word = _tickData.tickBitmap[wPos];
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

                uint24 liquidatingTick = _positionToTick(wPos, bPos);
                _lastTickLiquidation[liquidatingTick] = reservesChange.blockNumber;
                liquidationAmounts.liquidate(_tickFactoredLoans[liquidatingTick], _tickCollateral[liquidatingTick]);
                bShift += 256 - msb;
                word <<= 256 - msb;
            }

            if (wPos <= minWordPos && word == 0 && liquidationAmounts.remainingFactoredLoans <= factoredLoanLimit) {
                // reevaluate liquidation end tick if current word is fully liquidated
                (minWordPos, minBitPos, factoredLoanLimit) =
                    reservesChange.postLiquidationThresholds(liquidationAmounts);
            }

            if (word == 0) {
                _tickData.tickBitmap[wPos] = 0;
            } else {
                uint256 mask = type(uint256).max;
                mask >>= 256 - minBitPos; // check
                _tickData.tickBitmap[wPos] &= mask;
            }

            // TODO: ensure wPos can not underflow, this could require ticks to start at 256
            wPos--;
            // TODO: optionally use _tickData.minTickWord to exit early
        }

        if (liquidationAmounts.collateralLiquidated == 0) {
            return (0, 0);
        }

        // TODO: reset _tickData.maxTickWord and maybe _tickData.hasActiveTicks

        uint256 liquidatedLoans =
            Q96Math.asUintCeil(Q96Math.mul(liquidationAmounts.factoredLoansLiquidated(), reservesChange.interestFactor));
        _totalFactoredLoans = liquidationAmounts.remainingFactoredLoans;

        return _moveLiquidationAssets(
            reservesChange.currencyReserve,
            reservesChange.altcoinReserve,
            liquidationAmounts.collateralLiquidated,
            liquidatedLoans
        );
    }

    // TODO: emit event
    function _moveLiquidationAssets(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        uint256 collateralLiquidated,
        uint256 liquidatedLoans
    ) private returns (uint256 pairCurrency, uint256 pairAltcoin) {
        uint256 maxLiquidationReward =
            LiquidationMath.getAmountOut(collateralLiquidated, altcoinReserve, currencyReserve);

        if (maxLiquidationReward <= liquidatedLoans) {
            pairCurrency = maxLiquidationReward;
            pairAltcoin = collateralLiquidated;
        } else {
            pairCurrency = liquidatedLoans;
            pairAltcoin = LiquidationMath.getAmountIn(pairCurrency, altcoinReserve, currencyReserve);
        }

        // TODO: avoid locking through excessive altcoin amount
        if (pairAltcoin + altcoinReserve > type(uint112).max) revert ExcessiveAltcoinAmount();

        SafeERC20.safeTransfer(IERC20(altcoin), address(pair), pairAltcoin);
        if (collateralLiquidated > pairAltcoin) {
            SafeERC20.safeTransfer(IERC20(altcoin), IHoyuFactory(factory).feeTo(), collateralLiquidated - pairAltcoin);
        }

        // TODO: consider getting rid of the cast to uint112
        IHoyuPair(pair).payForLiquidation(uint112(pairCurrency));
    }

    // TODO: save intermediate values
    // TODO: save for varying interest rate
    function _interestFactor() private view returns (uint256) {
        return _interestFactorAt(block.number);
    }

    function _interestFactorAt(uint256 blockNumber) private pure returns (uint256 interestFactor) {
        interestFactor = Q96Math.pow(BLOCK_INTEREST_RATE, blockNumber);
    }

    function _q96LoanOf(address borrower, uint256 interestFactor) private view returns (uint256) {
        return Q96Math.mul(_factoredLoanOf[borrower], interestFactor);
    }

    function _addLoan(uint256 factoredLoan, uint256 collateral, address borrower) private returns (uint24 tick) {
        // TODO: consider removing the factoredLoan == 0 condition
        if (collateral == 0 && factoredLoan > 0) revert InsufficientCollateralization();

        tick = _loanTick(factoredLoan, collateral);

        _activateTick(tick);

        _tickFactoredLoans[tick] += factoredLoan;
        _tickCollateral[tick] += collateral;

        _totalFactoredLoans += factoredLoan;
        _factoredLoanOf[borrower] = factoredLoan;
        _userLoanBlock[borrower] = block.number;
        _userLoanTick[borrower] = tick;
    }

    function _removeLoan(uint256 removedFactoredLoan, uint256 unlockedCollateral, address borrower) private {
        uint24 tick = _loanTick(removedFactoredLoan, unlockedCollateral);

        _tickFactoredLoans[tick] -= removedFactoredLoan;
        _tickCollateral[tick] -= unlockedCollateral;
        _totalFactoredLoans -= removedFactoredLoan;
        _factoredLoanOf[borrower] = 0;
    }

    function _loanTick(uint256 factoredLoan, uint256 collateral) private pure returns (uint24) {
        uint256 factoredPrice = Math.ceilDiv(factoredLoan, collateral);
        return LiquidationMath.priceTick(factoredPrice) + LOAN_COLLATERALIZATION_TICK_OFFSET;
    }

    function _verifyLoanHealty(uint24 tick, uint256 interestFactor, bool verifyVaultHealth) private view {
        (uint112 currencyReserve, uint112 altcoinReserve,) = IHoyuPair(pair).getReserves();

        if (verifyVaultHealth) {
            uint256 totalLoans_ = Q96Math.mul(_totalFactoredLoans, interestFactor, Math.Rounding.Up);
            if (Q96Math.asUintCeil(totalLoans_) > BORROW_LIMIT_PER_MIL * currencyReserve / 1000) {
                revert ExcessBorrowAmount();
            }
        }

        uint256 reservesPrice = Q96Math.div(currencyReserve, altcoinReserve);
        uint256 factoredReservesPrice = Q96Math.div(reservesPrice, interestFactor);
        uint24 reservesTick = LiquidationMath.priceTick(factoredReservesPrice);
        if (tick >= reservesTick) revert InsufficientCollateralization();
    }

    function _positionToTick(uint16 wordPos, uint8 bitPos) private pure returns (uint24 tick) {
        tick = (uint24(wordPos) << 8) + bitPos;
    }

    function _activateTick(uint24 tick) private {
        (uint16 wordPos, uint8 bitPos) = LiquidationMath.tickToPosition(tick);

        bool tickWasActive = ((_tickData.tickBitmap[wordPos] >> bitPos) & 1) == 1;

        if (tickWasActive) {
            return;
        }

        if (_lastTickLiquidation[tick] >= block.number) revert LiquidationOnSameBlock();

        if (!_tickData.hasActiveTicks) {
            _tickData.hasActiveTicks = true;
            _tickData.minTick = tick;
            _tickData.minTickWord = wordPos;
            _tickData.minTickBit = bitPos;
            _tickData.maxTick = tick;
            _tickData.maxTickWord = wordPos;
            _tickData.maxTickBit = bitPos;
        } else {
            if (_tickData.minTick > tick) {
                _tickData.minTick = tick;
                _tickData.minTickWord = wordPos;
                _tickData.minTickBit = bitPos;
            }
            if (_tickData.maxTick < tick) {
                _tickData.maxTick = tick;
                _tickData.maxTickWord = wordPos;
                _tickData.maxTickBit = bitPos;
            }
        }

        uint256 mask = 1 << bitPos;
        _tickData.tickBitmap[wordPos] ^= mask;
    }
}
