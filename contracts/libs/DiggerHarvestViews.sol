// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3} from "./DiggerV3.sol";

/**
 * @title DiggerHarvestViews
 * @notice Pending-fee reads for opportunistic harvest gating.
 * @dev Linked external library. `Diggers` uses {shouldHarvest} before pulling fees on the
 *      swap path (skip when both sides are below floors); `DiggersHub` exposes
 *      {pendingFees} for indexer reconciliation. Both delegate to
 *      {DiggerV3.getPendingV3Fees} over the Launchpad-owned position
 *      `[tickLower, tickUpper]` — Diggers is the sole LP of every pool.
 * @author BasedDopamine
 */
library DiggerHarvestViews {
    /**
     * @notice True when accrued WETH or token fees exceed the configured floors.
     * @dev OR of the two thresholds: either side crossing its floor is enough to harvest.
     *      Keeps micro-fee collects off the swap hot path.
     * @param pool Uniswap V3 pool address for the digger token.
     * @param owner Position owner — always the Diggers launchpad singleton.
     * @param tickLower Lower tick of the Launchpad's LP position.
     * @param tickUpper Upper tick of the Launchpad's LP position.
     * @param ethThresholdWei Minimum pending quote (WETH) fees that trigger a harvest.
     * @param tokenThreshold Minimum pending token fees that trigger a harvest.
     * @return `true` if `pendingEth ≥ ethThresholdWei` or `pendingToken ≥ tokenThreshold`.
     */
    function shouldHarvest(
        address pool,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 ethThresholdWei,
        uint256 tokenThreshold
    ) external view returns (bool) {
        (uint256 pendingEth, uint256 pendingToken) = DiggerV3.getPendingV3Fees(pool, owner, tickLower, tickUpper);
        return pendingEth >= ethThresholdWei || pendingToken >= tokenThreshold;
    }

    /**
     * @notice Exact uncollected LP fees (WETH, token) awaiting the next harvest. For
     *         indexer reconciliation of the harvestable pot — not a per-pageview read.
     * @dev Pass-through of {DiggerV3.getPendingV3Fees}; does not collect or reset growth.
     * @param pool Uniswap V3 pool address for the digger token.
     * @param owner Position owner — always the Diggers launchpad singleton.
     * @param tickLower Lower tick of the Launchpad's LP position.
     * @param tickUpper Upper tick of the Launchpad's LP position.
     * @return ethFees Uncollected quote (WETH) fees owed to the position.
     * @return tokenFees Uncollected token fees owed to the position.
     */
    function pendingFees(address pool, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 ethFees, uint256 tokenFees)
    {
        (ethFees, tokenFees) = DiggerV3.getPendingV3Fees(pool, owner, tickLower, tickUpper);
    }
}
