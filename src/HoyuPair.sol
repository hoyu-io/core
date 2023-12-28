// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96Math} from "src/libraries/Q96Math.sol";
import {IntMath} from "src/libraries/IntMath.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHoyuPair} from "./interfaces/IHoyuPair.sol";
import {IHoyuVault} from "./interfaces/IHoyuVault.sol";
import {IUniswapV2Callee} from "./interfaces/IUniswapV2Callee.sol";
import {HoyuBurnRewardStore} from "./HoyuBurnRewardStore.sol";

contract HoyuPair is ERC20, IHoyuPair, ReentrancyGuard {
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3 * 2 ** 16;
    uint256 public constant LP_MULTIPLIER = 2 ** 32;
    uint8 public constant BURN_DURATION_INTERVALS = 14;
    uint16 public constant BURN_INTERVAL_BLOCKS = 3600;
    uint16 public constant VIRTUAL_OFFSETS_DECAY_BLOCKS = 300;

    uint256 private constant SWAP_FEE_PER_MIL = 3;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    address public immutable vault;
    address public immutable burnRewardStore;

    uint112 private _currencyReserve;
    uint112 private _altcoinReserve;
    uint32 private _blockTimestampLast;

    uint112 private _virtualCurrencyOffset;
    uint112 private _virtualAltcoinOffset;
    uint32 private _virtualOffsetBlock;

    uint32 public burnsProcessedUntil;
    uint256 public burnReserve;
    uint256 public totalBurnRate;

    mapping(uint256 => uint256) public burnRateEndingAt;
    mapping(address => uint256) public userBurnExpiry;
    mapping(address => uint256) public userBurnRate;

    uint256 private _currencyRewardFactor;
    uint256 private _altcoinRewardFactor;
    mapping(uint256 => uint256) private _currencyRewardFactorAtBlock;
    mapping(uint256 => uint256) private _altcoinRewardFactorAtBlock;
    mapping(address => uint256) private _userBurnStartCurrencyRewardFactor;
    mapping(address => uint256) private _userBurnStartAltcoinRewardFactor;

    modifier processBurns() {
        _processBurnUntilBlock(uint32(block.number));
        _;
    }

    constructor(address currency, address altcoin, address vault_, address factory_) ERC20("Hoyu Dex", "HOYD") {
        token0 = currency;
        token1 = altcoin;
        vault = vault_;
        factory = factory_;
        burnRewardStore = address(new HoyuBurnRewardStore(currency, altcoin));
    }

    // TODO: ensure first mint does not produce a price for an impossible tick
    function mint(address to) external nonReentrant processBurns returns (uint256 liquidity) {
        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        uint256 currencyBalance = IERC20(token0).balanceOf(address(this));
        uint256 altcoinBalance = IERC20(token1).balanceOf(address(this));
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

        _update(currencyBalance, altcoinBalance);
        emit Mint(_msgSender(), currencyAmount, altcoinAmount);
    }

    function burn(address to) external nonReentrant processBurns {
        if (userBurnExpiry[to] > block.number) revert BurnAlreadyActive();

        uint256 lastExpiryBlock = block.number - block.number % BURN_INTERVAL_BLOCKS;
        userBurnExpiry[to] = lastExpiryBlock + BURN_INTERVAL_BLOCKS * BURN_DURATION_INTERVALS;

        uint256 burnDuration = userBurnExpiry[to] - block.number;
        uint256 burnAmount = balanceOf(address(this)) - burnReserve;

        userBurnRate[to] = burnAmount / burnDuration;
        _userBurnStartCurrencyRewardFactor[to] = _currencyRewardFactor;
        _userBurnStartAltcoinRewardFactor[to] = _altcoinRewardFactor;

        if (userBurnRate[to] == 0) revert InsufficientBurnRate();

        burnRateEndingAt[userBurnExpiry[to]] += userBurnRate[to];
        totalBurnRate += userBurnRate[to];
        burnReserve += userBurnRate[to] * burnDuration;

        emit Burn(_msgSender(), to, userBurnRate[to], userBurnExpiry[to], burnReserve, totalBurnRate);
    }

    function cancelBurn(address to) external nonReentrant processBurns {
        if (userBurnExpiry[_msgSender()] <= block.number) revert NoActiveBurn();

        uint256 unburnedTokens = (userBurnExpiry[_msgSender()] - block.number) * userBurnRate[_msgSender()];
        _transfer(address(this), to, unburnedTokens);

        burnReserve -= unburnedTokens;
        totalBurnRate -= userBurnRate[_msgSender()];
        burnRateEndingAt[userBurnExpiry[_msgSender()]] -= userBurnRate[_msgSender()];
        userBurnExpiry[_msgSender()] = block.number;

        emit BurnCanceled(_msgSender(), to, unburnedTokens, burnReserve, totalBurnRate);
    }

    function processBurnUntilBlock(uint32 toBlock) public nonReentrant {
        _processBurnUntilBlock(toBlock);
    }

    function _processBurnUntilBlock(uint32 toBlock) private {
        if (toBlock > block.number) revert FutureBlock();

        uint32 fromBlock = burnsProcessedUntil;
        if (fromBlock >= toBlock) {
            return;
        }

        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        uint256 currencyBurned = 0;
        uint256 altcoinBurned = 0;

        uint32 nextIntervalExpiry = fromBlock - fromBlock % BURN_INTERVAL_BLOCKS + BURN_INTERVAL_BLOCKS;

        while (nextIntervalExpiry < toBlock && totalBurnRate > 0) {
            if (burnRateEndingAt[nextIntervalExpiry] > 0) {
                uint256 intervalCurrencyBurned;
                uint256 intervalAltcoinBurned;
                (currencyReserve, altcoinReserve, intervalCurrencyBurned, intervalAltcoinBurned) =
                    _executeBurns(fromBlock, nextIntervalExpiry, currencyReserve, altcoinReserve);
                currencyBurned += intervalCurrencyBurned;
                altcoinBurned += intervalAltcoinBurned;
                fromBlock = nextIntervalExpiry;
            }

            nextIntervalExpiry += BURN_INTERVAL_BLOCKS;
        }

        if (totalBurnRate > 0) {
            uint256 intervalCurrencyBurned;
            uint256 intervalAltcoinBurned;
            (currencyReserve, altcoinReserve, intervalCurrencyBurned, intervalAltcoinBurned) =
                _executeBurns(fromBlock, toBlock, currencyReserve, altcoinReserve);
            currencyBurned += intervalCurrencyBurned;
            altcoinBurned += intervalAltcoinBurned;
            _update(currencyReserve, altcoinReserve);
        } else {
            (uint112 currencyLiquidated, uint112 altcoinLiquidated) =
                IHoyuVault(vault).liquidateLoansByOffset(currencyReserve, altcoinReserve, 0, 0, toBlock);
            if (currencyLiquidated > 0 || altcoinLiquidated > 0 || currencyBurned > 0 || altcoinBurned > 0) {
                _update(currencyReserve - currencyLiquidated, altcoinReserve + altcoinLiquidated);
            }
        }

        if (currencyBurned > 0) SafeERC20.safeTransfer(IERC20(token0), burnRewardStore, currencyBurned);
        if (altcoinBurned > 0) SafeERC20.safeTransfer(IERC20(token1), burnRewardStore, altcoinBurned);

        burnsProcessedUntil = toBlock;
    }

    // TODO: add recipient address parameter to withdraw to
    function withdrawBurnProceeds()
        external
        nonReentrant
        processBurns
        returns (uint256 currencyAmount, uint256 altcoinAmount)
    {
        uint256 burnRate = userBurnRate[_msgSender()];

        if (burnRate == 0) {
            return (0, 0);
        }

        uint256 burnEnd = userBurnExpiry[_msgSender()];
        bool burnFullyCompleted = burnEnd <= block.number;
        if (!burnFullyCompleted) {
            burnEnd = block.number;
        }

        currencyAmount = Math.mulDiv(
            _currencyRewardFactorAtBlock[burnEnd] - _userBurnStartCurrencyRewardFactor[_msgSender()],
            burnRate,
            Q96Math.ONE
        );
        altcoinAmount = Math.mulDiv(
            _altcoinRewardFactorAtBlock[burnEnd] - _userBurnStartAltcoinRewardFactor[_msgSender()],
            burnRate,
            Q96Math.ONE
        );

        if (burnFullyCompleted) {
            userBurnRate[_msgSender()] = 0;
        } else {
            _userBurnStartCurrencyRewardFactor[_msgSender()] = _currencyRewardFactorAtBlock[burnEnd];
            _userBurnStartAltcoinRewardFactor[_msgSender()] = _altcoinRewardFactorAtBlock[burnEnd];
        }

        HoyuBurnRewardStore(burnRewardStore).payOutRewards(currencyAmount, altcoinAmount, _msgSender());
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
            IUniswapV2Callee(to).uniswapV2Call(msg.sender, currencyAmountOut, altcoinAmountOut, data);
        }

        uint256 currencyBalance = IERC20(token0).balanceOf(address(this));
        uint256 altcoinBalance = IERC20(token1).balanceOf(address(this));

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
            (uint112 currencyLiquidated, uint112 altcoinLiquidated) = IHoyuVault(vault).liquidateLoansByOffset(
                currencyReserve, altcoinReserve, currencyAmountInOut, altcoinAmountInOut, uint32(block.number)
            );

            if (currencyLiquidated > 0) {
                currencyReserve -= currencyLiquidated;
                altcoinReserve += altcoinLiquidated;
                // TODO: consider retrieving actual amounts again for ensured accuracy
                currencyBalance -= currencyLiquidated;
                altcoinBalance += altcoinLiquidated;
            }
        }

        {
            (uint256 currencyOffset, uint256 altcoinOffset) =
                altcoinAmountOut > 0 ? _effectiveVirtualOffsets(uint32(block.number)) : (0, 0);
            uint256 currencyBalanceAdjusted =
                (currencyBalance + currencyOffset) * 1000 - currencyAmountIn * SWAP_FEE_PER_MIL;
            uint256 altcoinBalanceAdjusted =
                (altcoinBalance - altcoinOffset) * 1000 - altcoinAmountIn * SWAP_FEE_PER_MIL;
            if (
                currencyBalanceAdjusted * altcoinBalanceAdjusted
                    < (currencyReserve + currencyOffset) * (altcoinReserve - altcoinOffset) * 1000 ** 2
            ) revert HoyuK();
        }

        _update(currencyBalance, altcoinBalance);

        emit Swap(_msgSender(), currencyAmountIn, altcoinAmountIn, currencyAmountOut, altcoinAmountOut, to);
    }

    function _effectiveVirtualOffsets(uint32 blockNumber) private view returns (uint112, uint112) {
        uint32 blocksSinceLastLiq = blockNumber - _virtualOffsetBlock;
        if (blocksSinceLastLiq >= VIRTUAL_OFFSETS_DECAY_BLOCKS) return (0, 0);

        uint32 remainingBlocks = VIRTUAL_OFFSETS_DECAY_BLOCKS - blocksSinceLastLiq;
        uint256 remainingCurrencyOffset =
            Math.mulDiv(_virtualCurrencyOffset, remainingBlocks, VIRTUAL_OFFSETS_DECAY_BLOCKS, Math.Rounding.Ceil);
        uint256 remainingAltcoinOffset =
            Math.mulDiv(_virtualAltcoinOffset, remainingBlocks, VIRTUAL_OFFSETS_DECAY_BLOCKS, Math.Rounding.Ceil);

        return (uint112(remainingCurrencyOffset), uint112(remainingAltcoinOffset));
    }

    function skim(address to) external nonReentrant processBurns {
        address token0_ = token0; // gas savings
        address token1_ = token1; // gas savings
        SafeERC20.safeTransfer(IERC20(token0_), to, IERC20(token0_).balanceOf(address(this)) - _currencyReserve);
        SafeERC20.safeTransfer(IERC20(token1_), to, IERC20(token1_).balanceOf(address(this)) - _altcoinReserve);
    }

    function sync() external nonReentrant processBurns {
        uint256 currencyBalance = IERC20(token0).balanceOf(address(this));
        uint256 altcoinBalance = IERC20(token1).balanceOf(address(this));
        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();
        int256 currencyAmountInOut = IntMath.sub(currencyBalance, currencyReserve);
        int256 altcoinAmountInOut = IntMath.sub(altcoinBalance, altcoinReserve);

        (uint112 currencyLiquidated, uint112 altcoinLiquidated) = IHoyuVault(vault).liquidateLoansByOffset(
            currencyReserve, altcoinReserve, currencyAmountInOut, altcoinAmountInOut, uint32(block.number)
        );

        // TODO: consider retrieving actual amounts again for ensured accuracy
        _update(currencyBalance - currencyLiquidated, altcoinBalance + altcoinLiquidated);
    }

    // this function depends on the calling vault to make sure that nothing else will need to be liquidated due to the price going down, and that reentrancy will be prevented
    function payForLiquidation(uint112 currencyPayout, uint112 altcoinLiquidated, uint32 blockNumber) external {
        if (_msgSender() != vault) revert CallerNotVault();

        (uint112 remainingCurrencyOffset, uint112 remainingAltcoinOffset) = _effectiveVirtualOffsets(blockNumber);
        _virtualCurrencyOffset = currencyPayout + remainingCurrencyOffset;
        _virtualAltcoinOffset = altcoinLiquidated + remainingAltcoinOffset;
        _virtualOffsetBlock = blockNumber;

        SafeERC20.safeTransfer(IERC20(token0), _msgSender(), currencyPayout);
        emit Swap(_msgSender(), 0, altcoinLiquidated, currencyPayout, 0, _msgSender());
    }

    function lockAndProcessBurn() external {
        if (_msgSender() != vault) revert CallerNotVault();

        _nonReentrantLock();
        _processBurnUntilBlock(uint32(block.number));
    }

    function unlock() external {
        if (_msgSender() != vault) revert CallerNotVault();

        _nonReentrantUnlock();
    }

    function getReserves()
        public
        view
        returns (uint112 currencyReserve, uint112 altcoinReserve, uint32 blockTimestampLast)
    {
        currencyReserve = _currencyReserve;
        altcoinReserve = _altcoinReserve;
        blockTimestampLast = _blockTimestampLast;
    }

    function getVirtualOffsets()
        public
        view
        returns (uint112 currencyOffset, uint112 altcoinOffset, uint32 offsetBlockNumber)
    {
        currencyOffset = _virtualCurrencyOffset;
        altcoinOffset = _virtualAltcoinOffset;
        offsetBlockNumber = _virtualOffsetBlock;
    }

    function _update(uint256 currencyBalance, uint256 altcoinBalance) private {
        // TODO: consider changing currencyBalance and altcoinBalance parameters to uint112 to avoid needing the require and cast
        if (currencyBalance > type(uint112).max || altcoinBalance > type(uint112).max) revert Overflow();
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        _currencyReserve = uint112(currencyBalance);
        _altcoinReserve = uint112(altcoinBalance);
        _blockTimestampLast = blockTimestamp;
        emit Sync(_currencyReserve, _altcoinReserve);
    }

    function _executeBurns(
        uint32 fromBlock,
        uint32 toBlock,
        uint112 currencyReserve,
        uint112 altcoinReserve
    ) private returns (uint112, uint112, uint256, uint256) {
        uint256 burnedAmount = totalBurnRate * (toBlock - fromBlock);
        uint256 totalSupply_ = totalSupply();

        (uint112 currencyLiquidated, uint112 altcoinLiquidated) = IHoyuVault(vault).liquidateLoansByFraction(
            currencyReserve, altcoinReserve, Math.mulDiv(burnedAmount, Q96Math.ONE, totalSupply_), toBlock
        );
        currencyReserve -= currencyLiquidated;
        altcoinReserve += altcoinLiquidated;

        uint256 currencyPayout = burnedAmount * currencyReserve / totalSupply_;
        uint256 altcoinPayout = burnedAmount * altcoinReserve / totalSupply_;

        _currencyRewardFactor += Q96Math.div(currencyPayout, totalBurnRate);
        _altcoinRewardFactor += Q96Math.div(altcoinPayout, totalBurnRate);
        _currencyRewardFactorAtBlock[toBlock] = _currencyRewardFactor;
        _altcoinRewardFactorAtBlock[toBlock] = _altcoinRewardFactor;

        burnReserve -= burnedAmount;
        totalBurnRate -= burnRateEndingAt[toBlock];
        _burn(address(this), burnedAmount);

        return (
            currencyReserve - uint112(currencyPayout),
            altcoinReserve - uint112(altcoinPayout),
            currencyPayout,
            altcoinPayout
        );
    }
}
