// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.21;

interface IHoyuPair {
    event Mint(address indexed sender, uint256 currencyAmount, uint256 altcoinAmount);
    event Burn(
        address indexed sender,
        address indexed to,
        uint256 burnRate,
        uint256 burnEnd,
        uint256 totalBurn,
        uint256 totalBurnRate
    );
    event BurnCanceled(
        address indexed sender, address indexed to, uint256 unburnedAmount, uint256 totalBurn, uint256 totalBurnRate
    );
    event Sync(uint112 currencyReserve, uint112 altcoinReserve);
    event Swap(
        address indexed sender,
        uint256 currencyIn,
        uint256 altcoinIn,
        uint256 currencyOut,
        uint256 altcoinOut,
        address indexed to
    );

    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error BurnAlreadyActive();
    error InsufficientBurnRate();
    error NoActiveBurn();
    error FutureBlock();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error MultiOutputSwap();
    error InvalidRecipient();
    error HoyuK();
    error CallerNotVault();
    error Overflow();

    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    function LP_MULTIPLIER() external pure returns (uint256);
    function BURN_DURATION_INTERVALS() external pure returns (uint256);
    function BURN_INTERVAL_BLOCKS() external pure returns (uint256);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function vault() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 currencyReserve, uint112 altcoinReserve, uint32 blockTimestampLast);
    function burnsProcessedUntil() external view returns (uint256 blockNumber);
    function burnReserve() external view returns (uint256);
    function totalBurnRate() external view returns (uint256);
    function burnRewardStore() external view returns (address);
    function burnRateEndingAt(uint256 blockNumber) external view returns (uint256);
    function userBurnExpiry(address user) external view returns (uint256 burnEndBlock);
    function userBurnRate(address user) external view returns (uint256 ratePerBlock);

    function mint(address to) external returns (uint256 liquidity);
    // TODO: maybe keep the uniswap signature that returns (uint256 currencyAmount, uint256 altcoinAmount) even though immediate values are always 0 due to long burn
    function burn(address to) external;
    function swap(uint256 currencyAmountOut, uint256 altcoinAmountOut, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function processBurnUntilBlock(uint256 toBlock) external;
    function withdrawBurnProceeds() external returns (uint256 currencyAmount, uint256 altcoinAmount);
    function cancelBurn(address to) external;

    // TODO: adjust to contain all information needed for swap event
    function payForLiquidation(uint112 currencyPayout) external;
}
