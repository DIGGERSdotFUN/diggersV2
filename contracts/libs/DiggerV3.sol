// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";

/**
 * @title DiggerV3
 * @notice Compact Uniswap V3 integration for the Diggers launchpad: the pool/factory/WETH
 *         interfaces, a stateless math library (tick math, price conversion, liquidity
 *         math, pending-fee accounting, an exact-input quoter), and an abstract base that
 *         creates + seeds pools, swaps, and collects fees through the canonical V3
 *         mint/swap callbacks. Scope is deliberately narrow: one WETH/TOKEN 1% pool per
 *         launch, WETH pinned as token0 (the launchpad grinds the clone salt so
 *         `WETH < token`), a single permanent position below spot (100% token1 / 0 WETH),
 *         no position removal — Diggers liquidity is permanent, so the unwind code does
 *         not exist.
 * @dev Native gas value is wrapped to WETH on the way into a pool and unwrapped back on
 *      the way out, so the launchpad's external surface stays native (ETH on Robinhood,
 *      USDT0 on Stable). All tick/price/liquidity math is byte-identical to the V4 edition
 *      because a 1% V3 pool uses the same tick spacing (200) and the same concentrated-
 *      liquidity formulas. Consumed by Diggers (inherits {DiggerV3Base}), {DiggerCreateLib},
 *      {DiggerHarvestLib}, {DiggerGraduationMath}, {DiggerTwapOracle}, and quote helpers.
 * @author BasedDopamine
 */

/**
 * @notice Quote-token surface: wrap/unwrap (WETH9-style; never called in dual-native
 *         mode) and the ERC20 moves the pool needs.
 */
interface IWETH9 {
    /// @notice Wraps `msg.value` native into WETH credited to the caller.
    function deposit() external payable;

    /**
     * @notice Unwraps WETH back to native ETH sent to the caller.
     * @param amount WETH amount to withdraw.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Transfers WETH to `to`.
     * @param to Recipient.
     * @param amount Amount to transfer.
     * @return True on success.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @notice Returns the WETH balance of `account`.
     * @param account Address to query.
     * @return WETH balance.
     */
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @notice Uniswap V3 factory: canonical-pool lookup + creation.
 */
interface IUniswapV3Factory {
    /**
     * @notice Returns the pool address for a token pair and fee tier, or address(0).
     * @param tokenA First token of the pair (order-independent).
     * @param tokenB Second token of the pair (order-independent).
     * @param fee Fee tier in millionths (e.g. 10000 = 1%).
     * @return pool Canonical pool address, or zero if not created.
     */
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

    /**
     * @notice Creates a new pool for the pair and fee tier.
     * @param tokenA First token of the pair (order-independent).
     * @param tokenB Second token of the pair (order-independent).
     * @param fee Fee tier in millionths.
     * @return pool Newly created pool address.
     */
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);

    /**
     * @notice Returns the tick spacing for a fee tier.
     * @param fee Fee tier in millionths.
     * @return Tick spacing for that tier (200 for Diggers' 1% pools).
     */
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

/**
 * @notice Minimal slice of the Uniswap V3 pool ABI used by Diggers.
 */
interface IUniswapV3Pool {
    /**
     * @notice Initializes the pool at `sqrtPriceX96` (one-shot).
     * @param sqrtPriceX96 Initial sqrt price in Q64.96.
     */
    function initialize(uint160 sqrtPriceX96) external;

    /**
     * @notice Mints liquidity into a tick range for `recipient`.
     * @param recipient Position owner that will receive the liquidity.
     * @param tickLower Lower tick of the position.
     * @param tickUpper Upper tick of the position.
     * @param amount Liquidity delta to mint.
     * @param data Callback data forwarded to `uniswapV3MintCallback`.
     * @return amount0 token0 paid to the pool.
     * @return amount1 token1 paid to the pool.
     */
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Burns liquidity from the caller's position (or pokes fees with amount 0).
     * @param tickLower Lower tick of the position.
     * @param tickUpper Upper tick of the position.
     * @param amount Liquidity delta to burn (0 = fee poke only).
     * @return amount0 token0 owed from the burn.
     * @return amount1 token1 owed from the burn.
     */
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Collects tokens owed to a position into `recipient`.
     * @param recipient Address receiving the collected tokens.
     * @param tickLower Lower tick of the position.
     * @param tickUpper Upper tick of the position.
     * @param amount0Requested Max token0 to collect.
     * @param amount1Requested Max token1 to collect.
     * @return amount0 token0 actually collected.
     * @return amount1 token1 actually collected.
     */
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /**
     * @notice Executes a swap against the pool.
     * @param recipient Address receiving the output tokens.
     * @param zeroForOne True to swap token0 → token1.
     * @param amountSpecified Exact input (positive) or exact output (negative).
     * @param sqrtPriceLimitX96 Price limit that the swap cannot cross.
     * @param data Callback data forwarded to `uniswapV3SwapCallback`.
     * @return amount0 token0 delta (positive = pool received).
     * @return amount1 token1 delta (positive = pool received).
     */
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /**
     * @notice Returns the packed spot state of the pool.
     * @return sqrtPriceX96 Current sqrt price in Q64.96.
     * @return tick Current tick.
     * @return observationIndex Most recent oracle observation index.
     * @return observationCardinality Current observation cardinality.
     * @return observationCardinalityNext Next observation cardinality.
     * @return feeProtocol Protocol fee bits.
     * @return unlocked Whether the pool reentrancy lock is open.
     */
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /**
     * @notice Returns the pool's currently active in-range liquidity.
     * @return Active liquidity (L).
     */
    function liquidity() external view returns (uint128);

    /**
     * @notice Global fee growth of token0 as of the last update, Q128-scaled.
     * @return feeGrowthGlobal0X128 accumulator.
     */
    function feeGrowthGlobal0X128() external view returns (uint256);

    /**
     * @notice Global fee growth of token1 as of the last update, Q128-scaled.
     * @return feeGrowthGlobal1X128 accumulator.
     */
    function feeGrowthGlobal1X128() external view returns (uint256);

    /**
     * @notice Returns the packed tick info for an initialized (or empty) tick.
     * @param tick Tick to query.
     * @return liquidityGross Total liquidity referencing this tick as a bound.
     * @return liquidityNet Net liquidity change when the tick is crossed.
     * @return feeGrowthOutside0X128 token0 fee growth outside this tick.
     * @return feeGrowthOutside1X128 token1 fee growth outside this tick.
     * @return tickCumulativeOutside Tick accumulator outside this tick.
     * @return secondsPerLiquidityOutsideX128 Liquidity-seconds outside this tick.
     * @return secondsOutside Seconds spent outside this tick.
     * @return initialized Whether the tick has been initialized.
     */
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    /**
     * @notice Returns position state for a V3 position key.
     * @param key keccak256(owner, tickLower, tickUpper).
     * @return liquidity Position liquidity.
     * @return feeGrowthInside0LastX128 Last recorded token0 fee growth inside the range.
     * @return feeGrowthInside1LastX128 Last recorded token1 fee growth inside the range.
     * @return tokensOwed0 Uncollected token0 fees/principal.
     * @return tokensOwed1 Uncollected token1 fees/principal.
     */
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /**
     * @notice Returns the pool's token0 address.
     * @return token0 address (WETH for every Diggers pool).
     */
    function token0() external view returns (address);

    /**
     * @notice Returns the pool's token1 address.
     * @return token1 address (the launched DiggersToken).
     */
    function token1() external view returns (address);

    /**
     * @notice Returns the pool's fee tier in millionths.
     * @return Fee tier (10000 = 1% for Diggers).
     */
    function fee() external view returns (uint24);
}

/**
 * @title DiggerV3 (library)
 * @notice Stateless helpers: pool-state reads via the V3 pool getters, tick/price math,
 *         liquidity-amount conversions, pending-fee accounting, and a single-step
 *         exact-input quoter that reproduces the pool's swap math within active liquidity.
 * @dev Pure/view-only — no storage. Intended to inline into Diggers and the domain libs
 *      that need TickMath / SqrtPriceMath without pulling the full Uniswap periphery.
 * @author BasedDopamine
 */
library DiggerV3 {
    // ------------------------------------------------------------------ types

    /// @dev Unpacked pool spot state.
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
    }

    /// @dev Outcome of a swap.
    struct SwapOutcome {
        uint256 amountIn;
        uint256 amountOut;
    }

    // -------------------------------------------------------------- constants

    /// @dev Absolute tick bound from Uniswap TickMath (pre spacing alignment).
    int24 internal constant MAX_TICK_BOUND = 887272;
    /// @dev sqrt price at tick -887272 (inclusive lower bound).
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev sqrt price at tick 887272 (EXCLUSIVE upper bound — initialize rejects ==).
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    /// @dev 2^96, the Q64.96 fixed-point unit.
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    /// @dev 2^128, denominator of V3 fee-growth accumulators.
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    /// @dev Pool fee unit: millionths (10000 = 1%).
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    // ----------------------------------------------------------------- errors

    /// @notice A pool key needs a non-zero token address.
    error TokenRequired();
    /// @notice Tick spacing must be strictly positive.
    error SpacingInvalid();
    /// @notice Tick magnitude exceeds the TickMath bound.
    error TickOutOfBounds();
    /// @notice A computed sqrt price no longer fits uint160.
    error SqrtPriceOverflow();
    /// @notice Downcast to uint128 would truncate.
    error CastOverflow();

    // ------------------------------------------------------- position helpers

    /**
     * @notice Widest spacing-aligned tick bounds for a pool.
     * @dev Position ticks must be spacing multiples, so the usable full range is
     *      ±floor(887272 / spacing) · spacing (e.g. ±887200 at 200).
     * @param tickSpacing Pool tick spacing (must be > 0).
     * @return tickLower Spacing-aligned lower bound (−aligned).
     * @return tickUpper Spacing-aligned upper bound (+aligned).
     */
    function fullRangeTicks(int24 tickSpacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        if (tickSpacing <= 0) revert SpacingInvalid();
        int24 aligned = (MAX_TICK_BOUND / tickSpacing) * tickSpacing;
        return (-aligned, aligned);
    }

    /**
     * @notice V3 position key: keccak256(owner, tickLower, tickUpper). No salt (that is V4).
     * @param owner Position owner (the launchpad for Diggers positions).
     * @param tickLower Position lower tick.
     * @param tickUpper Position upper tick.
     * @return keccak256-packed position key used by `pool.positions`.
     */
    function positionKey(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    // ------------------------------------------------------------- state reads

    /**
     * @notice Reads a pool's spot price and tick.
     * @param pool V3 pool address.
     * @return slot0 Unpacked `{sqrtPriceX96, tick}`.
     */
    function getSlot0(address pool) internal view returns (Slot0 memory slot0) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        slot0.sqrtPriceX96 = sqrtPriceX96;
        slot0.tick = tick;
    }

    /**
     * @notice Whether a pool exists and has been initialized (nonzero spot price).
     * @param pool Candidate pool address (may be zero or empty code).
     * @return True iff the address has code and `slot0.sqrtPriceX96 != 0`.
     */
    function isPoolInitialized(address pool) internal view returns (bool) {
        if (pool == address(0) || pool.code.length == 0) return false;
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return sqrtPriceX96 != 0;
    }

    /**
     * @notice A pool's currently active liquidity.
     * @param pool V3 pool address.
     * @return Active in-range liquidity (L).
     */
    function getPoolLiquidity(address pool) internal view returns (uint128) {
        return IUniswapV3Pool(pool).liquidity();
    }

    /**
     * @notice Fee growth inside a tick range, following the canonical V3 rules.
     * @dev feeGrowthOutside flips meaning depending on which side of the boundary the
     *      current tick sits, so both boundaries are conditionally mirrored through the
     *      global accumulator. The final subtraction wraps intentionally — V3 fee
     *      accounting is modular by specification.
     * @param pool V3 pool address.
     * @param tickLower Lower tick of the range.
     * @param tickUpper Upper tick of the range.
     * @return feeGrowthInside0 token0 fee growth inside the range (Q128).
     * @return feeGrowthInside1 token1 fee growth inside the range (Q128).
     */
    function getFeeGrowthInside(address pool, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1)
    {
        Slot0 memory slot0 = getSlot0(pool);
        uint256 global0 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 global1 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        (,, uint256 lowerOut0, uint256 lowerOut1,,,,) = IUniswapV3Pool(pool).ticks(tickLower);
        (,, uint256 upperOut0, uint256 upperOut1,,,,) = IUniswapV3Pool(pool).ticks(tickUpper);

        uint256 below0;
        uint256 below1;
        if (slot0.tick >= tickLower) {
            below0 = lowerOut0;
            below1 = lowerOut1;
        } else {
            below0 = global0 - lowerOut0;
            below1 = global1 - lowerOut1;
        }

        uint256 above0;
        uint256 above1;
        if (slot0.tick < tickUpper) {
            above0 = upperOut0;
            above1 = upperOut1;
        } else {
            above0 = global0 - upperOut0;
            above1 = global1 - upperOut1;
        }

        unchecked {
            feeGrowthInside0 = global0 - below0 - above0;
            feeGrowthInside1 = global1 - below1 - above1;
        }
    }

    /**
     * @notice Pending (uncollected) LP fees of the launchpad's position, without touching
     *         state. Includes already-poked `tokensOwed` plus fresh fee-growth accrual.
     * @param pool V3 pool address.
     * @param owner Position owner (the launchpad).
     * @param tickLower Position lower tick.
     * @param tickUpper Position upper tick.
     * @return pendingFees0 token0 (WETH) fees awaiting collection.
     * @return pendingFees1 token1 (launched token) fees awaiting collection.
     */
    function getPendingV3Fees(address pool, address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 pendingFees0, uint256 pendingFees1)
    {
        bytes32 key = positionKey(owner, tickLower, tickUpper);
        (uint128 liquidity, uint256 last0, uint256 last1, uint128 owed0, uint128 owed1) =
            IUniswapV3Pool(pool).positions(key);
        pendingFees0 = owed0;
        pendingFees1 = owed1;
        if (liquidity == 0) return (pendingFees0, pendingFees1);

        (uint256 inside0, uint256 inside1) = getFeeGrowthInside(pool, tickLower, tickUpper);
        unchecked {
            // Wrapping deltas, per V3's modular fee accounting.
            pendingFees0 += DiggerMath.md512(uint256(liquidity), inside0 - last0, Q128);
            pendingFees1 += DiggerMath.md512(uint256(liquidity), inside1 - last1, Q128);
        }
    }

    // -------------------------------------------------------------- tick math

    /**
     * @notice sqrt(1.0001^tick) in Q64.96 — the canonical TickMath routine.
     * @dev Bit-by-bit multiplication with the standard precomputed constants;
     *      byte-identical to the Uniswap reference. Reverts outside ±887272.
     * @param tick Tick whose sqrt price is requested.
     * @return sqrtPriceX96 sqrt(1.0001^tick) as a Q64.96 fixed-point value.
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK_BOUND))) revert TickOutOfBounds();

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Q128.128 → Q64.96, rounding up on any truncated bits.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    // ------------------------------------------------------------- price math

    /**
     * @notice Token-per-ETH spot price implied by a sqrt price, scaled 1e18.
     * @dev price = sqrtPrice² / 2^192, computed as two chained 512-bit mul-divs.
     * @param sqrtPriceX96 Pool sqrt price in Q64.96.
     * @return priceTokenPerEth 1e18-scaled token1-per-token0 price.
     */
    function sqrtPriceToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 priceTokenPerEth) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 squared = DiggerMath.md512(sqrtPrice, sqrtPrice, Q96);
        priceTokenPerEth = DiggerMath.md512(squared, 1e18, Q96);
    }

    /**
     * @notice Native-WEI-per-token spot price implied by a sqrt price, scaled 1e18.
     * @dev inverse = 2^192 · 1e18 · quoteScale / sqrtPrice², split into two divisions by
     *      sqrtPrice because squaring first would overflow for sqrtPriceX96 > 2^128.
     *      Returns 0 for an uninitialized pool (sqrtPrice == 0) instead of reverting.
     * @param sqrtPriceX96 Pool sqrt price in Q64.96.
     * @param quoteScale Wei per pool unit (1 on Robinhood, 1e12 on Stable).
     * @return priceEthPerToken 1e18-scaled native-wei-per-token1 price.
     */
    function sqrtPriceToInversePrice(uint160 sqrtPriceX96, uint256 quoteScale)
        internal
        pure
        returns (uint256 priceEthPerToken)
    {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        if (sqrtPrice == 0) return 0;
        // `quoteScale` folds in BEFORE the divisions: on a 6-dec quote the units-per-token
        // ratio is ~1e12 smaller than its wei value, so scaling an already-floored result
        // would just multiply zero. 1e18 × 1e12 stays far inside md512's 512-bit range.
        uint256 half = DiggerMath.md512(Q96, 1e18 * quoteScale, sqrtPrice);
        priceEthPerToken = DiggerMath.md512(Q96, half, sqrtPrice);
    }

    /**
     * @notice Encodes an initial sqrt price from a deposit ratio (bootstrap helper).
     * @dev price = amount1/amount0 in raw units; result = sqrt(ratio·2^96)·2^48, clamped
     *      into [MIN_SQRT_RATIO, MAX_SQRT_RATIO). Both amounts must be nonzero.
     * @param amount0 Desired token0 deposit (denominator of the ratio).
     * @param amount1 Desired token1 deposit (numerator of the ratio).
     * @return sqrtPriceX96 Clamped Q64.96 sqrt price encoding `amount1/amount0`.
     */
    function encodePriceSqrt(uint256 amount0, uint256 amount1) internal pure returns (uint160 sqrtPriceX96) {
        uint256 ratioX96 = DiggerMath.md512(amount1, Q96, amount0);
        uint256 encoded = _isqrt(ratioX96) << 48;
        if (encoded < MIN_SQRT_RATIO) encoded = MIN_SQRT_RATIO;
        else if (encoded >= MAX_SQRT_RATIO) encoded = MAX_SQRT_RATIO - 1;
        sqrtPriceX96 = uint160(encoded);
    }

    /**
     * @dev Babylonian floor square root.
     * @param x Value whose floor square root is requested.
     * @return Floor of sqrt(x).
     */
    function _isqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        uint256 estimate = (x + 1) / 2;
        uint256 best = x;
        while (estimate < best) {
            best = estimate;
            estimate = (x / estimate + estimate) / 2;
        }
        return best;
    }

    // -------------------------------------------------------- liquidity math

    /**
     * @notice Liquidity implied by a currency0 (WETH) amount over a price range.
     * @dev L = amount0 · (sqrtA·sqrtB / Q96) / (sqrtB − sqrtA), floored at each step.
     * @param sqrtPriceAX96 One end of the price range (order-independent).
     * @param sqrtPriceBX96 Other end of the price range (order-independent).
     * @param amount0 token0 amount available.
     * @return Floored liquidity corresponding to `amount0` over the range.
     */
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = DiggerMath.md512(uint256(sqrtPriceAX96), uint256(sqrtPriceBX96), Q96);
        return toUint128(DiggerMath.md512(amount0, intermediate, uint256(sqrtPriceBX96) - uint256(sqrtPriceAX96)));
    }

    /**
     * @notice Liquidity implied by a currency1 (token) amount over a price range.
     * @param sqrtPriceAX96 One end of the price range (order-independent).
     * @param sqrtPriceBX96 Other end of the price range (order-independent).
     * @param amount1 token1 amount available.
     * @return Floored liquidity corresponding to `amount1` over the range.
     */
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return toUint128(DiggerMath.md512(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice Like {getLiquidityForAmount1} but rounds liquidity up — used when seeding
     *         the full fixed supply so no tokens strand on the launchpad.
     * @param sqrtPriceAX96 One end of the price range (order-independent).
     * @param sqrtPriceBX96 Other end of the price range (order-independent).
     * @param amount1 token1 amount that must be fully absorbed.
     * @return Ceiled liquidity corresponding to `amount1` over the range.
     */
    function getLiquidityForAmount1Up(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return toUint128(DiggerMath.md512Up(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice ETH amount represented by a liquidity figure over a price range.
     * @param sqrtLowerX96 Lower sqrt price of the range.
     * @param sqrtUpperX96 Upper sqrt price of the range.
     * @param liquidity Liquidity figure to convert.
     * @return token0 (WETH) amount held by `liquidity` over the range.
     */
    function getAmount0ForLiquidity(uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (sqrtLowerX96 > sqrtUpperX96) (sqrtLowerX96, sqrtUpperX96) = (sqrtUpperX96, sqrtLowerX96);
        return DiggerMath.md512(
            DiggerMath.md512(uint256(liquidity), Q96, uint256(sqrtUpperX96)),
            uint256(sqrtUpperX96) - uint256(sqrtLowerX96),
            uint256(sqrtLowerX96)
        );
    }

    /**
     * @notice Token amount represented by a liquidity figure over a price range.
     * @param sqrtLowerX96 Lower sqrt price of the range.
     * @param sqrtUpperX96 Upper sqrt price of the range.
     * @param liquidity Liquidity figure to convert.
     * @return token1 amount held by `liquidity` over the range.
     */
    function getAmount1ForLiquidity(uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (sqrtLowerX96 > sqrtUpperX96) (sqrtLowerX96, sqrtUpperX96) = (sqrtUpperX96, sqrtLowerX96);
        return DiggerMath.md512(uint256(liquidity), uint256(sqrtUpperX96) - uint256(sqrtLowerX96), Q96);
    }

    /**
     * @notice Both currency amounts held by a position at the current price.
     * @dev Below range → all ETH; above range → all tokens; in range → split at spot.
     *      A fresh Diggers launch sits exactly at the upper edge (spot == upper bound), so
     *      the whole supply is token-side.
     * @param sqrtPriceX96 Current pool sqrt price.
     * @param sqrtLowerX96 Position lower sqrt price.
     * @param sqrtUpperX96 Position upper sqrt price.
     * @param liquidity Position liquidity.
     * @return amount0 token0 (WETH) held at `sqrtPriceX96`.
     * @return amount1 token1 held at `sqrtPriceX96`.
     */
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = getAmount0ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        } else if (sqrtPriceX96 >= sqrtUpperX96) {
            amount1 = getAmount1ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        } else {
            amount0 = getAmount0ForLiquidity(sqrtPriceX96, sqrtUpperX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtLowerX96, sqrtPriceX96, liquidity);
        }
    }

    /**
     * @notice Checked uint256 → uint128 downcast.
     * @param value Value to downcast.
     * @return value as uint128 (reverts {CastOverflow} on truncation).
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert CastOverflow();
        return uint128(value);
    }

    // ----------------------------------------------------------- swap quoting
    //
    // Reproduces the exact SqrtPriceMath/SwapMath step the pool runs inside the current
    // tick's active liquidity. For Diggers pools — a single protocol position spanning
    // [floorTick, startTick] — no swap can cross an initialized tick without draining the
    // pool, so the single-step quote is exact within rounding-dust tolerance.

    /**
     * @notice New sqrt price after adding amount0, rounded up (exact behaviour).
     * @param sqrtPX96 Current sqrt price.
     * @param liquidity Active liquidity.
     * @param amount0 token0 amount being added (fee-exclusive for quotes).
     * @return sqrtQX96 Next sqrt price after the amount0 step.
     */
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount0)
        internal
        pure
        returns (uint160 sqrtQX96)
    {
        if (amount0 == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << 96;

        unchecked {
            uint256 product = amount0 * uint256(sqrtPX96);
            if (product / amount0 == uint256(sqrtPX96)) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1) {
                    uint256 next = DiggerMath.md512Up(numerator1, uint256(sqrtPX96), denominator);
                    if (next > type(uint160).max) revert SqrtPriceOverflow();
                    return uint160(next);
                }
            }
            uint256 altDenominator = (numerator1 / uint256(sqrtPX96)) + amount0;
            uint256 result = numerator1 / altDenominator;
            if (numerator1 % altDenominator != 0) result += 1;
            if (result > type(uint160).max) revert SqrtPriceOverflow();
            return uint160(result);
        }
    }

    /**
     * @notice New sqrt price after adding amount1, rounded down (exact behaviour).
     * @param sqrtPX96 Current sqrt price.
     * @param liquidity Active liquidity.
     * @param amount1 token1 amount being added (fee-exclusive for quotes).
     * @return sqrtQX96 Next sqrt price after the amount1 step.
     */
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount1)
        internal
        pure
        returns (uint160 sqrtQX96)
    {
        if (amount1 == 0) return sqrtPX96;

        uint256 quotient = (amount1 <= type(uint160).max)
            ? (amount1 << 96) / uint256(liquidity)
            : DiggerMath.md512(amount1, Q96, uint256(liquidity));

        uint256 result = uint256(sqrtPX96) + quotient;
        if (result > type(uint160).max) revert SqrtPriceOverflow();
        return uint160(result);
    }

    /**
     * @notice Read-only exact-input quote: the bit-exact output of the swap the pool would
     *         execute right now, single-step within active liquidity.
     * @param pool The token's V3 pool.
     * @param poolFee LP fee in millionths (10000 for 1%).
     * @param zeroForOne Direction: true sells token0 (WETH) for token1 (the token).
     * @param amountIn Exact input, fee-inclusive.
     * @return amountOut Output the real swap would deliver.
     * @return sqrtPriceAfter Post-swap sqrt price.
     */
    function quoteExactInputSingle(address pool, uint24 poolFee, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint160 sqrtPriceAfter)
    {
        if (amountIn == 0) return (0, 0);

        Slot0 memory slot0 = getSlot0(pool);
        if (slot0.sqrtPriceX96 == 0) return (0, 0);

        uint128 liquidity = getPoolLiquidity(pool);
        if (liquidity == 0) return (0, 0);

        // Fee off the top, floored — identical to the pool's fee handling.
        uint256 amountInLessFee = DiggerMath.md512(amountIn, FEE_DENOMINATOR - uint256(poolFee), FEE_DENOMINATOR);

        if (zeroForOne) {
            sqrtPriceAfter = getNextSqrtPriceFromAmount0RoundingUp(slot0.sqrtPriceX96, liquidity, amountInLessFee);
            amountOut =
                DiggerMath.md512(uint256(liquidity), uint256(slot0.sqrtPriceX96) - uint256(sqrtPriceAfter), Q96);
        } else {
            sqrtPriceAfter = getNextSqrtPriceFromAmount1RoundingDown(slot0.sqrtPriceX96, liquidity, amountInLessFee);
            uint256 scaled = DiggerMath.md512(uint256(liquidity), Q96, uint256(sqrtPriceAfter));
            amountOut = DiggerMath.md512(
                scaled, uint256(sqrtPriceAfter) - uint256(slot0.sqrtPriceX96), uint256(slot0.sqrtPriceX96)
            );
        }
    }
}

/**
 * @title DiggerV3Base
 * @notice Abstract pool-operation host. The inheriting launchpad owns every V3 position
 *         and routes all pool interaction through create/seed, swap, and collect. WETH is
 *         pinned as token0 (the launchpad grinds the clone salt so `WETH < token`); native
 *         value wraps to WETH on the way into a pool and unwraps back out. There is no
 *         remove-liquidity operation — protocol liquidity is permanent.
 * @dev Both V3 callbacks authenticate the caller against a transient "expected pool" slot
 *      set for the duration of the mint/swap. Token1 (the launched token) is paid through
 *      the abstract {_transferToken} hook (which the launchpad routes to an approve-free
 *      seller pull on sells); token0 (WETH) is paid from the launchpad's own wrapped
 *      balance. Diggers inherits this base; domain libs that mint via delegatecall arm the
 *      same EIP-1153 slot key (`diggers.v3.callbackPool`).
 * @author BasedDopamine
 */
abstract contract DiggerV3Base {
    /// @notice The Uniswap V3 factory; fixed for the contract's lifetime.
    address public immutable V3_FACTORY;

    /// @notice The quote token — token0 of every Diggers pool. A classic wrapped-native
    ///         (WETH9 on Robinhood) or a dual-native token (USDT0 on Stable, whose ERC-20
    ///         interface shares ONE balance with native gas).
    address public immutable WETH;

    /// @notice wei-per-pool-unit scale for the quote side: 10^(18 − quoteDecimals). 1 on
    ///         Robinhood (18-dec WETH), 1e12 on Stable (6-dec USDT0). Pool-boundary amounts
    ///         (swap/mint/collect legs) are units; the whole external + accounting surface
    ///         stays 18-dec wei so points/volume/thresholds are identical across chains.
    uint256 public immutable QUOTE_SCALE;

    /// @notice True when the quote token IS the native gas token on one shared balance
    ///         (Stable's USDT0): `deposit`/`withdraw` don't exist — an ERC-20 transfer
    ///         debits native directly, and receiving pool payouts credits native directly.
    bool public immutable DUAL_NATIVE;

    /// @dev The 1% fee tier (millionths) every Diggers pool uses.
    uint24 internal constant POOL_FEE = 10000;

    /// @notice Constructor received a zero factory or WETH address.
    error FactoryRequired();
    /// @notice Quote decimals above 18, or a sub-18-dec quote without dual-native mode
    ///         (a non-1:1 wrapper has no defined deposit semantics — unsupported).
    error QuoteConfigInvalid();
    /// @notice A V3 callback fired outside an in-progress pool op, or from the wrong pool.
    error UnauthorizedCallback();
    /// @notice Swap input of zero.
    error ZeroSwapAmount();
    /// @notice Swap output fell below the caller's minimum.
    error Slippage();
    /// @notice A raw native transfer failed.
    error NativeTransferFailed();
    /// @notice WETH payment to the pool failed.
    error WethTransferFailed();

    /**
     * @notice Wires the immutable V3 factory, quote token, and decimal/dual-native mode.
     * @param v3Factory Canonical Uniswap V3 factory.
     * @param weth Quote token (token0 of every Diggers pool).
     * @param quoteDecimals Quote token decimals (≤ 18; must be 18 unless dualNative).
     * @param dualNative True when quote ERC-20 shares the native gas balance.
     */
    constructor(address v3Factory, address weth, uint8 quoteDecimals, bool dualNative) {
        if (v3Factory == address(0) || weth == address(0)) revert FactoryRequired();
        if (quoteDecimals > 18 || (!dualNative && quoteDecimals != 18)) revert QuoteConfigInvalid();
        V3_FACTORY = v3Factory;
        WETH = weth;
        QUOTE_SCALE = 10 ** (18 - quoteDecimals);
        DUAL_NATIVE = dualNative;
    }

    // -------------------------------------------------- transient callback pool

    /**
     * @dev Transient slot holding the pool authorized to fire a callback right now.
     * @return EIP-1153 key `keccak256(address(this) || "diggers.v3.callbackPool")`.
     */
    function _callbackPoolSlot() private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), "diggers.v3.callbackPool"));
    }

    /**
     * @dev Arms the transient callback-auth slot for `pool`.
     * @param pool Pool authorized to call back into this contract.
     */
    function _stashCallbackPool(address pool) private {
        bytes32 slot = _callbackPoolSlot();
        assembly {
            tstore(slot, pool)
        }
    }

    /**
     * @dev Reads the currently authorized callback pool (address(0) when idle).
     * @return pool Authorized pool, or zero outside an in-progress mint/swap.
     */
    function _loadCallbackPool() private view returns (address pool) {
        bytes32 slot = _callbackPoolSlot();
        assembly {
            pool := tload(slot)
        }
    }

    /// @dev Clears the transient callback-auth slot after a mint/swap completes.
    function _dropCallbackPool() private {
        bytes32 slot = _callbackPoolSlot();
        assembly {
            tstore(slot, 0)
        }
    }

    // ------------------------------------------------------------ pool creation

    /**
     * @dev Creates (or fetches) the WETH/token 1% pool and initializes it at `sqrtPriceX96`.
     *      WETH < token is guaranteed by the caller's salt grind, so token0 == WETH.
     * @param token Launched DiggersToken (token1).
     * @param sqrtPriceX96 Initial sqrt price for {IUniswapV3Pool.initialize}.
     * @return pool Created or fetched pool address.
     */
    function _initPoolV3(address token, uint160 sqrtPriceX96) internal returns (address pool) {
        pool = IUniswapV3Factory(V3_FACTORY).getPool(WETH, token, POOL_FEE);
        if (pool == address(0)) {
            pool = IUniswapV3Factory(V3_FACTORY).createPool(WETH, token, POOL_FEE);
        }
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    }

    // ------------------------------------------------------------ operations

    /**
     * @dev Mints `liquidity` into the launchpad's single position; the mint callback pays
     *      the owed token1 (via {_transferToken}) and any owed token0 (WETH from balance).
     * @param pool Token's V3 pool.
     * @param token Launched DiggersToken (passed through callback data).
     * @param tickLower Position lower tick.
     * @param tickUpper Position upper tick.
     * @param liquidity Liquidity delta to mint.
     * @return amount0 token0 paid to the pool.
     * @return amount1 token1 paid to the pool.
     */
    function _mintV3(address pool, address token, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        _stashCallbackPool(pool);
        (amount0, amount1) = IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, abi.encode(token));
        _dropCallbackPool();
    }

    /**
     * @dev Best-effort add-liquidity into the launchpad's position — `pool.mint` with the
     *      SAME owner + range only ever increases the existing position. The whole call is
     *      try/caught so a mint problem (rounding shortfall, weird pool state) can NEVER
     *      revert the carrying operation; on failure the caller keeps its full budget.
     * @param pool Token's V3 pool.
     * @param token Launched DiggersToken (passed through callback data).
     * @param tickLower Position lower tick.
     * @param tickUpper Position upper tick.
     * @param liquidity Liquidity delta to attempt.
     * @return ok True iff the mint succeeded.
     * @return amount0 token0 consumed on success (0 on failure).
     * @return amount1 token1 consumed on success (0 on failure).
     */
    function _tryMintV3(address pool, address token, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (bool ok, uint256 amount0, uint256 amount1)
    {
        _stashCallbackPool(pool);
        try IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, abi.encode(token)) returns (
            uint256 used0, uint256 used1
        ) {
            ok = true;
            amount0 = used0;
            amount1 = used1;
        } catch {}
        _dropCallbackPool();
    }

    /**
     * @dev Pokes then collects all accrued fees to the launchpad, unwrapping the quote side
     *      back to native (a no-op in dual-native mode — the ERC-20 payout already credited
     *      the launchpad's native balance). Returns (native fee WEI, token fee amount).
     * @param pool Token's V3 pool.
     * @param tickLower Position lower tick.
     * @param tickUpper Position upper tick.
     * @return ethFees Collected quote fees in native wei (units × QUOTE_SCALE).
     * @return tokenFees Collected token1 fees (18-dec raw units).
     */
    function _collectFeesV3(address pool, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256 ethFees, uint256 tokenFees)
    {
        // burn(0) is the canonical fee poke: removes no liquidity, refreshes tokensOwed.
        IUniswapV3Pool(pool).burn(tickLower, tickUpper, 0);
        (uint128 collected0, uint128 collected1) = IUniswapV3Pool(pool).collect(
            address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max
        );
        tokenFees = uint256(collected1); // token1 == launched token
        if (collected0 > 0 && !DUAL_NATIVE) IWETH9(WETH).withdraw(collected0);
        ethFees = uint256(collected0) * QUOTE_SCALE; // pool units -> wei
    }

    /**
     * @notice Executes an exact-input swap with an output floor, delivering to `recipient`
     *         in the caller's expected currency (tokens on a buy, native WEI on a sell).
     * @dev Amounts cross the wei⇄pool-unit boundary here: buy inputs floor to units (any
     *      sub-unit wei remainder is donated to the token's buyback pot so nothing strands
     *      on the launchpad); sell outputs scale back up to wei. In dual-native mode there
     *      is no wrap/unwrap — the quote ERC-20 and native gas are one balance.
     * @param pool The token's V3 pool.
     * @param token The launched token (token1); passed to the callback for the pay leg.
     * @param zeroForOne true = quote in / tokens out (buy); false = tokens in / quote out (sell).
     * @param amountIn Exact input, fee-inclusive — native WEI on a buy, tokens on a sell.
     * @param recipient Output destination.
     * @param minAmountOut Revert floor for the output (0 disables — tests only).
     * @return result `{amountIn, amountOut}` in the external wei/token surface.
     */
    function _swapV3(
        address pool,
        address token,
        bool zeroForOne,
        uint256 amountIn,
        address recipient,
        uint256 minAmountOut
    ) internal returns (DiggerV3.SwapOutcome memory result) {
        if (amountIn == 0) revert ZeroSwapAmount();

        uint256 swapAmountIn = amountIn;
        if (zeroForOne) {
            // wei -> pool units. The sub-unit remainder can't enter the pool; park it on
            // the token (its buyback pot) so the launchpad keeps nothing.
            swapAmountIn = amountIn / QUOTE_SCALE;
            if (swapAmountIn == 0) revert ZeroSwapAmount();
            uint256 dust = amountIn - swapAmountIn * QUOTE_SCALE;
            if (dust > 0) _sendNative(token, dust);
            // Wrap the input so the callback can pay the pool. Dual-native quote tokens
            // spend the launchpad's native balance directly through their ERC-20 transfer.
            if (!DUAL_NATIVE) IWETH9(WETH).deposit{value: swapAmountIn}();
        }

        // Buys deliver tokens straight to the recipient; sells route the quote side to the
        // launchpad so it can unwrap (when needed) and forward native wei.
        address swapRecipient = zeroForOne ? recipient : address(this);

        uint160 limit = zeroForOne ? DiggerV3.MIN_SQRT_RATIO + 1 : DiggerV3.MAX_SQRT_RATIO - 1;

        _stashCallbackPool(pool);
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(swapRecipient, zeroForOne, int256(swapAmountIn), limit, abi.encode(token));
        _dropCallbackPool();

        if (zeroForOne) {
            result.amountIn = amount0 > 0 ? uint256(amount0) * QUOTE_SCALE : 0; // quote wei in
            result.amountOut = amount1 < 0 ? uint256(-amount1) : 0; // tokens out
        } else {
            result.amountIn = amount1 > 0 ? uint256(amount1) : 0; // tokens paid in
            uint256 quoteOutUnits = amount0 < 0 ? uint256(-amount0) : 0;
            result.amountOut = quoteOutUnits * QUOTE_SCALE; // wei
            if (quoteOutUnits > 0) {
                if (!DUAL_NATIVE) IWETH9(WETH).withdraw(quoteOutUnits);
                if (recipient != address(this)) _sendNative(recipient, result.amountOut);
            }
        }

        if (result.amountOut < minAmountOut) revert Slippage();
    }

    // -------------------------------------------------------------- callbacks

    /**
     * @notice Uniswap V3 mint callback: pay the pool the token amounts it is owed.
     * @dev Fires only during {_mintV3}. token0 == WETH (from balance), token1 == the
     *      launched token (via {_transferToken}).
     * @param amount0Owed token0 the pool is owed.
     * @param amount1Owed token1 the pool is owed.
     * @param data ABI-encoded launched-token address.
     */
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        address expected = _loadCallbackPool();
        if (expected == address(0) || msg.sender != expected) revert UnauthorizedCallback();
        address token = abi.decode(data, (address));
        if (amount0Owed > 0) _payWeth(msg.sender, amount0Owed);
        if (amount1Owed > 0) _transferToken(token, msg.sender, amount1Owed);
    }

    /**
     * @notice Uniswap V3 swap callback: pay the pool the input it is owed.
     * @dev Fires only during {_swapV3}. A positive delta on the WETH side pays from the
     *      launchpad's wrapped balance; a positive delta on the token side pays through
     *      {_transferToken} (approve-free seller pull on sells).
     * @param amount0Delta token0 delta (positive = this contract must pay).
     * @param amount1Delta token1 delta (positive = this contract must pay).
     * @param data ABI-encoded launched-token address.
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address expected = _loadCallbackPool();
        if (expected == address(0) || msg.sender != expected) revert UnauthorizedCallback();
        address token = abi.decode(data, (address));
        if (amount0Delta > 0) _payWeth(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) _transferToken(token, msg.sender, uint256(amount1Delta));
    }

    // ---------------------------------------------------------------- helpers

    /**
     * @dev Pays WETH from the launchpad's balance to the calling pool.
     * @param pool Pool receiving the WETH transfer.
     * @param amount WETH amount to pay.
     */
    function _payWeth(address pool, uint256 amount) private {
        if (!IWETH9(WETH).transfer(pool, amount)) revert WethTransferFailed();
    }

    /**
     * @dev Sends raw native value, bubbling a clean error on failure.
     * @param to Recipient of the native transfer.
     * @param amount Wei to send.
     */
    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /**
     * @notice Token1 transfer hook the launchpad must provide; moves the launched token to
     *         the pool during seeding and sells (approve-free seller pull on sells).
     * @param token Launched DiggersToken.
     * @param to Destination (typically the calling pool).
     * @param amount Token amount to transfer.
     */
    function _transferToken(address token, address to, uint256 amount) internal virtual;
}
