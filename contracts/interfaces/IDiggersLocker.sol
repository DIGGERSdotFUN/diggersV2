// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IDiggers} from "./IDiggers.sol";

/**
 * @title IDiggersLocker
 * @notice Interface of the standalone vesting-lock escrow. The locker owns the lock book
 *         and the escrowed token balances; the launchpad stays the event surface — every
 *         `Locked`/`Withdrawn` is relayed through `Diggers.logLocked`/`logWithdrawn`
 *         (locker-gated), so the indexer keeps watching ONE address. A UI resolves this
 *         contract once via `diggers.LOCKER()` and reads the views here.
 * @dev Shares the lock types (`Lock`, `LockSchedule`, `LockOrder`) and errors
 *      (`LockConfigInvalid`, `UnknownLock`, `NothingToWithdraw`, `UnknownToken`,
 *      `Reentrancy`) with {IDiggers}. Events print from the hub via locker-gated relays
 *      (see {IDiggersHub.logLocked} / {IDiggersHub.logWithdrawn}).
 * @author BasedDopamine
 */
interface IDiggersLocker {
    // ----------------------------------------------------------------- errors

    /// @dev Thrown when a Diggers-only entrypoint (`lockFor`) is called by anyone else.
    error NotDiggers();

    // ------------------------------------------------------------- immutables

    /// @notice The Diggers launchpad this locker is bound to (its deployer).
    /// @return The bound Diggers launchpad address.
    function DIGGERS() external view returns (address);

    // -------------------------------------------------------------- locking

    /**
     * @notice Escrows locks for many recipients in one call, pulling `sum(amounts)` of
     *         `token` from the caller — approve-free for Diggers tokens (the locker
     *         carve; no ERC20 approval ever needed). Each row becomes a FRESH lock index
     *         with its own schedule; a wallet can hold any number of locks.
     * @param token The launched token to lock.
     * @param to Recipients (1..100 per call — gas-bounded batch, repeat for more; no zero
     *        address).
     * @param amounts Raw token units per recipient (no zero rows; same length as `to`).
     * @param schedules ONE row broadcasts to every recipient, else one per recipient.
     */
    function multiLock(
        address token,
        address[] calldata to,
        uint256[] calldata amounts,
        IDiggers.LockSchedule[] calldata schedules
    ) external;

    /**
     * @notice Books a create-time / buyAndLock distribution table against `purchased`
     *         tokens the carrying swap has ALREADY delivered to the locker (no pull).
     *         Diggers-only.
     * @param token The launched token being distributed.
     * @param funder The outer caller recorded on each `Locked` event.
     * @param purchased Total tokens to distribute (raw units, already on the locker).
     * @param orders The LockOrder table (validated here; shares sum to exactly 1e18).
     */
    function lockFor(address token, address funder, uint256 purchased, IDiggers.LockOrder[] calldata orders)
        external;

    // ------------------------------------------------------------ withdrawals

    /// @notice Pays out everything currently vested-but-unpaid on one lock. Permissionless
    ///         trigger; funds always go to the lock's wallet.
    /// @param token Launched Diggers token of the lock.
    /// @param wallet Lock owner / payout recipient.
    /// @param index Position index in `wallet`'s per-token lock list.
    /// @return amount Raw token units paid out in this call.
    function withdraw(address token, address wallet, uint256 index) external returns (uint256 amount);

    /// @notice Sweeps every withdrawable tranche across ALL of `wallet`'s locks on `token`
    ///         in ONE transfer (caller pays the gas; reverts only if nothing at all is
    ///         withdrawable).
    /// @param token Launched Diggers token.
    /// @param wallet Lock owner / payout recipient.
    /// @return amount Total raw token units paid out across all locks.
    function withdrawAll(address token, address wallet) external returns (uint256 amount);

    /// @notice Partial withdrawal: takes from each of the given lock `indexes` IN ORDER
    ///         until `maxAmount` is filled, then stops — one transfer to `wallet`. Built
    ///         for the pre-graduation 2% cap: pass the wallet's cap headroom and the
    ///         payout can never trip the shield. Duplicate indexes are harmless; an
    ///         out-of-range index reverts; paying nothing reverts.
    /// @param token Launched Diggers token.
    /// @param wallet Lock owner / payout recipient.
    /// @param indexes Lock indexes to drain from, in order.
    /// @param maxAmount Cap on total raw token units paid in this call.
    /// @return amount Raw token units actually paid (≤ `maxAmount`).
    function withdrawUpTo(address token, address wallet, uint256[] calldata indexes, uint256 maxAmount)
        external
        returns (uint256 amount);

    // ------------------------------------------------------------------ views

    /// @notice Number of locks `wallet` holds on `token` (indexes are 0..count-1).
    /// @param token Launched Diggers token.
    /// @param wallet Address whose lock list to measure.
    /// @return Number of lock positions for `(token, wallet)`.
    function lockCountOf(address token, address wallet) external view returns (uint256);

    /// @notice Full detail of one lock.
    /// @param token Launched Diggers token.
    /// @param wallet Lock owner.
    /// @param index Position index in the wallet's per-token lock list.
    /// @return The {IDiggers.Lock} struct for that position.
    function getLock(address token, address wallet, uint256 index) external view returns (IDiggers.Lock memory);

    /// @notice Currently vested-but-unpaid amount of one lock.
    /// @param token Launched Diggers token.
    /// @param wallet Lock owner.
    /// @param index Position index in the wallet's per-token lock list.
    /// @return Raw token units currently withdrawable from that lock.
    function withdrawableOf(address token, address wallet, uint256 index) external view returns (uint256);

    /// @notice `wallet`'s LIVE locked balance on `token` (sum of total minus withdrawn).
    /// @param token Launched Diggers token.
    /// @param wallet Address whose still-locked aggregate to read.
    /// @return Raw token units still locked for `wallet` on `token`.
    function lockedOf(address token, address wallet) external view returns (uint256);

    /// @notice `token`'s LIVE locked supply across all wallets.
    /// @param token Launched Diggers token.
    /// @return Raw token units still escrowed on this locker for `token`.
    function lockedSupplyOf(address token) external view returns (uint256);
}
