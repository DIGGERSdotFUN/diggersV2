// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3} from "./DiggerV3.sol";

/**
 * @title DiggerLaunchLiquidity
 * @notice Create-time liquidity search kept out of the `Diggers` runtime.
 * @dev Linked external library used by {DiggerCreateLib} when seeding the full
 *      `TOKEN_SUPPLY` as single-sided token1 liquidity over `[sqrtLower, sqrtUpper]`.
 *      `getLiquidityForAmount1Up` can overshoot the exact budget after ceil rounding, so
 *      this binary-searches the largest `uint128` liquidity whose `getAmount1ForLiquidity`
 *      still fits inside the mint budget — keeping create-path bytecode off the singleton.
 * @author BasedDopamine
 */
library DiggerLaunchLiquidity {
    /**
     * @notice Maximum liquidity mintable without exceeding a token1 budget.
     * @dev Binary search over `[0, getLiquidityForAmount1Up(...)]`. Midpoints that fit the
     *      budget become the new lower bound; overshoots shrink the upper bound. Returns 0
     *      when no positive liquidity fits (degenerate / empty range).
     * @param sqrtLower Lower bound of the position's sqrt-price range (X96).
     * @param sqrtUpper Upper bound of the position's sqrt-price range (X96).
     * @param budget Maximum token1 (wei, 18-dec) that may be consumed by the mint.
     * @return The largest liquidity L such that amount1(L) ≤ `budget`.
     */
    function maxLiquidityForAmount1(uint160 sqrtLower, uint160 sqrtUpper, uint256 budget)
        external
        pure
        returns (uint128)
    {
        uint128 lo;
        uint128 hi = DiggerV3.getLiquidityForAmount1Up(sqrtLower, sqrtUpper, budget);
        uint128 best;
        while (lo <= hi) {
            uint128 mid = lo + (hi - lo) / 2;
            if (DiggerV3.getAmount1ForLiquidity(sqrtLower, sqrtUpper, mid) <= budget) {
                best = mid;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        return best;
    }
}
