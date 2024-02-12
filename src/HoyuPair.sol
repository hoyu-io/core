// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.21;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Q96} from "./libraries/Q96.sol";
import {IntMath} from "./libraries/IntMath.sol";
import {SwapMath} from "./libraries/SwapMath.sol";
import {timestamp as ts} from "./utils/Timestamp.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {HoyuBurnRewardStore} from "./HoyuBurnRewardStore.sol";
import {IHoyuPair} from "./interfaces/IHoyuPair.sol";
import {IHoyuVault} from "./interfaces/IHoyuVault.sol";
import {IUniswapV2Callee} from "./interfaces/IUniswapV2Callee.sol";

contract HoyuPair is ERC20, IHoyuPair, ReentrancyGuard {
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3 * 2 ** 16;
    uint256 public constant LP_MULTIPLIER = 2 ** 32;
    uint8 public constant BURN_INTERVALS = 14;
    uint16 public constant BURN_INTERVAL_LENGTH = 12 hours;
    uint16 public constant VIRTUAL_OFFSETS_DECAY_TIME = 1 hours;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    address public immutable vault;
    address public immutable burnRewardStore;

    uint112 private _currencyReserve;
    uint112 private _altcoinReserve;
    uint32 private _reserveTimestampLast;

    uint112 private _virtualCurrencyOffset;
    uint112 private _virtualAltcoinOffset;
    uint32 private _virtualOffsetTimestamp;

    uint32 public burnsProcessedUntil;
    uint256 public burnReserve;
    uint256 public totalBurnRate;

    mapping(uint32 => uint256) public burnRateEndingAt;
    mapping(address => uint32) public userBurnExpiry;
    mapping(address => uint256) public userBurnRate;

    uint256 private _currencyRewardFactor;
    uint256 private _altcoinRewardFactor;
    mapping(uint32 => uint256) private _currencyRewardFactorAt;
    mapping(uint32 => uint256) private _altcoinRewardFactorAt;
    mapping(address => uint256) private _userBurnStartCurrencyRewardFactor;
    mapping(address => uint256) private _userBurnStartAltcoinRewardFactor;

    modifier processBurns() {
        _processBurnUntil(ts());
        _;
    }

    modifier onlyVault() {
        if (_msgSender() != vault) revert CallerNotVault();
        _;
    }

    constructor(address currency, address altcoin, address vault_, address factory_) ERC20("Hoyu Dex", "HOYD") {
        token0 = currency;
        token1 = altcoin;
        vault = vault_;
        factory = factory_;
        burnRewardStore = address(new HoyuBurnRewardStore(currency, altcoin));
    }

    function mint(address to) external nonReentrant processBurns returns (uint256 liquidity) {
        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        uint256 currencyBalance = _currencyBalance();
        uint256 altcoinBalance = _altcoinBalance();
        uint256 currencyAmount = currencyBalance - currencyReserve;
        uint256 altcoinAmount = altcoinBalance - altcoinReserve;

        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            liquidity = Math.sqrt(currencyAmount * altcoinAmount * LP_MULTIPLIER) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity =
                Math.min(currencyAmount * totalSupply_ / currencyReserve, altcoinAmount * totalSupply_ / altcoinReserve);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(currencyBalance, altcoinBalance, ts());
        emit Mint(_msgSender(), currencyAmount, altcoinAmount);
    }

    function burn(address to) external nonReentrant processBurns {
        if (userBurnExpiry[to] > ts()) revert BurnAlreadyActive();

        uint32 burnEnd = (ts() / BURN_INTERVAL_LENGTH + BURN_INTERVALS) * BURN_INTERVAL_LENGTH;
        uint32 burnDuration = burnEnd - ts();
        uint256 burnRate = (balanceOf(address(this)) - burnReserve) / burnDuration;

        if (burnRate == 0) revert InsufficientBurnRate();

        userBurnExpiry[to] = burnEnd;
        userBurnRate[to] = burnRate;
        _userBurnStartCurrencyRewardFactor[to] = _currencyRewardFactor;
        _userBurnStartAltcoinRewardFactor[to] = _altcoinRewardFactor;

        burnRateEndingAt[burnEnd] += burnRate;
        totalBurnRate += burnRate;
        burnReserve += burnRate * burnDuration;

        emit Burn(_msgSender(), to, burnRate, burnEnd);
    }

    function cancelBurn(address to) external nonReentrant processBurns {
        uint32 burnEnd = userBurnExpiry[_msgSender()];

        if (burnEnd <= ts()) revert NoActiveBurn();

        uint256 burnRate = userBurnRate[_msgSender()];
        uint256 unburnedTokens = (burnEnd - ts()) * burnRate;

        burnReserve -= unburnedTokens;
        totalBurnRate -= burnRate;
        burnRateEndingAt[burnEnd] -= burnRate;
        userBurnExpiry[_msgSender()] = ts();

        _transfer(address(this), to, unburnedTokens);

        emit BurnCanceled(_msgSender(), to, unburnedTokens);
    }

    function processBurnUntil(uint32 timestamp) public nonReentrant {
        _processBurnUntil(timestamp);
    }

    function _processBurnUntil(uint32 toTimestamp) private {
        if (toTimestamp > ts()) revert FutureTime();

        uint32 fromTimestamp = burnsProcessedUntil;
        if (fromTimestamp >= toTimestamp) {
            return;
        }

        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        uint256 currencyBurned = 0;
        uint256 altcoinBurned = 0;

        uint32 nextIntervalExpiry = (fromTimestamp / BURN_INTERVAL_LENGTH + 1) * BURN_INTERVAL_LENGTH;

        while (nextIntervalExpiry < toTimestamp && totalBurnRate > 0) {
            if (burnRateEndingAt[nextIntervalExpiry] > 0) {
                uint256 intervalCurrencyBurned;
                uint256 intervalAltcoinBurned;
                (currencyReserve, altcoinReserve, intervalCurrencyBurned, intervalAltcoinBurned) =
                    _executeBurns(fromTimestamp, nextIntervalExpiry, currencyReserve, altcoinReserve);
                currencyBurned += intervalCurrencyBurned;
                altcoinBurned += intervalAltcoinBurned;
                fromTimestamp = nextIntervalExpiry;
            }

            nextIntervalExpiry += BURN_INTERVAL_LENGTH;
        }

        if (totalBurnRate > 0) {
            uint256 intervalCurrencyBurned;
            uint256 intervalAltcoinBurned;
            (currencyReserve, altcoinReserve, intervalCurrencyBurned, intervalAltcoinBurned) =
                _executeBurns(fromTimestamp, toTimestamp, currencyReserve, altcoinReserve);
            currencyBurned += intervalCurrencyBurned;
            altcoinBurned += intervalAltcoinBurned;
            _update(currencyReserve, altcoinReserve, toTimestamp);
        } else {
            (uint112 currencyLiquidated, uint112 altcoinLiquidated) =
                _liquidateByOffset(currencyReserve, altcoinReserve, 0, 0, toTimestamp);
            if (currencyLiquidated > 0 || altcoinLiquidated > 0 || currencyBurned > 0 || altcoinBurned > 0) {
                _update(currencyReserve - currencyLiquidated, altcoinReserve + altcoinLiquidated, toTimestamp);
            }
        }

        if (currencyBurned > 0) SafeERC20.safeTransfer(IERC20(token0), burnRewardStore, currencyBurned);
        if (altcoinBurned > 0) SafeERC20.safeTransfer(IERC20(token1), burnRewardStore, altcoinBurned);

        burnsProcessedUntil = toTimestamp;
    }

    function withdrawBurnProceeds(address to)
        external
        nonReentrant
        processBurns
        returns (uint256 currencyAmount, uint256 altcoinAmount)
    {
        uint256 burnRate = userBurnRate[_msgSender()];

        if (burnRate == 0) {
            return (0, 0);
        }

        uint32 burnEnd = userBurnExpiry[_msgSender()];
        bool burnFullyCompleted = burnEnd <= ts();
        if (!burnFullyCompleted) {
            burnEnd = ts();
        }

        currencyAmount = Math.mulDiv(
            _currencyRewardFactorAt[burnEnd] - _userBurnStartCurrencyRewardFactor[_msgSender()], burnRate, Q96.ONE
        );
        altcoinAmount = Math.mulDiv(
            _altcoinRewardFactorAt[burnEnd] - _userBurnStartAltcoinRewardFactor[_msgSender()], burnRate, Q96.ONE
        );

        if (burnFullyCompleted) {
            userBurnRate[_msgSender()] = 0;
        } else {
            _userBurnStartCurrencyRewardFactor[_msgSender()] = _currencyRewardFactorAt[burnEnd];
            _userBurnStartAltcoinRewardFactor[_msgSender()] = _altcoinRewardFactorAt[burnEnd];
        }

        HoyuBurnRewardStore(burnRewardStore).payOutRewards(currencyAmount, altcoinAmount, to);
    }

    function swap(
        uint256 currencyAmountOut,
        uint256 altcoinAmountOut,
        address to,
        bytes calldata data
    ) external nonReentrant processBurns {
        if (currencyAmountOut == 0 && altcoinAmountOut == 0) revert InsufficientOutputAmount();
        if (currencyAmountOut > 0 && altcoinAmountOut > 0) revert MultiOutputSwap();
        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        if (currencyAmountOut >= currencyReserve || altcoinAmountOut >= altcoinReserve) revert InsufficientLiquidity();
        if (to == token0 || to == token1) revert InvalidRecipient();

        if (currencyAmountOut > 0) {
            SafeERC20.safeTransfer(IERC20(token0), to, currencyAmountOut);
        }
        if (altcoinAmountOut > 0) {
            SafeERC20.safeTransfer(IERC20(token1), to, altcoinAmountOut);
        }

        if (data.length > 0) {
            IUniswapV2Callee(to).uniswapV2Call(_msgSender(), currencyAmountOut, altcoinAmountOut, data);
        }

        uint256 currencyBalance = _currencyBalance();
        uint256 altcoinBalance = _altcoinBalance();

        uint256 currencyAmountIn = currencyBalance > currencyReserve - currencyAmountOut
            ? currencyBalance - (currencyReserve - currencyAmountOut)
            : 0;
        uint256 altcoinAmountIn = altcoinBalance > altcoinReserve - altcoinAmountOut
            ? altcoinBalance - (altcoinReserve - altcoinAmountOut)
            : 0;
        if (currencyAmountIn == 0 && altcoinAmountIn == 0) revert InsufficientInputAmount();

        {
            int256 currencyAmountInOut = IntMath.sub(currencyAmountIn, currencyAmountOut);
            int256 altcoinAmountInOut = IntMath.sub(altcoinAmountIn, altcoinAmountOut);
            (uint112 currencyLiquidated, uint112 altcoinLiquidated) =
                _liquidateByOffset(currencyReserve, altcoinReserve, currencyAmountInOut, altcoinAmountInOut, ts());

            if (currencyLiquidated > 0) {
                currencyReserve -= currencyLiquidated;
                altcoinReserve += altcoinLiquidated;
                currencyBalance -= currencyLiquidated;
                altcoinBalance += altcoinLiquidated;
            }
        }

        {
            (uint256 currencyOffset, uint256 altcoinOffset) =
                altcoinAmountOut > 0 ? _effectiveVirtualOffsets(ts()) : (0, 0);
            uint256 currencyBalanceAdjusted =
                (currencyBalance + currencyOffset) * 1000 - currencyAmountIn * SwapMath.SWAP_FEE_PER_MIL;
            uint256 altcoinBalanceAdjusted =
                (altcoinBalance - altcoinOffset) * 1000 - altcoinAmountIn * SwapMath.SWAP_FEE_PER_MIL;
            if (
                currencyBalanceAdjusted * altcoinBalanceAdjusted
                    < (currencyReserve + currencyOffset) * (altcoinReserve - altcoinOffset) * 1000 ** 2
            ) revert HoyuK();
        }

        _update(currencyBalance, altcoinBalance, ts());

        emit Swap(_msgSender(), currencyAmountIn, altcoinAmountIn, currencyAmountOut, altcoinAmountOut, to);
    }

    function _effectiveVirtualOffsets(uint32 timestamp) private view returns (uint112, uint112) {
        uint32 timeSinceLastLiquidation = timestamp - _virtualOffsetTimestamp;
        if (timeSinceLastLiquidation >= VIRTUAL_OFFSETS_DECAY_TIME) return (0, 0);

        uint32 remainingTime = VIRTUAL_OFFSETS_DECAY_TIME - timeSinceLastLiquidation;
        uint256 remainingCurrencyOffset =
            Math.mulDiv(_virtualCurrencyOffset, remainingTime, VIRTUAL_OFFSETS_DECAY_TIME, Math.Rounding.Ceil);
        uint256 remainingAltcoinOffset =
            Math.mulDiv(_virtualAltcoinOffset, remainingTime, VIRTUAL_OFFSETS_DECAY_TIME, Math.Rounding.Ceil);

        return (uint112(remainingCurrencyOffset), uint112(remainingAltcoinOffset));
    }

    function skim(address to) external nonReentrant processBurns {
        address token0_ = token0; // gas savings
        address token1_ = token1; // gas savings
        SafeERC20.safeTransfer(IERC20(token0_), to, _currencyBalance() - _currencyReserve);
        SafeERC20.safeTransfer(IERC20(token1_), to, _altcoinBalance() - _altcoinReserve);
    }

    function sync() external nonReentrant processBurns {
        uint256 currencyBalance = _currencyBalance();
        uint256 altcoinBalance = _altcoinBalance();
        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        int256 currencyAmountInOut = IntMath.sub(currencyBalance, currencyReserve);
        int256 altcoinAmountInOut = IntMath.sub(altcoinBalance, altcoinReserve);

        (uint112 currencyLiquidated, uint112 altcoinLiquidated) =
            _liquidateByOffset(currencyReserve, altcoinReserve, currencyAmountInOut, altcoinAmountInOut, ts());

        _update(currencyBalance - currencyLiquidated, altcoinBalance + altcoinLiquidated, ts());
    }

    // this function depends on the calling vault to make sure that nothing else will need to be liquidated due to the price going down, and that reentrancy will be prevented
    // calling flow needs to make sure to call sync at the end
    function payForLiquidation(
        uint112 currencyPayout,
        uint112 altcoinLiquidated,
        uint32 timestamp
    ) external onlyVault {
        (uint112 remainingCurrencyOffset, uint112 remainingAltcoinOffset) = _effectiveVirtualOffsets(timestamp);
        _virtualCurrencyOffset = currencyPayout + remainingCurrencyOffset;
        _virtualAltcoinOffset = altcoinLiquidated + remainingAltcoinOffset;
        _virtualOffsetTimestamp = timestamp;

        SafeERC20.safeTransfer(IERC20(token0), _msgSender(), currencyPayout);
        emit Swap(_msgSender(), 0, altcoinLiquidated, currencyPayout, 0, _msgSender());
    }

    function lockAndProcessBurn() external onlyVault {
        _nonReentrantLock();
        _processBurnUntil(ts());
    }

    function unlock() external onlyVault {
        _nonReentrantUnlock();
    }

    function getReserves()
        public
        view
        returns (uint112 currencyReserve, uint112 altcoinReserve, uint32 reserveTimestampLast)
    {
        currencyReserve = _currencyReserve;
        altcoinReserve = _altcoinReserve;
        reserveTimestampLast = _reserveTimestampLast;
    }

    function getVirtualOffsets()
        public
        view
        returns (uint112 currencyOffset, uint112 altcoinOffset, uint32 offsetTimestamp)
    {
        currencyOffset = _virtualCurrencyOffset;
        altcoinOffset = _virtualAltcoinOffset;
        offsetTimestamp = _virtualOffsetTimestamp;
    }

    function _update(uint256 currencyBalance, uint256 altcoinBalance, uint32 timestamp) private {
        if (currencyBalance > type(uint112).max || altcoinBalance > type(uint112).max) revert Overflow();
        _currencyReserve = uint112(currencyBalance);
        _altcoinReserve = uint112(altcoinBalance);
        _reserveTimestampLast = timestamp;
        emit Sync(_currencyReserve, _altcoinReserve);
    }

    function _executeBurns(
        uint32 fromTimestamp,
        uint32 toTimestamp,
        uint112 currencyReserve,
        uint112 altcoinReserve
    ) private returns (uint112, uint112, uint256, uint256) {
        uint256 burnedAmount = totalBurnRate * (toTimestamp - fromTimestamp);
        uint256 burnedFraction = Math.mulDiv(burnedAmount, Q96.ONE, totalSupply());

        (uint112 currencyLiquidated, uint112 altcoinLiquidated) =
            IHoyuVault(vault).liquidateLoansByFraction(currencyReserve, altcoinReserve, burnedFraction, toTimestamp);
        currencyReserve -= currencyLiquidated;
        altcoinReserve += altcoinLiquidated;

        uint256 currencyPayout = Math.mulDiv(burnedFraction, currencyReserve, Q96.ONE);
        uint256 altcoinPayout = Math.mulDiv(burnedFraction, altcoinReserve, Q96.ONE);

        _currencyRewardFactor += Math.mulDiv(currencyPayout, Q96.ONE, totalBurnRate);
        _altcoinRewardFactor += Math.mulDiv(altcoinPayout, Q96.ONE, totalBurnRate);
        _currencyRewardFactorAt[toTimestamp] = _currencyRewardFactor;
        _altcoinRewardFactorAt[toTimestamp] = _altcoinRewardFactor;

        burnReserve -= burnedAmount;
        totalBurnRate -= burnRateEndingAt[toTimestamp];
        _burn(address(this), burnedAmount);

        return (
            currencyReserve - uint112(currencyPayout),
            altcoinReserve - uint112(altcoinPayout),
            currencyPayout,
            altcoinPayout
        );
    }

    function _currencyBalance() private view returns (uint256) {
        return IERC20(token0).balanceOf(address(this));
    }

    function _altcoinBalance() private view returns (uint256) {
        return IERC20(token1).balanceOf(address(this));
    }

    function _liquidateByOffset(
        uint112 currencyReserve,
        uint112 altcoinReserve,
        int256 currencyAmountInOut,
        int256 altcoinAmountInOut,
        uint32 timestamp
    ) private returns (uint112 currencyLiquidated, uint112 altcoinLiquidated) {
        return IHoyuVault(vault).liquidateLoansByOffset(
            currencyReserve, altcoinReserve, currencyAmountInOut, altcoinAmountInOut, timestamp
        );
    }
}
