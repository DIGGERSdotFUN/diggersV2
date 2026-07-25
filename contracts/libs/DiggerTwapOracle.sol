// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3, IUniswapV3Factory} from "./DiggerV3.sol";
import {DiggerMath} from "./DiggerMath.sol";
import {DiggerGraduationLib} from "./DiggerGraduationLib.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";
import {IDiggersHub} from "../interfaces/IDiggersHub.sol";

/**
 * @notice Oracle slice of the V3 pool ABI (kept out of {DiggerV3.IUniswapV3Pool} — only
 *         this library reads it).
 */
interface IUniswapV3PoolOracle {
    /**
     * @notice Returns the cumulative tick and liquidity-seconds observations at each
     *         lookback offset.
     * @param secondsAgos Array of seconds-ago timestamps to sample (e.g. `[window, 0]`).
     * @return tickCumulatives Tick accumulator at each sample.
     * @return secondsPerLiquidityCumulativeX128s Liquidity-seconds accumulator at each sample.
     */
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/**
 * @notice Minimal ERC-20 metadata read used once per asset registration.
 */
interface IERC20Decimals {
    /**
     * @notice Returns the token's decimal places.
     * @return Token decimals (must be ≤ 18 for Diggers oracle assets).
     */
    function decimals() external view returns (uint8);
}

/**
 * @title DiggerTwapOracle
 * @notice USD -> native-wei conversion of the blue-chip bars on ETH-quote chains,
 *         executed via `delegatecall` from `Diggers` (storage-pointer params resolve in
 *         the launchpad's context; no state lives here). Never used on NATIVE_USD
 *         deployments — there the bars already ARE dollars.
 *
 *         Per registered stable asset, the WETH/asset pools of the four canonical fee
 *         tiers are discovered LIVE through the immutable factory and the DEEPEST one is
 *         the price anchor: smallest secondsPerLiquidityCumulative delta over the window
 *         == highest harmonic-mean liquidity, which cannot be flashed (liquidity must sit
 *         in range for the whole 30 minutes to score) and prices out dust-tier injection
 *         (a permissionless outlier pool contributes NOTHING unless it out-liquidities
 *         the canonical pool at its fake price for the full window, bleeding to
 *         arbitrage the entire time). Pools younger than the window revert `OLD` inside
 *         `observe` and are skipped, so a fresh pool cannot even enter the race.
 *
 *         The two USD bars convert through the per-asset 30-min arithmetic-mean-tick
 *         price. Across assets the MIN and MAX conversions are both kept: promotion is
 *         checked against the hardest (max-wei) bar, demotion retention against the
 *         easiest (min-wei) — the USDC/USDT spread doubles as a hysteresis band.
 *
 *         A 1-hour lazy cache (two packed slots) keeps the ~150-250k discovery+TWAP cost
 *         off the hot path: one trade per hour refreshes, everything else reads two
 *         slots. A refresh that finds no healthy pool keeps the previous bars and simply
 *         re-arms the TTL; before the first successful fill the plain-ETH constructor
 *         bars serve as the fallback. NOTHING in here may revert a carrying trade: every
 *         external read is try/caught or trusted-immutable, and the remaining math is
 *         md512 against constant nonzero denominators plus bounded tick math.
 * @dev Feeds {DiggerGraduationLib.BlueChipBars} into every state-changing blue-chip path
 *      (`autoBlueChip`, explicit `blueChip` / `blueChipLost`). DiggersHub read views use
 *      the memory twin {previewBarsMem} so they never write launchpad storage.
 * @author BasedDopamine
 */
library DiggerTwapOracle {
    // ------------------------------------------------------------------- types

    /// @notice One registered oracle stable. `unit` is cached at registration so the hot
    ///         refresh never calls `decimals()` again.
    struct OracleAsset {
        address asset; // the stable ERC-20 paired against WETH
        uint96 unit; // 10^decimals — raw asset units per whole USD
    }

    /// @notice The converted-bar cache, two packed slots. All bar values are native wei,
    ///         clamped into uint96 (7.9e28 wei ≈ 79B ETH — unreachable).
    struct BarCache {
        uint96 volumeHi; // promotion volume bar (hardest conversion), wei
        uint96 mcapHi; // promotion mcap bar (hardest conversion), wei
        uint64 updatedAt; // last refresh or re-arm (seconds); 0 = never filled
        uint96 mcapLo; // demotion-retention mcap bar (easiest conversion), wei
    }

    /// @notice Chain wiring + every bar constant, bundled per call (all immutables on the
    ///         launchpad — cheaper to pass than to store). `nativeUsd` short-circuits the
    ///         whole oracle path so the mode branch lives HERE, off the singleton runtime.
    struct BarConfig {
        address factory; // canonical V3 factory (immutable, trusted)
        address weth; // the 18-dec native-wrapper quote of this chain
        bool nativeUsd; // true => bars ARE dollars, oracle path never taken
        uint256 volumeUsd; // blue-chip volume bar, USD 1e18
        uint256 mcapUsd; // blue-chip mcap bar, USD 1e18
        uint256 fallbackVolume; // ctor volume bar — THE bar when nativeUsd, wei fallback else
        uint256 fallbackMcap; // ctor mcap bar — THE bar when nativeUsd, wei fallback else
        uint32 holders; // blue-chip holder bar (currency-free, passed through)
        uint256 quoteScale; // wei per pool unit (passed through to the mcap math)
    }

    // ---------------------------------------------------------------- constants

    /// @dev TWAP lookback (seconds) — the manipulation-cost knob, independent of the TTL.
    uint32 internal constant TWAP_WINDOW = 30 minutes;

    /// @dev Bar-cache time-to-live (seconds) — the gas knob. Safe at a full hour because
    ///      the 24h name-unlock grace makes a stale-bar wrongful demotion self-healing.
    uint64 internal constant CACHE_TTL = 1 hours;

    /// @dev Registered-asset ceiling: bounds the refresh loop.
    uint256 internal constant MAX_ASSETS = 4;

    /// @dev The four canonical fee tiers probed per asset.
    uint24 private constant TIER_A = 100;
    uint24 private constant TIER_B = 500;
    uint24 private constant TIER_C = 3000;
    uint24 private constant TIER_D = 10000;

    // ------------------------------------------------------------- registration

    /**
     * @notice Registers a stable oracle asset: validates it, caches its unit, appends it.
     * @dev Reverts {NativeUsdMode} on USD-quote deployments (no oracle surface there),
     *      {OracleAssetsFull} past MAX_ASSETS, {OracleAssetInvalid} for the zero address,
     *      WETH itself, a duplicate, a non-ERC20 (failed `decimals()`), or decimals above
     *      18. Prints {IDiggersHub.OracleAssetAdded} through the hub.
     * @param list The launchpad's registered-asset array (storage).
     * @param nativeUsd The deployment's NATIVE_USD flag.
     * @param weth The chain's quote token — never a valid oracle asset.
     * @param asset The stable ERC-20 to register.
     * @param hub The DiggersHub event singleton.
     */
    function register(OracleAsset[] storage list, bool nativeUsd, address weth, address asset, address hub) external {
        if (nativeUsd) revert IDiggers.NativeUsdMode();
        if (asset == address(0) || asset == weth) revert IDiggers.OracleAssetInvalid();
        uint256 count = list.length;
        if (count >= MAX_ASSETS) revert IDiggers.OracleAssetsFull();
        for (uint256 i; i < count; ++i) {
            if (list[i].asset == asset) revert IDiggers.OracleAssetInvalid();
        }

        uint8 decimals;
        try IERC20Decimals(asset).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            revert IDiggers.OracleAssetInvalid();
        }
        if (decimals > 18) revert IDiggers.OracleAssetInvalid();

        uint96 unit = uint96(10 ** decimals);
        list.push(OracleAsset({asset: asset, unit: unit}));
        IDiggersHub(hub).logOracleAssetAdded(asset, unit);
    }

    /**
     * @notice Removes a registered oracle asset (swap-and-pop; order is irrelevant).
     * @dev Reverts {NativeUsdMode} on USD-quote deployments, {OracleAssetUnknown} when
     *      not registered. Prints {IDiggersHub.OracleAssetRemoved} through the hub.
     * @param list The launchpad's registered-asset array (storage).
     * @param nativeUsd The deployment's NATIVE_USD flag.
     * @param asset The stable ERC-20 to remove.
     * @param hub The DiggersHub event singleton.
     */
    function drop(OracleAsset[] storage list, bool nativeUsd, address asset, address hub) external {
        if (nativeUsd) revert IDiggers.NativeUsdMode();
        uint256 count = list.length;
        for (uint256 i; i < count; ++i) {
            if (list[i].asset != asset) continue;
            if (i != count - 1) list[i] = list[count - 1];
            list.pop();
            IDiggersHub(hub).logOracleAssetRemoved(asset);
            return;
        }
        revert IDiggers.OracleAssetUnknown();
    }

    // ------------------------------------------------------------------- bars

    /**
     * @notice The bars every STATE-CHANGING blue-chip path reads — cached, lazily
     *         refreshed. One source of truth: `autoBlueChip` after each trade and the
     *         explicit `blueChip`/`blueChipLost` all land here, so no caller can pick a
     *         momentarily-favorable price source. On NATIVE_USD deployments the
     *         constructor bars pass straight through, both mcap sides equal.
     * @dev Within the TTL: two SLOADs. Past it: full discovery+TWAP refresh; on success
     *      the cache re-fills, on total oracle failure the previous bars are kept and the
     *      TTL simply re-arms (a transient outage never re-charges every trade). Before
     *      the first successful fill the plain-ETH fallback bars are written instead.
     *      MUST NOT revert — see the library banner for why it cannot.
     * @param cache The launchpad's bar cache (storage).
     * @param list The registered oracle assets (storage).
     * @param cfg Chain wiring + bar constants.
     * @return bars The bundled thresholds for {DiggerGraduationLib}.
     */
    function tradeBars(BarCache storage cache, OracleAsset[] storage list, BarConfig memory cfg)
        external
        returns (DiggerGraduationLib.BlueChipBars memory bars)
    {
        bars.holders = cfg.holders;
        bars.quoteScale = cfg.quoteScale;
        if (cfg.nativeUsd) {
            bars.volume = cfg.fallbackVolume;
            bars.mcapHi = cfg.fallbackMcap;
            bars.mcapLo = cfg.fallbackMcap;
            return bars;
        }

        BarCache memory c = cache;
        if (c.updatedAt != 0 && block.timestamp < uint256(c.updatedAt) + CACHE_TTL) {
            bars.volume = c.volumeHi;
            bars.mcapHi = c.mcapHi;
            bars.mcapLo = c.mcapLo;
            return bars;
        }

        (uint256 perUsdLo, uint256 perUsdHi, bool live) = _usdBounds(loadAssets(list), cfg);
        if (live) {
            bars.volume = DiggerMath.md512(cfg.volumeUsd, perUsdHi, 1e18);
            bars.mcapHi = DiggerMath.md512(cfg.mcapUsd, perUsdHi, 1e18);
            bars.mcapLo = DiggerMath.md512(cfg.mcapUsd, perUsdLo, 1e18);
        } else if (c.updatedAt == 0) {
            // Never filled: the plain-ETH constructor bars, both sides collapsed.
            bars.volume = cfg.fallbackVolume;
            bars.mcapHi = cfg.fallbackMcap;
            bars.mcapLo = cfg.fallbackMcap;
        } else {
            // Total outage on a filled cache: keep serving the previous bars.
            bars.volume = c.volumeHi;
            bars.mcapHi = c.mcapHi;
            bars.mcapLo = c.mcapLo;
        }

        cache.volumeHi = _clamp96(bars.volume);
        cache.mcapHi = _clamp96(bars.mcapHi);
        cache.mcapLo = _clamp96(bars.mcapLo);
        cache.updatedAt = uint64(block.timestamp);
    }

    /**
     * @notice Read-only, memory-based twin of {tradeBars} for the DiggersHub views
     *         (`progressOf`, `blueChipBars`): a FRESH conversion when the oracles answer
     *         (`live`), else the cached bars, else the plain-ETH fallback. Never writes.
     * @dev `internal` on purpose: the hub owns none of the launchpad's storage — it
     *      reconstructs the cache and the asset list from raw `extsload` slots and feeds
     *      them here as memory, compiling this body in.
     * @param c The launchpad's bar cache (memory snapshot).
     * @param list The registered oracle assets (memory snapshot).
     * @param cfg Chain wiring + bar constants.
     * @return bars The bundled thresholds for {DiggerGraduationLib}.
     * @return live Whether a fresh oracle conversion answered (false on NATIVE_USD).
     * @return updatedAt Last bar-cache write (0 = never; always 0 on NATIVE_USD).
     */
    function previewBarsMem(BarCache memory c, OracleAsset[] memory list, BarConfig memory cfg)
        internal
        view
        returns (DiggerGraduationLib.BlueChipBars memory bars, bool live, uint64 updatedAt)
    {
        bars.holders = cfg.holders;
        bars.quoteScale = cfg.quoteScale;
        if (cfg.nativeUsd) {
            bars.volume = cfg.fallbackVolume;
            bars.mcapHi = cfg.fallbackMcap;
            bars.mcapLo = cfg.fallbackMcap;
            return (bars, false, 0);
        }

        updatedAt = c.updatedAt;

        uint256 perUsdLo;
        uint256 perUsdHi;
        (perUsdLo, perUsdHi, live) = _usdBounds(list, cfg);
        if (live) {
            bars.volume = DiggerMath.md512(cfg.volumeUsd, perUsdHi, 1e18);
            bars.mcapHi = DiggerMath.md512(cfg.mcapUsd, perUsdHi, 1e18);
            bars.mcapLo = DiggerMath.md512(cfg.mcapUsd, perUsdLo, 1e18);
        } else if (c.updatedAt != 0) {
            bars.volume = c.volumeHi;
            bars.mcapHi = c.mcapHi;
            bars.mcapLo = c.mcapLo;
        } else {
            bars.volume = cfg.fallbackVolume;
            bars.mcapHi = cfg.fallbackMcap;
            bars.mcapLo = cfg.fallbackMcap;
        }
    }

    /**
     * @dev Materializes the registered-asset array (bounded at MAX_ASSETS = 4).
     * @param list The launchpad's registered-asset array (storage).
     * @return arr Memory copy of every registered {OracleAsset}.
     */
    function loadAssets(OracleAsset[] storage list) internal view returns (OracleAsset[] memory arr) {
        uint256 count = list.length;
        arr = new OracleAsset[](count);
        for (uint256 i; i < count; ++i) {
            arr[i] = list[i];
        }
    }

    // ---------------------------------------------------------------- internals

    /**
     * @dev MIN and MAX wei-per-USD conversion across the registered assets' anchors.
     *      `live` is false when no pool of any asset answered (skip-everything case).
     * @param list Registered oracle assets (memory).
     * @param cfg Chain wiring (factory + weth).
     * @return perUsdLo Easiest (min) native-wei-per-USD conversion across live assets.
     * @return perUsdHi Hardest (max) native-wei-per-USD conversion across live assets.
     * @return live True iff at least one asset returned a nonzero conversion.
     */
    function _usdBounds(OracleAsset[] memory list, BarConfig memory cfg)
        private
        view
        returns (uint256 perUsdLo, uint256 perUsdHi, bool live)
    {
        uint256 count = list.length;
        for (uint256 i; i < count; ++i) {
            uint256 perUsd = _weiPerUsd(list[i], cfg.factory, cfg.weth);
            if (perUsd == 0) continue;
            if (!live || perUsd < perUsdLo) perUsdLo = perUsd;
            if (!live || perUsd > perUsdHi) perUsdHi = perUsd;
            live = true;
        }
    }

    /**
     * @dev Native wei per whole USD from ONE asset's deepest-pool 30-min TWAP; 0 when no
     *      tier pool exists or can serve the window (the caller skips the asset).
     * @param entry Registered stable asset + cached unit.
     * @param factory Canonical Uniswap V3 factory.
     * @param weth Chain quote token (token0 or token1 depending on address order).
     * @return Native wei per whole USD (0 when no healthy pool answered).
     */
    function _weiPerUsd(OracleAsset memory entry, address factory, address weth) private view returns (uint256) {
        (bool found, int256 tickDelta) = _deepestTickDelta(factory, weth, entry.asset);
        if (!found) return 0;

        // Arithmetic-mean tick, floored toward negative infinity (a truncated negative
        // quotient would otherwise round the price UP). |delta| <= MAX_TICK * window, so
        // the int24 cast is safe by construction.
        int256 window = int256(uint256(TWAP_WINDOW));
        int256 meanTick = tickDelta / window;
        if (tickDelta < 0 && tickDelta % window != 0) --meanTick;

        uint160 sqrtP = DiggerV3.getSqrtRatioAtTick(int24(meanTick));
        // Wei per RAW asset unit, 1e18-scaled: pool price when WETH is token1, inverse
        // when WETH is token0 (V3 orders by address).
        uint256 unitPrice =
            weth < entry.asset ? DiggerV3.sqrtPriceToInversePrice(sqrtP, 1) : DiggerV3.sqrtPriceToPrice(sqrtP);
        // One whole USD = `unit` raw units.
        return DiggerMath.md512(entry.unit, unitPrice, 1e18);
    }

    /**
     * @dev Probes the four canonical fee tiers of WETH/asset and returns the
     *      tickCumulative delta of the DEEPEST pool over the window. Depth = smallest
     *      secondsPerLiquidityCumulative delta (highest harmonic-mean liquidity —
     *      un-flashable). Nonexistent tiers and pools that cannot serve the lookback
     *      (`OLD` revert inside observe) are skipped via try/catch.
     * @param factory Canonical Uniswap V3 factory.
     * @param weth Chain quote token.
     * @param asset Stable ERC-20 paired against WETH.
     * @return found True iff at least one tier pool served the TWAP window.
     * @return tickDelta `tickCumulative(now) - tickCumulative(window ago)` of the deepest pool.
     */
    function _deepestTickDelta(address factory, address weth, address asset)
        private
        view
        returns (bool found, int256 tickDelta)
    {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        // ago[1] = 0 (now)

        uint24[4] memory tiers = [TIER_A, TIER_B, TIER_C, TIER_D];
        uint160 bestDelta;
        for (uint256 i; i < 4; ++i) {
            address pool = IUniswapV3Factory(factory).getPool(weth, asset, tiers[i]);
            if (pool == address(0)) continue;
            try IUniswapV3PoolOracle(pool).observe(ago) returns (int56[] memory ticks, uint160[] memory spls) {
                uint160 splDelta;
                unchecked {
                    splDelta = spls[1] - spls[0]; // wrapping counter, delta is exact
                }
                if (splDelta == 0) splDelta = 1; // theoretical floor, keeps the compare sane
                if (!found || splDelta < bestDelta) {
                    found = true;
                    bestDelta = splDelta;
                    tickDelta = int256(ticks[1]) - int256(ticks[0]);
                }
            } catch {}
        }
    }

    /**
     * @dev Saturating uint96 cast for the cache slots.
     * @param value Raw wei bar to clamp.
     * @return value as uint96, or `type(uint96).max` if it would overflow.
     */
    function _clamp96(uint256 value) private pure returns (uint96) {
        return value > type(uint96).max ? type(uint96).max : uint96(value);
    }
}
