// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Q96Math} from "src/libraries/Q96Math.sol";
import {IntMath} from "src/libraries/IntMath.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHoyuPair} from "./interfaces/IHoyuPair.sol";
import {IHoyuVault} from "./interfaces/IHoyuVault.sol";
import {IUniswapV2Callee} from "./interfaces/IUniswapV2Callee.sol";
import {HoyuBurnRewardStore} from "./HoyuBurnRewardStore.sol";

contract HoyuPair is ERC20, IHoyuPair {
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
        processBurnUntilBlock(uint32(block.number));
        _;
    }

    constructor(address currency, address altcoin, address vault_, address factory_) ERC20("Hoyu Dex", "HOYD") {
        token0 = currency;
        token1 = altcoin;
        vault = vault_;
        factory = factory_;
        burnRewardStore = address(new HoyuBurnRewardStore(currency, altcoin));
    }

    // TODO: use lock
    // TODO: ensure first mint does not produce a price for an impossible tick
    function mint(address to) external processBurns returns (uint256 liquidity) {
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

        _update(currencyBalance, altcoinBalance, currencyReserve, altcoinReserve);
        emit Mint(_msgSender(), currencyAmount, altcoinAmount);
    }

    // TODO: use lock
    function burn(address to) external processBurns {
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

    // TODO: use lock
    // TODO: avoid reentrancy - adjust order of token transfer and data saves
    function cancelBurn(address to) external processBurns {
        if (userBurnExpiry[_msgSender()] <= block.number) revert NoActiveBurn();

        uint256 unburnedTokens = (userBurnExpiry[_msgSender()] - block.number) * userBurnRate[_msgSender()];
        _transfer(address(this), to, unburnedTokens);

        burnReserve -= unburnedTokens;
        totalBurnRate -= userBurnRate[_msgSender()];
        burnRateEndingAt[userBurnExpiry[_msgSender()]] -= userBurnRate[_msgSender()];
        userBurnExpiry[_msgSender()] = block.number;

        emit BurnCanceled(_msgSender(), to, unburnedTokens, burnReserve, totalBurnRate);
    }

    // TODO: use lock
    function processBurnUntilBlock(uint32 toBlock) public {
        if (toBlock > block.number) revert FutureBlock();

        if (burnsProcessedUntil >= toBlock) {
            return;
        }

        (uint112 currencyReserve, uint112 altcoinReserve,) = getReserves();

        if (totalBurnRate == 0) {
            // TODO: extract and reuse the common liquidation code here and below
            (uint256 currencyLiquidated, uint256 altcoinLiquidated) =
                IHoyuVault(vault).liquidateLoansByOffset(currencyReserve, altcoinReserve, 0, 0, toBlock);
            // TODO: consider avoiding the need to call _update
            if (currencyLiquidated > 0 || altcoinLiquidated > 0) {
                // TODO: consider retrieving actual amounts again for ensured accuracy
                _update(
                    currencyReserve - currencyLiquidated,
                    altcoinReserve + altcoinLiquidated,
                    currencyReserve,
                    altcoinReserve
                );
            }
            burnsProcessedUntil = toBlock;
            return;
        }

        uint32 nextIntervalExpiry =
            burnsProcessedUntil - burnsProcessedUntil % BURN_INTERVAL_BLOCKS + BURN_INTERVAL_BLOCKS;

        while (nextIntervalExpiry < toBlock) {
            uint256 burnRateEnding = burnRateEndingAt[nextIntervalExpiry];

            if (burnRateEnding > 0) {
                (currencyReserve, altcoinReserve) =
                    _executeBurns(burnsProcessedUntil, nextIntervalExpiry, currencyReserve, altcoinReserve);
                burnsProcessedUntil = nextIntervalExpiry;
            }

            nextIntervalExpiry += BURN_INTERVAL_BLOCKS;

            if (totalBurnRate <= 0) {
                break;
            }
        }

        if (totalBurnRate > 0) {
            (currencyReserve, altcoinReserve) =
                _executeBurns(burnsProcessedUntil, toBlock, currencyReserve, altcoinReserve);
            _update(currencyReserve, altcoinReserve, _currencyReserve, _altcoinReserve);
        } else {
            (uint256 currencyLiquidated, uint256 altcoinLiquidated) =
                IHoyuVault(vault).liquidateLoansByOffset(currencyReserve, altcoinReserve, 0, 0, toBlock);
            if (currencyLiquidated > 0 || altcoinLiquidated > 0) {
                _update(
                    currencyReserve - currencyLiquidated,
                    altcoinReserve + altcoinLiquidated,
                    _currencyReserve,
                    _altcoinReserve
                );
            }
        }

        burnsProcessedUntil = toBlock;
    }

    // TODO: use lock
    function withdrawBurnProceeds() external processBurns returns (uint256 currencyAmount, uint256 altcoinAmount) {
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

    // TODO: use lock
    // TODO: implement virtual buy reserves
    function swap(
        uint256 currencyAmountOut,
        uint256 altcoinAmountOut,
        address to,
        bytes calldata data
    ) external processBurns {
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
            (uint256 currencyLiquidated, uint256 altcoinLiquidated) = IHoyuVault(vault).liquidateLoansByOffset(
                currencyReserve, altcoinReserve, currencyAmountInOut, altcoinAmountInOut, uint32(block.number)
            );

            if (currencyLiquidated > 0) {
                currencyReserve -= uint112(currencyLiquidated);
                altcoinReserve += uint112(altcoinLiquidated);
                // TODO: consider retrieving actual amounts again for ensured accuracy
                currencyBalance -= currencyLiquidated;
                altcoinBalance += altcoinLiquidated;
            }
        }

        {
            uint256 currencyBalanceAdjusted = currencyBalance * 1000 - currencyAmountIn * SWAP_FEE_PER_MIL;
            uint256 altcoinBalanceAdjusted = altcoinBalance * 1000 - altcoinAmountIn * SWAP_FEE_PER_MIL;
            if (
                currencyBalanceAdjusted * altcoinBalanceAdjusted < uint256(currencyReserve) * altcoinReserve * 1000 ** 2
            ) revert HoyuK();
        }

        _update(currencyBalance, altcoinBalance, currencyReserve, altcoinReserve);

        {
            emit Swap(msg.sender, currencyAmountIn, altcoinAmountIn, currencyAmountOut, altcoinAmountOut, to);
        }
    }

    // TODO: use lock
    function skim(address to) external processBurns {
        address token0_ = token0; // gas savings
        address token1_ = token1; // gas savings
        SafeERC20.safeTransfer(IERC20(token0_), to, IERC20(token0_).balanceOf(address(this)) - _currencyReserve);
        SafeERC20.safeTransfer(IERC20(token1_), to, IERC20(token1_).balanceOf(address(this)) - _altcoinReserve);
    }

    // TODO: use lock
    function sync() external processBurns {
        uint256 currencyBalance = IERC20(token0).balanceOf(address(this));
        uint256 altcoinBalance = IERC20(token1).balanceOf(address(this));
        int256 currencyAmountInOut = IntMath.sub(currencyBalance, _currencyReserve);
        int256 altcoinAmountInOut = IntMath.sub(altcoinBalance, _altcoinReserve);

        (uint256 currencyLiquidated, uint256 altcoinLiquidated) = IHoyuVault(vault).liquidateLoansByOffset(
            _currencyReserve, _altcoinReserve, currencyAmountInOut, altcoinAmountInOut, uint32(block.number)
        );

        // TODO: consider retrieving actual amounts again for ensured accuracy
        _update(
            currencyBalance - currencyLiquidated, altcoinBalance + altcoinLiquidated, _currencyReserve, _altcoinReserve
        );
    }

    // TODO: emit swap event
    // this function depends on the calling vault to make sure that nothing else will need to be liquidated due to the price going down
    function payForLiquidation(uint112 currencyPayout, uint112 altcoinLiquidated, uint32 blockNumber) external {
        if (_msgSender() != vault) revert CallerNotVault();

        SafeERC20.safeTransfer(IERC20(token0), address(vault), currencyPayout);

        // TODO: consider instead using previous reserves and passed values to calculate the new reserves
        uint256 currencyBalance = IERC20(token0).balanceOf(address(this));
        uint256 altcoinBalance = IERC20(token1).balanceOf(address(this));
        _update(currencyBalance, altcoinBalance, _currencyReserve, _altcoinReserve);

        uint32 blocksSinceLastLiq = blockNumber - _virtualOffsetBlock;
        if (blocksSinceLastLiq >= VIRTUAL_OFFSETS_DECAY_BLOCKS) {
            _virtualCurrencyOffset = currencyPayout;
            _virtualAltcoinOffset = altcoinLiquidated;
        } else {
            // TODO: uint112 overflow
            uint32 remainingBlocks = VIRTUAL_OFFSETS_DECAY_BLOCKS - blocksSinceLastLiq;
            uint112 remainingCurrencyOffset = uint112(
                Math.mulDiv(_virtualCurrencyOffset, remainingBlocks, VIRTUAL_OFFSETS_DECAY_BLOCKS, Math.Rounding.Up)
            );
            uint112 remainingAltcoinOffset = uint112(
                Math.mulDiv(_virtualAltcoinOffset, remainingBlocks, VIRTUAL_OFFSETS_DECAY_BLOCKS, Math.Rounding.Up)
            );
            _virtualCurrencyOffset = remainingCurrencyOffset + currencyPayout;
            _virtualAltcoinOffset = remainingAltcoinOffset + altcoinLiquidated;
        }

        _virtualOffsetBlock = blockNumber;
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

    function _update(uint256 currencyBalance, uint256 altcoinBalance, uint112, uint112) private {
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
    ) private returns (uint112, uint112) {
        uint256 burnedAmount = totalBurnRate * (toBlock - fromBlock);
        uint256 totalSupply_ = totalSupply();
        uint112 currencyPayout = uint112(burnedAmount * currencyReserve / totalSupply_);
        uint256 burnFraction =
            Q96Math.ceilDiv(Q96Math.asQ96(uint160(burnedAmount)), Q96Math.asQ96(uint160(totalSupply_)));

        (uint256 currencyLiquidated, uint256 altcoinLiquidated) =
            IHoyuVault(vault).liquidateLoansByFraction(currencyReserve, altcoinReserve, burnFraction, toBlock);
        // TODO: avoid overflows when casting
        currencyReserve -= uint112(currencyLiquidated);
        altcoinReserve += uint112(altcoinLiquidated);

        _burn(address(this), burnedAmount);
        burnReserve -= burnedAmount;

        currencyPayout = uint112(burnedAmount * currencyReserve / totalSupply_);
        uint112 altcoinPayout = uint112(burnedAmount * altcoinReserve / totalSupply_);
        // TODO: avoid doing zero transfers
        // TODO: consider aggregating transfers from multiple _executeBurns for possible gas savings
        SafeERC20.safeTransfer(IERC20(token0), burnRewardStore, currencyPayout);
        SafeERC20.safeTransfer(IERC20(token1), burnRewardStore, altcoinPayout);

        _currencyRewardFactor += Q96Math.div(currencyPayout, totalBurnRate);
        _altcoinRewardFactor += Q96Math.div(altcoinPayout, totalBurnRate);
        _currencyRewardFactorAtBlock[toBlock] = _currencyRewardFactor;
        _altcoinRewardFactorAtBlock[toBlock] = _altcoinRewardFactor;

        totalBurnRate -= burnRateEndingAt[toBlock];

        return (currencyReserve - currencyPayout, altcoinReserve - altcoinPayout);
    }
}
