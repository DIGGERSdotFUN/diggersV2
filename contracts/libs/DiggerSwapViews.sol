// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3} from "./DiggerV3.sol";

/**
 * @title DiggerSwapViews
 * @notice Post-trade pool reads for the rich `Swapped` event. Deployed as a linked library
 *         so swap hot paths stay out of the `Diggers` runtime.
 * @dev Called from `Diggers` (and mirrored on `DiggersHub`) immediately after a swap to
 *      populate sqrtPrice / tick / liquidity / virtual reserves on `Swapped`. Virtual
 *      reserves are derived from active liquidity over the seed range
 *      `[startTick, maxTick]` via {DiggerV3.getAmountsForLiquidity} — the same single-
 *      sided band minted at create — not from ERC-20 balances.
 * @author BasedDopamine
 */
library DiggerSwapViews {
    /// @notice Snapshot of pool slot0 + active liquidity + virtual reserves in the seed range.
    struct State {
        /// @notice Current pool sqrt price (X96).
        uint160 sqrtPriceX96;
        /// @notice Current pool tick.
        int24 tick;
        /// @notice Active in-range liquidity.
        uint128 liquidity;
        /// @notice Virtual quote (currency0 / WETH) amount for `liquidity` in `[startTick, maxTick]`.
        uint256 ethInPool;
        /// @notice Virtual token (currency1) amount for `liquidity` in `[startTick, maxTick]`.
        uint256 tokenInPool;
    }

    /**
     * @notice Slot0, liquidity, and virtual reserves after a swap.
     * @dev Reads live slot0 + liquidity, then converts active L into virtual amounts over
     *      the create-time tick band. Safe as a view — no state writes.
     * @param pool Uniswap V3 pool address for the digger token.
     * @param startTick Lower tick of the seed liquidity range (spacing-aligned).
     * @param maxTick Upper tick of the seed liquidity range (typically `MAX_TICK` aligned).
     * @return s Bundled post-trade pool state for the `Swapped` event payload.
     */
    function afterSwap(address pool, int24 startTick, int24 maxTick) external view returns (State memory s) {
        DiggerV3.Slot0 memory slot0 = DiggerV3.getSlot0(pool);
        s.sqrtPriceX96 = slot0.sqrtPriceX96;
        s.tick = slot0.tick;
        s.liquidity = DiggerV3.getPoolLiquidity(pool);
        uint160 sqrtStart = DiggerV3.getSqrtRatioAtTick(startTick);
        uint160 sqrtMax = DiggerV3.getSqrtRatioAtTick(maxTick);
        (s.ethInPool, s.tokenInPool) =
            DiggerV3.getAmountsForLiquidity(s.sqrtPriceX96, sqrtStart, sqrtMax, s.liquidity);
    }
}
