// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerGraduationMath} from "./DiggerGraduationMath.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";
import {IDiggersHub} from "../interfaces/IDiggersHub.sol";
import {IDiggersToken} from "../interfaces/IDiggersToken.sol";

/**
 * @title DiggerGraduationLib
 * @notice Graduation + blue-chip orchestration executed via `delegatecall` from `Diggers`.
 *
 *         Graduation is a single supply-sold criterion (pump.fun-style): the token's
 *         pool balance must fall to `gradPoolBalance` — i.e. enough of the fixed supply
 *         was bought out of the pool (foreign LP positions can only ADD tokens, making
 *         the bar harder, see {DiggerGraduationMath.evaluateGraduation}). A token that
 *         clears it: (a) sets its `graduatedAt` flag, and (b) has its anti-whale shield
 *         dropped forever via `markGraduated()`. Graduation has NO registry effect.
 *
 *         Blue chip is a LIVE, revocable market-derived status with three legs: lifetime
 *         volume (monotone — gates promotion, can never un-pass), mean-tick market cap,
 *         and holder count (both live). It is DORMANT until graduation: the launchpad
 *         only routes blue-chip calls (explicit or auto) for graduated tokens. Promotion
 *         sets `blueChippedAt` and LOCKS the token's name + symbol objects (registry
 *         lock count +1 each — the only name gate); demotion (a live leg failing) clears
 *         the flag and unlocks both. Both directions have an explicit permissionless
 *         entrypoint (reverting on failure) and ride the silent auto-check called after
 *         every post-graduation buy/sell (never breaks a trade). The status can be
 *         regained.
 * @dev Storage-pointer parameters resolve in Diggers' context; under delegatecall
 *      `address(this)` is the launchpad — the owner of every position. No state lives
 *      here. All thresholds are chain-parameterized and passed in by the launchpad.
 *      Pure criteria live in {DiggerGraduationMath}; USD-oracle bar conversion (when
 *      active) is supplied upstream by {DiggerTwapOracle.tradeBars}.
 * @author BasedDopamine
 */
library DiggerGraduationLib {
    // ------------------------------------------------------------- graduation

    /**
     * @notice Graduate `token` explicitly (permissionless, callable anytime).
     * @dev Reverts `AlreadyGraduated` if done, `CriteriaNotMet` if short.
     * @param graduatedAt Per-token graduation timestamps (Diggers storage; 0 = not yet).
     * @param tokenKeys Per-token folded name/symbol keys (Diggers storage).
     * @param tokenRecords Per-token pool/position records (Diggers storage).
     * @param token Launched token to graduate.
     * @param gradPoolBalance Pool-balance threshold: TOTAL_SUPPLY x (1 - gradSoldWad).
     * @param hub DiggersHub event singleton.
     */
    function graduate(
        mapping(address => uint64) storage graduatedAt,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        address token,
        uint256 gradPoolBalance,
        address hub
    ) external {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();
        if (graduatedAt[token] != 0) revert IDiggers.AlreadyGraduated();

        IDiggers.TokenRecord memory rec = tokenRecords[token];
        (bool ok, uint256 poolBalance) = DiggerGraduationMath.evaluateGraduation(token, rec.pool, gradPoolBalance);
        if (!ok) revert IDiggers.CriteriaNotMet();

        _applyGraduation(graduatedAt, k, token, rec.pool, poolBalance, hub);
    }

    /**
     * @notice Silent auto-graduation, called from `Diggers._trade` after each buy/sell.
     * @dev No-ops unless not yet graduated and the supply-sold criterion passes. On
     *      success it graduates (shield off). Never reverts a trade.
     * @param graduatedAt Per-token graduation timestamps (Diggers storage; 0 = not yet).
     * @param tokenKeys Per-token folded name/symbol keys (Diggers storage).
     * @param tokenRecords Per-token pool/position records (Diggers storage).
     * @param token Launched token just traded.
     * @param gradPoolBalance Pool-balance threshold: TOTAL_SUPPLY x (1 - gradSoldWad).
     * @param hub DiggersHub event singleton.
     */
    function autoGraduate(
        mapping(address => uint64) storage graduatedAt,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        address token,
        uint256 gradPoolBalance,
        address hub
    ) external {
        if (graduatedAt[token] != 0) return;

        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) return;

        IDiggers.TokenRecord memory rec = tokenRecords[token];
        (bool ok, uint256 poolBalance) = DiggerGraduationMath.evaluateGraduation(token, rec.pool, gradPoolBalance);
        if (!ok) return;

        _applyGraduation(graduatedAt, k, token, rec.pool, poolBalance, hub);
    }

    // -------------------------------------------------------------- blue chip

    /// @dev Freed-name grace: how long BOTH of a demoted token's keys stay uncreatable
    ///      after their LAST lock drops, so a wrongful demotion (price swing, oracle
    ///      wobble) cannot be name-sniped before the token has two full daily closes to
    ///      recover. Any re-promotion during the window re-locks and moots the stamp.
    uint64 internal constant NAME_GRACE = 48 hours;

    /// @dev Chain-parameterized blue-chip thresholds, bundled so the entrypoints stay
    ///      within stack limits. `mcapHi` gates promotion, `mcapLo` gates retention —
    ///      equal outside the USD-oracle mode (see {DiggerGraduationMath.evaluateBlueChip}).
    struct BlueChipBars {
        uint256 volume;
        uint256 mcapHi;
        uint256 mcapLo;
        uint32 holders;
        uint256 quoteScale;
    }

    /**
     * @notice Promote `token` to blue chip explicitly (permissionless, callable anytime).
     * @dev Reverts `AlreadyBlueChip` if live, `CriteriaNotMet` if any leg is short.
     * @param blueChippedAt Per-token blue-chip timestamps (Diggers storage; 0 = not live).
     * @param lockCount Per-key live blue-chip lock counts (Diggers registry storage).
     * @param tokenKeys Per-token folded name/symbol keys (Diggers storage).
     * @param token Launched token to promote.
     * @param bars Bundled volume / mcap hi-lo / holders / quoteScale thresholds.
     * @param hub DiggersHub event singleton.
     */
    function blueChip(
        mapping(address => uint64) storage blueChippedAt,
        mapping(bytes32 => uint32) storage lockCount,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token,
        BlueChipBars memory bars,
        address hub
    ) external {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();
        if (blueChippedAt[token] != 0) revert IDiggers.AlreadyBlueChip();

        (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked) =
            IDiggersToken(token).graduationStats();
        (bool promoteOk, uint256 mcap,,,,) = DiggerGraduationMath.evaluateBlueChip(
            holders, volumeEth, meanTick, daysTracked, bars.volume, bars.mcapHi, bars.mcapLo, bars.holders,
            bars.quoteScale
        );
        if (!promoteOk) revert IDiggers.CriteriaNotMet();

        _promote(blueChippedAt, lockCount, k, token, volumeEth, mcap, holders, hub);
    }

    /**
     * @notice Demote `token` explicitly (permissionless): strips a blue chip whose LIVE
     *         legs (mean-tick mcap or holders) no longer pass, unlocking its objects.
     * @dev Reverts `NotBlueChip` when the token is not blue chip, `CriteriaNotMet` while
     *      every live leg still passes. Retention uses the EASY mcap bar (`mcapLo`) —
     *      demotion needs a failure even under the most favorable conversion. Lifetime
     *      volume is monotone and never re-checked.
     * @param blueChippedAt Per-token blue-chip timestamps (Diggers storage; 0 = not live).
     * @param lockCount Per-key live blue-chip lock counts (Diggers registry storage).
     * @param keyGraceUntil Per-key post-demotion creation-grace deadlines (Diggers storage).
     * @param tokenKeys Per-token folded name/symbol keys (Diggers storage).
     * @param token Launched token to demote.
     * @param bars Bundled volume / mcap hi-lo / holders / quoteScale thresholds.
     * @param hub DiggersHub event singleton.
     */
    function blueChipLost(
        mapping(address => uint64) storage blueChippedAt,
        mapping(bytes32 => uint32) storage lockCount,
        mapping(bytes32 => uint64) storage keyGraceUntil,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token,
        BlueChipBars memory bars,
        address hub
    ) external {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();
        if (blueChippedAt[token] == 0) revert IDiggers.NotBlueChip();

        (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked) =
            IDiggersToken(token).graduationStats();
        (, uint256 mcap,,, bool mcapPassLo, bool holdersPass) = DiggerGraduationMath.evaluateBlueChip(
            holders, volumeEth, meanTick, daysTracked, bars.volume, bars.mcapHi, bars.mcapLo, bars.holders,
            bars.quoteScale
        );
        if (mcapPassLo && holdersPass) revert IDiggers.CriteriaNotMet();

        _demote(blueChippedAt, lockCount, keyGraceUntil, k, token, mcap, holders, hub);
    }

    /**
     * @notice Silent BOTH-direction blue-chip check, called from `Diggers._trade` after
     *         EVERY buy/sell: promotes when all HARD legs pass, demotes when a live leg
     *         fails even its EASY bar. Never reverts a trade.
     * @param blueChippedAt Per-token blue-chip timestamps (Diggers storage; 0 = not live).
     * @param lockCount Per-key live blue-chip lock counts (Diggers registry storage).
     * @param keyGraceUntil Per-key post-demotion creation-grace deadlines (Diggers storage).
     * @param tokenKeys Per-token folded name/symbol keys (Diggers storage).
     * @param token Launched token just traded.
     * @param bars Bundled volume / mcap hi-lo / holders / quoteScale thresholds.
     * @param hub DiggersHub event singleton.
     */
    function autoBlueChip(
        mapping(address => uint64) storage blueChippedAt,
        mapping(bytes32 => uint32) storage lockCount,
        mapping(bytes32 => uint64) storage keyGraceUntil,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token,
        BlueChipBars memory bars,
        address hub
    ) external {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) return;

        (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked) =
            IDiggersToken(token).graduationStats();
        (bool promoteOk, uint256 mcap,,, bool mcapPassLo, bool holdersPass) = DiggerGraduationMath.evaluateBlueChip(
            holders, volumeEth, meanTick, daysTracked, bars.volume, bars.mcapHi, bars.mcapLo, bars.holders,
            bars.quoteScale
        );

        if (blueChippedAt[token] == 0) {
            if (promoteOk) _promote(blueChippedAt, lockCount, k, token, volumeEth, mcap, holders, hub);
        } else if (!(mcapPassLo && holdersPass)) {
            _demote(blueChippedAt, lockCount, keyGraceUntil, k, token, mcap, holders, hub);
        }
    }

    // ---------------------------------------------------------------- progress

    /// @dev The read-only progress snapshot (`progressOf`) lives on the DiggersHub,
    ///      which reconstructs this library's inputs from raw extsload slots and calls
    ///      the same {DiggerGraduationMath} evaluators — one shared truth, two hosts.

    // -------------------------------------------------------------- internal

    /**
     * @dev Marks `token` graduated and drops its anti-whale shield forever. No registry
     *      effect. Emits the rich {Graduated} (our indexer) plus the minimal
     *      {TokenGraduated} companion for third-party integrators.
     * @param graduatedAt Per-token graduation timestamps (Diggers storage).
     * @param k Token's folded name/symbol keys.
     * @param token Launched token being graduated.
     * @param pool Token's V3 pool address (event payload).
     * @param poolBalance Pool token balance that cleared the bar (raw units).
     * @param hub DiggersHub event singleton.
     */
    function _applyGraduation(
        mapping(address => uint64) storage graduatedAt,
        IDiggers.TokenKeys memory k,
        address token,
        address pool,
        uint256 poolBalance,
        address hub
    ) private {
        graduatedAt[token] = uint64(block.timestamp);
        IDiggersToken(token).markGraduated();

        uint256 supplySold = DiggerGraduationMath.TOTAL_SUPPLY - poolBalance;
        (uint32 holders, uint256 volumeEth,,) = IDiggersToken(token).graduationStats();
        // One hub call prints BOTH the rich Graduated and the TokenGraduated companion.
        IDiggersHub(hub).logGraduated(token, k.nameKey, k.symbolKey, holders, volumeEth, supplySold, pool);
    }

    /**
     * @dev Grants the status and locks both objects (+1 each; the symbol key only when it
     *      differs from the name key — a token whose folded name equals its folded symbol
     *      holds ONE object). Emits {BlueChip}.
     * @param blueChippedAt Per-token blue-chip timestamps (Diggers storage).
     * @param lockCount Per-key live blue-chip lock counts (Diggers registry storage).
     * @param k Token's folded name/symbol keys.
     * @param token Launched token being promoted.
     * @param volumeEth Lifetime volume at promotion (event payload).
     * @param mcap Mean-tick mcap at promotion (event payload).
     * @param holders Holder count at promotion (event payload).
     * @param hub DiggersHub event singleton.
     */
    function _promote(
        mapping(address => uint64) storage blueChippedAt,
        mapping(bytes32 => uint32) storage lockCount,
        IDiggers.TokenKeys memory k,
        address token,
        uint256 volumeEth,
        uint256 mcap,
        uint32 holders,
        address hub
    ) private {
        blueChippedAt[token] = uint64(block.timestamp);
        ++lockCount[k.nameKey];
        if (k.symbolKey != k.nameKey) ++lockCount[k.symbolKey];
        IDiggersHub(hub).logBlueChip(token, k.nameKey, k.symbolKey, volumeEth, mcap, holders);
    }

    /**
     * @dev Strips the status and unlocks both objects (-1 each, exactly mirroring
     *      {_promote} — a live blue chip always holds one count on each of its keys, so
     *      the decrement can never underflow). A key whose LAST lock drops here gets its
     *      48h creation-grace stamp: the name stays uncreatable while any still-live
     *      same-name blue chip (count > 0) or the grace clock protects it. Emits
     *      {BlueChipLost} carrying the stamp.
     * @param blueChippedAt Per-token blue-chip timestamps (Diggers storage).
     * @param lockCount Per-key live blue-chip lock counts (Diggers registry storage).
     * @param keyGraceUntil Per-key post-demotion creation-grace deadlines (Diggers storage).
     * @param k Token's folded name/symbol keys.
     * @param token Launched token being demoted.
     * @param mcap Mean-tick mcap at demotion (event payload).
     * @param holders Holder count at demotion (event payload).
     * @param hub DiggersHub event singleton.
     */
    function _demote(
        mapping(address => uint64) storage blueChippedAt,
        mapping(bytes32 => uint32) storage lockCount,
        mapping(bytes32 => uint64) storage keyGraceUntil,
        IDiggers.TokenKeys memory k,
        address token,
        uint256 mcap,
        uint32 holders,
        address hub
    ) private {
        blueChippedAt[token] = 0;
        uint64 graceUntil = uint64(block.timestamp) + NAME_GRACE;
        if (--lockCount[k.nameKey] == 0) keyGraceUntil[k.nameKey] = graceUntil;
        if (k.symbolKey != k.nameKey && --lockCount[k.symbolKey] == 0) keyGraceUntil[k.symbolKey] = graceUntil;
        IDiggersHub(hub).logBlueChipLost(token, k.nameKey, k.symbolKey, mcap, holders, graceUntil);
    }
}
