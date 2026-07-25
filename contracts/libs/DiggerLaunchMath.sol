// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3} from "./DiggerV3.sol";

/**
 * @title DiggerLaunchMath
 * @notice Pure helpers for deriving the spacing-aligned launch tick off-chain or in deploy
 *         harnesses. Kept out of `Diggers` runtime to save bytecode.
 * @dev Internal-only tick utilities wrapping {DiggerV3.getSqrtRatioAtTick}. Launch seeding
 *      needs a spacing-aligned `startTick` whose sqrt price is ≤ the constant pump.fun-like
 *      start price; these helpers recover that tick via binary search then floor-align to
 *      the pool fee tier's tick spacing. Not linked into the hot create path — deploy /
 *      config tooling and tests call them directly.
 * @author BasedDopamine
 */
library DiggerLaunchMath {
    /**
     * @notice Spacing-aligned tick whose sqrt ratio is ≤ `sqrtPriceX96`.
     * @dev Composes {tickFromSqrt} then {alignTickDown}. The resulting tick is safe to
     *      use as the lower edge of the single-sided seed range.
     * @param sqrtPriceX96 Target sqrt price (X96) at launch.
     * @param spacing Pool tick spacing (fee-tier multiple).
     * @return The largest spacing-aligned tick with sqrt(tick) ≤ `sqrtPriceX96`.
     */
    function alignedStartTick(uint160 sqrtPriceX96, int24 spacing) internal pure returns (int24) {
        return alignTickDown(tickFromSqrt(sqrtPriceX96), spacing);
    }

    /**
     * @notice Rounds a tick down to the nearest spacing multiple (toward −∞).
     * @dev Remainder is `tick % spacing` in Solidity (toward zero for positive ticks);
     *      subtracting `r` floors toward −∞ for the positive ticks used at launch.
     * @param tick Raw tick to align.
     * @param spacing Pool tick spacing (fee-tier multiple).
     * @return The greatest multiple of `spacing` that is ≤ `tick`.
     */
    function alignTickDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r == 0) return tick;
        return tick - r;
    }

    /**
     * @notice Largest tick whose sqrt ratio is ≤ `sqrtPriceX96` (binary search).
     * @dev Searches the Uniswap V3 tick domain `[-887272, 887272]` with an upper-biased
     *      midpoint so the loop converges on the floor tick under `sqrtPriceX96`.
     * @param sqrtPriceX96 Target sqrt price (X96).
     * @return tick The greatest tick with `getSqrtRatioAtTick(tick) ≤ sqrtPriceX96`.
     */
    function tickFromSqrt(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        int24 lo = -887272;
        int24 hi = 887272;
        while (lo < hi) {
            int24 mid = int24((int256(lo) + int256(hi) + 1) / 2);
            if (DiggerV3.getSqrtRatioAtTick(mid) <= sqrtPriceX96) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
}
