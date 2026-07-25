// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3, IUniswapV3Pool} from "./DiggerV3.sol";
import {DiggerMath} from "./DiggerMath.sol";
import {IDiggersToken} from "../interfaces/IDiggersToken.sol";

/**
 * @title DiggerGraduationMath
 * @notice Pure graduation + blue-chip criteria.
 *
 *         GRADUATION is a single supply-sold criterion (pump.fun-style): a token
 *         graduates once enough of the fixed 1e9 supply has been bought OUT of its pool —
 *         `token.balanceOf(pool) <= gradPoolBalance`, where the threshold is
 *         `TOTAL_SUPPLY x (1 - gradSoldWad)` fixed at deploy (production: 80% sold, which
 *         on the launch curve implies a ~25x price multiple / ~$70K market cap). A pure
 *         balance read: no oracle, price-path independent, and foreign LP positions can
 *         only ADD tokens to the pool — they make the bar harder, never easier.
 *
 *         BLUE CHIP is market-derived and LIVE: lifetime volume (monotone — an acquisition
 *         bar that can never un-pass) + mean daily-close tick market cap + holder count
 *         (both live — the demotion vectors). Dormant until graduation (the launchpad
 *         never evaluates it for an ungraduated token). No oracle; pure pool telemetry.
 *
 *         All thresholds are supplied by the launchpad (chain-parameterized:
 *         USDT0-denominated on Stable, ETH-denominated on Robinhood), so this library
 *         stays chain-agnostic.
 * @dev `internal` on purpose so these inline into whichever library links them, keeping
 *      them off the `Diggers` singleton runtime. Consumed by {DiggerGraduationLib}
 *      (delegatecall orchestration) and by DiggersHub progress views that reconstruct the
 *      same inputs from raw extsload slots — one shared evaluator, two hosts.
 * @author BasedDopamine
 */
library DiggerGraduationMath {
    /// @dev Fixed launch supply — must match DiggersToken.TOTAL_SUPPLY.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /**
     * @notice The launchpad's own position liquidity. No longer a graduation input —
     *         kept for pool telemetry views (foreign positions never enter this read).
     * @param pool The token's V3 pool.
     * @param owner The position owner (the launchpad).
     * @param tickLower Position lower tick (from the token's record).
     * @param tickUpper Position upper tick (from the token's record).
     * @return liquidity The launchpad position's current liquidity (0 if unset).
     */
    function ownLiquidity(address pool, address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        (liquidity,,,,) = IUniswapV3Pool(pool).positions(DiggerV3.positionKey(owner, tickLower, tickUpper));
    }

    /**
     * @notice Graduation criterion: enough of the supply has been SOLD out of the pool —
     *         `token.balanceOf(pool) <= gradPoolBalance`, i.e. circulating (bought or
     *         burned) supply reached the chain-parameterized sold fraction. Pump.fun-style:
     *         a pure balance read, price-path independent, foreign LP invisible (foreign
     *         mints only ADD tokens to the pool, making the bar harder, never easier).
     * @param token The launched DiggersToken.
     * @param pool The token's V3 pool.
     * @param gradPoolBalance Pool-balance threshold: TOTAL_SUPPLY x (1 - soldWad) (raw).
     * @return ok True iff the pool balance fell to (or below) the threshold.
     * @return poolBalance The pool's current token balance (raw units).
     */
    function evaluateGraduation(address token, address pool, uint256 gradPoolBalance)
        internal
        view
        returns (bool ok, uint256 poolBalance)
    {
        poolBalance = IDiggersToken(token).balanceOf(pool);
        ok = poolBalance <= gradPoolBalance;
    }

    /**
     * @notice Market cap (native WEI) implied by a mean daily-close tick.
     * @dev `mcap = TOTAL_SUPPLY × weiPerToken`, where `quoteScale` (wei per pool unit:
     *      1 on Robinhood, 1e12 on Stable) folds into the inverse-price fixed point
     *      itself, so mcap thresholds carry the same 18-dec scale on every chain without
     *      precision loss. Returns 0 for a zero price.
     * @param meanTick Mean of the recorded daily-close ticks.
     * @param quoteScale Wei per pool unit (1 on Robinhood, 1e12 on Stable).
     * @return mcap Implied market cap in native wei (0 when price is zero).
     */
    function mcapAtTick(int24 meanTick, uint256 quoteScale) internal pure returns (uint256 mcap) {
        uint160 sqrtP = DiggerV3.getSqrtRatioAtTick(meanTick);
        uint256 weiPerToken = DiggerV3.sqrtPriceToInversePrice(sqrtP, quoteScale); // 1e18-scaled wei
        mcap = DiggerMath.md512(TOTAL_SUPPLY, weiPerToken, 1e18);
    }

    /**
     * @notice Mean-tick market cap over the tracked days (0 when no price data yet).
     * @param meanTick Mean of the recorded daily closes.
     * @param daysTracked Non-empty days that entered the mean (0 ⇒ no mcap yet).
     * @param quoteScale Wei per pool unit (see {mcapAtTick}).
     * @return Implied mean-tick market cap in native wei, or 0 when `daysTracked == 0`.
     */
    function meanMcap(int24 meanTick, uint16 daysTracked, uint256 quoteScale) internal pure returns (uint256) {
        return daysTracked == 0 ? 0 : mcapAtTick(meanTick, quoteScale);
    }

    /**
     * @notice Blue-chip criteria with DUAL-SIDED mcap bars: promotion needs lifetime
     *         volume ≥ `bcVolume` AND mean-tick mcap ≥ `bcMcapHi` AND holders ≥
     *         `bcHolders`; demotion retention only needs mcap ≥ `bcMcapLo` (+ holders).
     *         On USD-oracle chains hi/lo come from the hardest/easiest stable conversion
     *         (hysteresis band); everywhere else they are equal and this degenerates to
     *         the single-bar check. Volume is monotone — never re-checked on demotion.
     * @param holders Current unique pool-verified holder count.
     * @param volumeEth Lifetime native-equivalent volume (wei).
     * @param meanTick Mean of the recorded daily closes.
     * @param daysTracked Non-empty days that entered the mean.
     * @param bcVolume Blue-chip volume threshold (native wei; promotion side).
     * @param bcMcapHi Blue-chip market-cap PROMOTION threshold (native wei).
     * @param bcMcapLo Blue-chip market-cap RETENTION threshold (native wei; ≤ hi).
     * @param bcHolders Blue-chip holder-count threshold (production 500).
     * @param quoteScale wei per pool unit (see {mcapAtTick}).
     * @return promoteOk True iff all three promotion legs pass (hard bars).
     * @return mcap The implied mean-tick market cap (native wei).
     * @return volumePass Volume criterion flag (promotion side).
     * @return mcapPassHi Market-cap PROMOTION flag (hard bar).
     * @return mcapPassLo Market-cap RETENTION flag — demote only when this fails.
     * @return holdersPass Holder-count criterion flag (live, both directions).
     */
    function evaluateBlueChip(
        uint32 holders,
        uint256 volumeEth,
        int24 meanTick,
        uint16 daysTracked,
        uint256 bcVolume,
        uint256 bcMcapHi,
        uint256 bcMcapLo,
        uint32 bcHolders,
        uint256 quoteScale
    )
        internal
        pure
        returns (bool promoteOk, uint256 mcap, bool volumePass, bool mcapPassHi, bool mcapPassLo, bool holdersPass)
    {
        mcap = meanMcap(meanTick, daysTracked, quoteScale);
        volumePass = volumeEth >= bcVolume;
        mcapPassHi = daysTracked != 0 && mcap >= bcMcapHi;
        mcapPassLo = daysTracked != 0 && mcap >= bcMcapLo;
        holdersPass = holders >= bcHolders;
        promoteOk = volumePass && mcapPassHi && holdersPass;
    }
}
