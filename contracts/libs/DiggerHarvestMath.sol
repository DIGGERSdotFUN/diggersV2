// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";

/**
 * @title DiggerHarvestMath
 * @notice Pure 1e18-scaled harvest split math kept out of the `Diggers` runtime.
 * @dev V3 edition: there is NO platform ETH slice. The platform coin ($DIG) is airdrop-
 *      only and soulbound, and its liquidity is provisioned manually off-protocol, so ETH
 *      fees split purely team / creator. Buy-mining still mints $DIG during the window;
 *      it just no longer diverts any ETH fee to the coin. Fees always split in full —
 *      there is no reinvest leg. Linked by {DiggerHarvestLib} (delegatecall orchestration).
 * @author BasedDopamine
 */
library DiggerHarvestMath {
    uint256 internal constant WAD = 1e18;

    /**
     * @notice ETH split with an owner-set team share. The creator side is the remainder;
     *         the team side is floored and the creator side absorbs rounding dust so the
     *         whole `ethTotal` is always conserved.
     * @dev Caller guarantees `teamShareWad <= 1e18`.
     * @param ethTotal Total native fees being split (wei).
     * @param teamShareWad Owner-set team share of ETH fees (1e18-scaled).
     * @return toTeam Floored team slice (wei).
     * @return toCreators Remainder for the creator side (wei; absorbs dust).
     */
    function splitEth(uint256 ethTotal, uint256 teamShareWad)
        external
        pure
        returns (uint256 toTeam, uint256 toCreators)
    {
        toTeam = DiggerMath.md512(ethTotal, teamShareWad, WAD);
        toCreators = ethTotal - toTeam;
    }

    /**
     * @notice Splits collected token fees per the token's creator-chosen burn share
     *         (1e18-scaled). Burn floors; the airdrop pot takes the remainder.
     * @param tokenTotal Collected token fees (18-dec raw units).
     * @param burnShareWad Creator-chosen burn share of token fees (1e18-scaled).
     * @return toBurn Floored burn amount.
     * @return toPot Remainder for the daily airdrop pot (absorbs dust).
     */
    function splitToken(uint256 tokenTotal, uint256 burnShareWad)
        external
        pure
        returns (uint256 toBurn, uint256 toPot)
    {
        toBurn = DiggerMath.md512(tokenTotal, burnShareWad, WAD);
        toPot = tokenTotal - toBurn;
    }

    /**
     * @notice Credits one creator-table share (floor); last entry gets dust.
     * @param creatorTotal Total creator-side ETH being allocated (wei).
     * @param shareWad This row's 1e18-scaled share of `creatorTotal`.
     * @param isLast True when this is the final fee-split row (receives remaining dust).
     * @param allocatedSoFar Wei already allocated to prior rows.
     * @return amount Wei credited to this row.
     */
    function shareOf(uint256 creatorTotal, uint256 shareWad, bool isLast, uint256 allocatedSoFar)
        external
        pure
        returns (uint256 amount)
    {
        if (isLast) return creatorTotal - allocatedSoFar;
        return DiggerMath.md512(creatorTotal, shareWad, WAD);
    }
}
