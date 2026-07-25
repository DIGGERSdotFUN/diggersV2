// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggerMath
 * @notice Full-precision multiply-divide helpers used by every share, fee, and points
 *         computation in the Diggers protocol. The core routine keeps the 512-bit
 *         intermediate product of `a * b`, so ratios never lose precision or overflow
 *         before the division lands (same construction as Uniswap's FullMath).
 * @dev Pure internal library — inlines into callers (`DiggersToken` points/volume,
 *      `DiggerHarvestLib` / `DiggerHarvestMath` fee splits, `DiggerV3` liquidity and
 *      quote math, buyback / graduation / TWAP conversions). Prefer `md512` when the
 *      protocol should round down; `md512Up` when amounts owed to the pool must round
 *      up. All protocol percentages remain 1e18-scaled WAD ratios through these helpers.
 * @author BasedDopamine
 */
library DiggerMath {
    /// @notice The quotient does not fit a uint256, or the denominator is zero.
    error MulDivOverflow();

    /// @notice Ceil rounding would push the result past uint256 max.
    error CeilOverflow();

    /**
     * @notice Computes floor(a * b / denominator) at full 512-bit precision.
     * @dev Rounds toward zero. Reverts with MulDivOverflow when denominator == 0 or the
     *      true quotient needs more than 256 bits. Callers pick this floor variant
     *      whenever rounding in the protocol's favor means rounding DOWN (payouts,
     *      points, fee credits).
     * @param a Multiplicand.
     * @param b Multiplier.
     * @param denominator Divisor.
     * @return result floor(a * b / denominator).
     */
    function md512(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // Split the raw product into a 512-bit value [high | low] using the
            // mulmod(-1) trick: mm - low (mod 2^256) recovers the high limb.
            uint256 low;
            uint256 high;
            assembly {
                let mm := mulmod(a, b, not(0))
                low := mul(a, b)
                high := sub(sub(mm, low), lt(mm, low))
            }

            // The quotient fits 256 bits only if high < denominator. This also rejects
            // denominator == 0 in the same comparison.
            if (denominator <= high) revert MulDivOverflow();

            // Fast path: the product never left 256 bits.
            if (high == 0) {
                assembly {
                    result := div(low, denominator)
                }
                return result;
            }

            // Make the 512-bit value exactly divisible by subtracting the remainder.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }

            // Factor out the largest power of two from the denominator, shift the
            // 512-bit product by the same amount, and fold the high limb into the low
            // one. Skipping the fold would drop the high bits whenever a*b >= 2^256.
            uint256 pow2 = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, pow2)
                low := div(low, pow2)
                // pow2 becomes 2^256 / pow2, the shift that repositions the high limb.
                pow2 := add(div(sub(0, pow2), pow2), 1)
            }
            low |= high * pow2;

            // Newton-Raphson inverse of the (now odd) denominator mod 2^256. Six
            // doubling steps: 8 -> 16 -> 32 -> 64 -> 128 -> 256 bits of accuracy.
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            // Exact division: multiply by the modular inverse.
            result = low * inverse;
            return result;
        }
    }

    /**
     * @notice Computes ceil(a * b / denominator) at full 512-bit precision.
     * @dev Same domain as md512; additionally reverts with CeilOverflow when the floor
     *      result is already uint256 max and a nonzero remainder would round past it.
     *      Callers pick this ceil variant when rounding in the protocol's favor means
     *      rounding UP (amounts owed to the pool).
     * @param a Multiplicand.
     * @param b Multiplier.
     * @param denominator Divisor.
     * @return result ceil(a * b / denominator).
     */
    function md512Up(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = md512(a, b, denominator);
            if (mulmod(a, b, denominator) > 0) {
                if (result >= type(uint256).max) revert CeilOverflow();
                result++;
            }
        }
    }
}
