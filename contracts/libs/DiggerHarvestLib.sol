// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";
import {DiggerHarvestMath} from "./DiggerHarvestMath.sol";
import {DiggersToken} from "../DiggersToken.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";
import {IDiggersHub} from "../interfaces/IDiggersHub.sol";
import {IGlueV2} from "../interfaces/IGlueV2.sol";

/**
 * @title DiggerHarvestLib
 * @notice Harvest orchestration executed via `delegatecall` from `Diggers`, so its
 *         bytecode lives off the singleton while it still reads and writes the launchpad's
 *         own storage (ETH-owed ledger, per-token retry pot, creator fee-split table).
 *         Under delegatecall `address(this)` is the launchpad, so the ETH pushes below
 *         spend the singleton's balance (the native fees it just unwrapped).
 * @dev V3 edition: ETH fees split purely team / creator (no platform slice), with
 *      optional burn-owner-set carves off the fresh creator side (buyback pot + the Glue
 *      backing/staking deposit) and an optional Glue stake carve on the token side, both
 *      glue legs try/caught and failing OPEN into the normal split. Payouts are
 *      PUSH, not pull: each ETH slice is delivered with a gas-capped low-level call so a
 *      recipient that reverts OR burns gas can never block the harvest (and therefore
 *      never block trades, since harvest runs opportunistically inside buy/sell). Fallback
 *      chain — creator rows: recipient → fee owner → the per-token retry pot; team:
 *      recipient → the pull ledger. State never lives here; only the code does.
 *      Fees are ALWAYS split in full — there is no reinvest leg (the seed position's
 *      liquidity is permanent and constant; graduation is supply-sold, never L-based).
 *      Pure split math is delegated to {DiggerHarvestMath}.
 * @author BasedDopamine
 */
library DiggerHarvestLib {
    /// @dev Gas forwarded to each ETH push. Enough for an EOA or a lean receiver; a
    ///      recipient needing more (or hostile) falls through the chain instead of
    ///      reverting the harvest. A bare bool/try check does NOT bound gas — this does.
    uint256 private constant PUSH_GAS = 40_000;

    /// @dev WAD == 1e18 == 100% (also Glue's PRECISION for `backingPercentage`).
    uint256 private constant WAD_ = 1e18;

    /// @dev Glue staking implementation version Diggers pins on every deposit.
    uint8 private constant GLUE_STAKING_VERSION = 1;

    /// @notice Value bundle for {distribute} (the 1e18-wad shares are pre-validated at
    ///         create/edit: buyback+backing+staking <= 1e18 and burn+stake <= 1e18).
    struct DistributeParams {
        uint8 count; // active creator fee-split rows
        address teamTreasury; // current team recipient (owner-editable)
        address feeOwner; // creator-push fallback (0 = renounced)
        address token; // launched token whose fees were collected
        address caller; // original harvest caller (for the event)
        address glue; // Glue V2 deposit router (0 = integration not activated)
        address hub; // DiggersHub event singleton (all events print there)
        uint256 ethFees; // freshly collected native fees (wei)
        uint256 carriedPending; // creator-side ETH retried from prior failed pushes (wei)
        uint256 tokenFees; // collected token fees (18 dec)
        uint256 teamShareWad; // owner-set team share of ETH fees
        uint256 creatorBuybackWad; // ETH side: buyback redirect carve
        uint256 backingWad; // ETH side: Glue NAV-backing carve
        uint256 stakingWad; // ETH side: Glue staking carve
        uint256 burnShareWad; // token side: burn share
        uint256 stakeWad; // token side: Glue staking share (pot takes the remainder)
    }

    /**
     * @notice Splits collected fees and delivers them (gas-capped pushes, glue deposits,
     *         burn, airdrop pot).
     * @dev ETH side: team is split off first; the buyback, backing, and staking carves are
     *      then all taken as INDEPENDENT fractions of the same FRESH creator side (they
     *      never compound on each other); the remainder + any retried wei goes to the
     *      fee-split rows. Backing+staking travel to Glue in ONE combined deposit whose
     *      `backingPercentage` expresses the backing fraction. Token side: burn and stake
     *      are fractions of the collected token fees; the airdrop pot takes the exact
     *      remainder (dust included). Every glue call is try/caught and fails OPEN — the
     *      slice rejoins the normal split in the SAME harvest, so fees are always conserved
     *      and a glue problem can never revert a trade.
     * @param ethOwed Diggers' pull-payment ETH ledger (storage pointer) — team push fallback.
     * @param pendingEth Diggers' per-token creator retry pot (storage pointer).
     * @param feeSplits The token's creator fee-split rows (storage pointer).
     * @param p Everything else (see {DistributeParams}).
     */
    function distribute(
        mapping(address => uint256) storage ethOwed,
        mapping(address => uint256) storage pendingEth,
        mapping(uint256 => IDiggers.FeeSplit) storage feeSplits,
        DistributeParams memory p
    ) external {
        (uint256 ethToTeam, uint256 ethToCreators) = DiggerHarvestMath.splitEth(p.ethFees, p.teamShareWad);
        uint256 freshCreator = ethToCreators;

        // Creator buyback redirect: carved from the FRESH creator side only, delivered to
        // the token address exactly like a donation (its own `receive()` — a plain vault).
        // If the gas-capped push somehow fails, the slice parks in the retry pot instead.
        uint256 ethToBuyback;
        if (p.creatorBuybackWad > 0 && freshCreator > 0) {
            ethToBuyback = DiggerHarvestMath.shareOf(freshCreator, p.creatorBuybackWad, false, 0);
            ethToCreators -= ethToBuyback;
            if (ethToBuyback > 0 && !_push(p.token, ethToBuyback)) {
                pendingEth[p.token] += ethToBuyback;
                IDiggersHub(p.hub).logFeeParked(p.token, p.token, ethToBuyback);
            }
        }

        // Glue ETH leg: backing + staking carves (independent fractions of the SAME fresh
        // creator side as the buyback), combined into one native deposit. Not gas-capped —
        // glue is owner-vetted and final at activation — but try/caught: on any revert the
        // whole carve rejoins the creator side below (fail-open, conserved).
        uint256 ethToGlue = _glueEthLeg(p, freshCreator);
        if (ethToGlue > 0) ethToCreators -= ethToGlue;

        // Retried creator wei rides the creator side only (already net of the team split
        // and every carve — they were carved when first distributed).
        ethToCreators += p.carriedPending;

        // Team: push, else fall back to the pull ledger (a protocol address; the registry
        // also credits team here).
        if (ethToTeam > 0 && !_push(p.teamTreasury, ethToTeam)) ethOwed[p.teamTreasury] += ethToTeam;

        // Creators: push to recipient → fee owner → park in the per-token retry pot.
        uint256 allocated;
        for (uint8 i = 0; i < p.count; ++i) {
            IDiggers.FeeSplit storage row = feeSplits[i];
            uint256 slice = DiggerHarvestMath.shareOf(ethToCreators, row.share, i == p.count - 1, allocated);
            allocated += slice;
            if (slice == 0) continue;
            if (_push(row.to, slice)) continue;
            if (p.feeOwner != address(0) && _push(p.feeOwner, slice)) continue;
            pendingEth[p.token] += slice;
            IDiggersHub(p.hub).logFeeParked(p.token, row.to, slice);
        }

        // Token side: burn + glue stake are independent fractions of the collected fees;
        // the daily airdrop pot takes the exact remainder (so the three total 100%).
        uint256 burned;
        uint256 tokensToGlue;
        uint256 toPot;
        if (p.tokenFees > 0) {
            burned = DiggerMath.md512(p.tokenFees, p.burnShareWad, WAD_);
            uint256 stakeAmt = p.glue == address(0) ? 0 : DiggerMath.md512(p.tokenFees, p.stakeWad, WAD_);
            toPot = p.tokenFees - burned - stakeAmt;

            if (burned > 0) DiggersToken(payable(p.token)).burn(burned);
            if (stakeAmt > 0) {
                // Exact-amount allowance; glue pulls it inside deposit. On failure the
                // allowance is zeroed and the stake folds into the airdrop pot instead.
                DiggersToken(payable(p.token)).approve(p.glue, stakeAmt);
                try IGlueV2(p.glue).deposit(p.token, GLUE_STAKING_VERSION, p.token, stakeAmt, 0) {
                    tokensToGlue = stakeAmt;
                } catch {
                    DiggersToken(payable(p.token)).approve(p.glue, 0);
                    toPot += stakeAmt;
                }
            }
            if (toPot > 0) DiggersToken(payable(p.token)).transfer(p.token, toPot);
        }

        IDiggersHub(p.hub).logHarvested(
            p.token,
            p.caller,
            p.ethFees + p.carriedPending,
            ethToTeam,
            ethToCreators,
            ethToBuyback,
            ethToGlue,
            burned,
            tokensToGlue,
            toPot
        );
    }

    /**
     * @dev Combined backing+staking native deposit to Glue. Returns the wei ACTUALLY
     *      handed over (0 when inactive, dust, or the deposit reverted — the caller keeps
     *      the carve on the creator side in that case). `backingPercentage` is the backing
     *      fraction of the combined amount in Glue's 1e18 PRECISION (staking-only ⇒ 0,
     *      backing-only ⇒ 1e18).
     * @param p Harvest distribute params (glue address + wad carves + token).
     * @param freshCreator Fresh creator-side ETH before buyback/glue carves (wei).
     * @return Wei actually deposited to Glue (0 on skip or fail-open revert).
     */
    function _glueEthLeg(DistributeParams memory p, uint256 freshCreator) private returns (uint256) {
        if (p.glue == address(0) || freshCreator == 0 || (p.backingWad | p.stakingWad) == 0) return 0;

        uint256 backingAmt = DiggerMath.md512(freshCreator, p.backingWad, WAD_);
        uint256 glueAmt = backingAmt + DiggerMath.md512(freshCreator, p.stakingWad, WAD_);
        if (glueAmt == 0) return 0;

        try IGlueV2(p.glue).deposit{value: glueAmt}(
            p.token, GLUE_STAKING_VERSION, address(0), glueAmt, backingAmt * WAD_ / glueAmt
        ) {
            return glueAmt;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Gas-capped ETH send from the launchpad's balance. Returns success; never
     *      reverts on a failing recipient so the caller can fall through its chain.
     * @param to Recipient of the native push.
     * @param amount Wei to send (forwards at most {PUSH_GAS}).
     * @return ok True iff the low-level call succeeded within the gas cap.
     */
    function _push(address to, uint256 amount) private returns (bool ok) {
        (ok,) = payable(to).call{value: amount, gas: PUSH_GAS}("");
    }
}
