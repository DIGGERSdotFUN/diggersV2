// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IGlueV2
 * @notice Minimal surface of the Glue V2 deposit router used by the Diggers fee
 *         integration. Diggers only ever calls `deposit`:
 *           - ETH side (one combined call per harvest): `asset == address(0)`, value ==
 *             amount, `backingPercentage` = the backing fraction of the combined
 *             backing+staking carve (1e18-scaled — Glue's PRECISION).
 *           - Token side: `asset == the launched token`, exact-amount approval first,
 *             `backingPercentage == 0` (pure staking).
 *         `context` is always the launched token; `stakingVersion` is always 1.
 * @dev The full Glue V2 deposit validates amount != 0 and backingPercentage <= PRECISION,
 *      resolves the sticky/NAV pair from `context`, lazily deploys the staking contract,
 *      and routes the value — none of which Diggers needs to know beyond "may revert"
 *      (every Diggers call site is try/caught and fails open into the normal fee split).
 * @author BasedDopamine
 */
interface IGlueV2 {
    /**
     * @notice Deposits `amount` of `asset` for `context`, split between NAV backing and
     *         staking rewards by `backingPercentage`.
     * @dev Diggers pins `stakingVersion == 1`, uses `context == launched token`, and
     *      never relies on a return value — failures are try/caught at harvest.
     * @param context The sticky-asset context (the launched token).
     * @param stakingVersion Glue staking implementation version (Diggers pins 1).
     * @param asset address(0) for native value, else the ERC-20 pulled via allowance.
     * @param amount Deposit size (wei / raw token units).
     * @param backingPercentage 1e18-scaled NAV-backing fraction of `amount`.
     */
    function deposit(address context, uint8 stakingVersion, address asset, uint256 amount, uint256 backingPercentage)
        external
        payable;
}
