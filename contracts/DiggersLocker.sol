// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./libs/DiggerMath.sol";
import {DiggersToken} from "./DiggersToken.sol";
import {IDiggers} from "./interfaces/IDiggers.sol";
import {IDiggersHub} from "./interfaces/IDiggersHub.sol";
import {IDiggersLocker} from "./interfaces/IDiggersLocker.sol";

/**
 * @title DiggersLocker
 * @notice The standalone vesting-lock escrow, deployed once by the Diggers constructor
 *         (immutably bound both ways). It owns the whole lock engine: the book is
 *         `_locks[token][wallet][]` — a wallet's lock list IS the storage (no separate id
 *         registry), each lock a fresh `(token, wallet, index)` handle with its own
 *         schedule — plus the escrowed token balances, so launchpad flows (harvest,
 *         buyback) can never even theoretically touch escrow:
 *         `token.balanceOf(locker) == lockedSupplyOf(token)` holds exactly.
 *         EVENTS PRINT FROM THE HUB: every `Locked`/`Withdrawn` is relayed through
 *         `DiggersHub.logLocked`/`logWithdrawn` (emitter-gated), so the indexer keeps
 *         watching one address. Gas-lean by layout: creating a lock writes ONE hot
 *         struct slot (`total|start|duration|tranches`; `withdrawn` starts zero) —
 *         token/wallet are the mapping keys and the funder rides the event only.
 *         Per-wallet and per-token still-locked aggregates are maintained on every op
 *         and ride on every event, so a UI reads "wallet has X locked" / "Y of supply
 *         locked" from the latest event.
 * @dev Diggers V2 architecture: Diggers (factory+router+fee splitter) deploys this
 *      locker and is the only caller of {lockFor}; DiggersToken treats this address
 *      like the launchpad in `_update` (cap-exempt, no points, no holder counting) and
 *      skips allowance on `transferFrom` when `msg.sender == LOCKER`; DiggersHub is the
 *      sole event surface. Approve-free by construction: the `multiLock` pull is
 *      `token.transferFrom` with the locker as `msg.sender`, and the locker only ever
 *      pulls `from == msg.sender` of the outer call. `lockFor` books create-time /
 *      buyAndLock tables against tokens the carrying swap already delivered here.
 *      Withdrawals are permissionless triggers but funds only ever go to the lock's
 *      wallet (checks-effects-interactions; a transient reentrancy latch guards the
 *      entrypoints).
 * @author BasedDopamine
 */
contract DiggersLocker is IDiggersLocker {
    // -------------------------------------------------- constants / immutables

    /// @dev 1e18 == 100%. Percentages are ALWAYS 1e18-scaled, never bps.
    uint256 private constant WAD = 1e18;

    /// @dev Hard cap on lock rows PER CALL (create tables AND multiLock batches) — the
    ///      book is unbounded; batch again for more. Gas-calibrated on the packed layout:
    ///      a fresh lock row is ~75k cold, so a maxed batch stays well inside one block.
    uint256 private constant MAX_LOCKS = 100;

    /// @dev Floor on every lock's size (0.001 token = 1e-12 of the fixed supply).
    ///      Anti-grief: without it, anyone could shower a wallet with 1-wei locks until
    ///      its `withdrawAll` sweep no longer fits a block (~25k gas per paying lock).
    ///      `withdraw(index)` never breaks either way; this keeps the sweep usable.
    uint256 private constant MIN_LOCK_AMOUNT = 1e15;

    /// @dev EIP-1153 transient reentrancy latch for the token-moving entrypoints.
    bytes32 private constant REENTRANCY_SLOT = keccak256("diggers.locker.reentrancy");

    /// @inheritdoc IDiggersLocker
    address public immutable DIGGERS;

    /// @notice The DiggersHub event singleton every `Locked`/`Withdrawn` prints from.
    /// @dev Registered as an emitter by Diggers at construction; this locker never emits
    ///      locally.
    address public immutable HUB;

    // ---------------------------------------------------------------- storage

    /// @dev The lock book: `_locks[token][wallet]` IS the wallet's lock list (handles are
    ///      `(token, wallet, index)` — no separate id registry, no global array).
    mapping(address => mapping(address => IDiggers.Lock[])) private _locks;

    /// @dev Per-(token, wallet) still-locked aggregate (total minus withdrawn).
    mapping(address => mapping(address => uint256)) private _lockedOf;

    /// @dev Per-token still-locked aggregate across all wallets.
    mapping(address => uint256) private _lockedSupply;

    // ------------------------------------------------------------ constructor

    /// @notice Deployed from the Diggers constructor — the launchpad is the deployer.
    /// @dev Sets {DIGGERS} = `msg.sender` and pins {HUB}; Diggers then `register`s this
    ///      address on the hub so `logLocked`/`logWithdrawn` succeed.
    /// @param hub The pre-deployed DiggersHub the launchpad is bound to.
    constructor(address hub) {
        DIGGERS = msg.sender;
        HUB = hub;
    }

    // -------------------------------------------------------------- modifiers

    /// @notice Transient (EIP-1153) reentrancy latch for token-moving entrypoints.
    /// @dev Reverts {IDiggers.Reentrancy} via custom-error selector `0xab143c06`.
    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        assembly {
            if tload(slot) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice Restricts {lockFor} to the bound Diggers launchpad.
    /// @dev Reverts {NotDiggers} for any other caller.
    modifier onlyDiggers() {
        if (msg.sender != DIGGERS) revert NotDiggers();
        _;
    }

    // --------------------------------------------------------------- locking

    /// @inheritdoc IDiggersLocker
    /// @dev One `transferFrom(msg.sender, this, sum)` then {_lock} per row. A single
    ///      schedule broadcasts to every recipient; otherwise lengths must match.
    function multiLock(
        address token,
        address[] calldata to,
        uint256[] calldata amounts,
        IDiggers.LockSchedule[] calldata schedules
    ) external nonReentrant {
        if (!IDiggers(DIGGERS).isDiggersToken(token)) revert IDiggers.UnknownToken();

        uint256 n = to.length;
        bool broadcast = schedules.length == 1;
        if (n == 0 || n > MAX_LOCKS || amounts.length != n || (!broadcast && schedules.length != n)) {
            revert IDiggers.LockConfigInvalid();
        }

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            IDiggers.LockSchedule calldata s = schedules[broadcast ? 0 : i];
            if (to[i] == address(0) || amounts[i] == 0 || s.tranches == 0 || s.duration == 0) {
                revert IDiggers.LockConfigInvalid();
            }
            sum += amounts[i];
        }

        // One pull for the whole batch. Approve-free: the token's allowance-skip carve
        // honors the locker as caller, and `from` is the outer caller.
        DiggersToken(payable(token)).transferFrom(msg.sender, address(this), sum);

        for (uint256 i; i < n; ++i) {
            IDiggers.LockSchedule calldata s = schedules[broadcast ? 0 : i];
            _lock(token, to[i], msg.sender, amounts[i], s.tranches, s.duration);
        }
    }

    /// @inheritdoc IDiggersLocker
    /// @dev No pull — tokens must already sit here from Diggers' swap recipient. Last
    ///      LockOrder row absorbs rounding dust; `tranches == 0` is an immediate transfer.
    function lockFor(address token, address funder, uint256 purchased, IDiggers.LockOrder[] calldata orders)
        external
        onlyDiggers
    {
        uint256 n = orders.length;
        if (n == 0 || n > MAX_LOCKS) revert IDiggers.LockConfigInvalid();

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            IDiggers.LockOrder calldata lo = orders[i];
            if (lo.to == address(0)) revert IDiggers.LockConfigInvalid();
            if (lo.tranches > 0 && lo.duration == 0) revert IDiggers.LockConfigInvalid();
            sum += lo.shareWad;
        }
        if (sum != WAD) revert IDiggers.LockConfigInvalid();

        // Split `purchased` (already delivered here by the carrying swap) by share; the
        // last row absorbs rounding dust. `tranches > 0` opens a fresh lock position for
        // `to`; `tranches == 0` is a plain immediate transfer.
        uint256 allocated;
        for (uint256 i; i < n; ++i) {
            IDiggers.LockOrder calldata lo = orders[i];
            uint256 amount = (i == n - 1) ? purchased - allocated : DiggerMath.md512(purchased, lo.shareWad, WAD);
            allocated += amount;
            if (amount == 0) continue;

            if (lo.tranches > 0) {
                _lock(token, lo.to, funder, amount, lo.tranches, lo.duration);
            } else {
                DiggersToken(payable(token)).transfer(lo.to, amount);
            }
        }
    }

    // ------------------------------------------------------------ withdrawals

    /// @inheritdoc IDiggersLocker
    /// @dev Effects via {_payout} first; single transfer to `wallet` (never to msg.sender).
    function withdraw(address token, address wallet, uint256 index) external nonReentrant returns (uint256 amount) {
        IDiggers.Lock[] storage list = _locks[token][wallet];
        if (index >= list.length) revert IDiggers.UnknownLock();
        amount = _payout(list[index], token, wallet, index, type(uint256).max);
        if (amount == 0) revert IDiggers.NothingToWithdraw();
        DiggersToken(payable(token)).transfer(wallet, amount);
    }

    /// @inheritdoc IDiggersLocker
    /// @dev Sweeps every lock index; gas-bounded in practice by {MIN_LOCK_AMOUNT} grief floor.
    function withdrawAll(address token, address wallet) external nonReentrant returns (uint256 amount) {
        IDiggers.Lock[] storage list = _locks[token][wallet];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            amount += _payout(list[i], token, wallet, i, type(uint256).max);
        }
        if (amount == 0) revert IDiggers.NothingToWithdraw();
        DiggersToken(payable(token)).transfer(wallet, amount);
    }

    /// @inheritdoc IDiggersLocker
    /// @dev Designed for pre-graduation 2% wallet-cap headroom: pass remaining headroom as
    ///      `maxAmount` so the payout cannot trip DiggersToken's anti-whale shield.
    function withdrawUpTo(address token, address wallet, uint256[] calldata indexes, uint256 maxAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        IDiggers.Lock[] storage list = _locks[token][wallet];
        uint256 len = list.length;
        uint256 left = maxAmount;
        for (uint256 i; i < indexes.length && left > 0; ++i) {
            uint256 index = indexes[i];
            if (index >= len) revert IDiggers.UnknownLock();
            left -= _payout(list[index], token, wallet, index, left);
        }
        amount = maxAmount - left;
        if (amount == 0) revert IDiggers.NothingToWithdraw();
        DiggersToken(payable(token)).transfer(wallet, amount);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IDiggersLocker
    function lockCountOf(address token, address wallet) external view returns (uint256) {
        return _locks[token][wallet].length;
    }

    /// @inheritdoc IDiggersLocker
    function getLock(address token, address wallet, uint256 index) external view returns (IDiggers.Lock memory) {
        IDiggers.Lock[] storage list = _locks[token][wallet];
        if (index >= list.length) revert IDiggers.UnknownLock();
        return list[index];
    }

    /// @inheritdoc IDiggersLocker
    function withdrawableOf(address token, address wallet, uint256 index) external view returns (uint256) {
        IDiggers.Lock[] storage list = _locks[token][wallet];
        if (index >= list.length) revert IDiggers.UnknownLock();
        IDiggers.Lock storage l = list[index];
        return _unlockedOf(l) - l.withdrawn;
    }

    /// @inheritdoc IDiggersLocker
    function lockedOf(address token, address wallet) external view returns (uint256) {
        return _lockedOf[token][wallet];
    }

    /// @inheritdoc IDiggersLocker
    function lockedSupplyOf(address token) external view returns (uint256) {
        return _lockedSupply[token];
    }

    // -------------------------------------------------------------- internal

    /// @notice Opens a fresh lock (funds must already sit on the locker), bumps both
    ///         still-locked aggregates, and relays the indexer-complete `Locked` through
    ///         the hub.
    /// @dev Guards here cover BOTH paths (create tables keep wide external types):
    ///      packed-layout ranges, the anti-grief size floor, and recipient sanity — the
    ///      locker (escrow itself), the launchpad, and the token (the buyback pot) can
    ///      never be lock wallets.
    /// @param token Escrowed DiggersToken.
    /// @param wallet Lock owner / eventual payout recipient.
    /// @param funder Outer caller recorded on the Hub `Locked` event only.
    /// @param amount Raw token units locked (≥ {MIN_LOCK_AMOUNT}).
    /// @param tranches Equal unlock slices across `duration`.
    /// @param duration Vesting duration in seconds from `block.timestamp`.
    function _lock(address token, address wallet, address funder, uint256 amount, uint32 tranches, uint64 duration)
        private
    {
        if (amount > type(uint128).max || duration > type(uint40).max || tranches > type(uint16).max) {
            revert IDiggers.LockConfigInvalid();
        }
        if (amount < MIN_LOCK_AMOUNT || wallet == address(this) || wallet == token || wallet == DIGGERS) {
            revert IDiggers.LockConfigInvalid();
        }

        IDiggers.Lock[] storage list = _locks[token][wallet];
        uint256 index = list.length;
        list.push(
            IDiggers.Lock({
                total: uint128(amount),
                start: uint40(block.timestamp),
                duration: uint40(duration),
                tranches: uint16(tranches),
                withdrawn: 0
            })
        );

        uint256 walletLocked = _lockedOf[token][wallet] + amount;
        _lockedOf[token][wallet] = walletLocked;
        uint256 supplyLocked = _lockedSupply[token] + amount;
        _lockedSupply[token] = supplyLocked;

        IDiggersHub(HUB).logLocked(
            token, wallet, index, funder, amount, uint64(block.timestamp), duration, tranches, walletLocked, supplyLocked
        );
    }

    /// @notice Settles up to `maxTake` of one lock's vested-but-unpaid amount in storage
    ///         (effects only — the caller does the actual transfer) and relays `Withdrawn`
    ///         through the hub.
    /// @dev Returns 0 untouched when nothing is withdrawable (or the budget is spent).
    /// @param l Storage pointer to the lock row.
    /// @param token Escrowed DiggersToken.
    /// @param wallet Lock owner.
    /// @param index Lock index (for the Hub event).
    /// @param maxTake Cap on raw token units taken this call.
    /// @return amount Raw token units booked as withdrawn (0 if none).
    function _payout(IDiggers.Lock storage l, address token, address wallet, uint256 index, uint256 maxTake)
        private
        returns (uint256 amount)
    {
        amount = _unlockedOf(l) - l.withdrawn;
        if (amount > maxTake) amount = maxTake;
        if (amount == 0) return 0;

        l.withdrawn += uint128(amount);

        uint256 walletLocked = _lockedOf[token][wallet] - amount;
        _lockedOf[token][wallet] = walletLocked;
        uint256 supplyLocked = _lockedSupply[token] - amount;
        _lockedSupply[token] = supplyLocked;

        IDiggersHub(HUB).logWithdrawn(token, wallet, index, amount, walletLocked, supplyLocked);
    }

    /// @notice Vested amount at the current timestamp (not yet net of `withdrawn`).
    /// @dev Formula: `total · min(tranches, elapsed·tranches/duration) / tranches`, floored —
    ///      the curve moves in discrete slices exactly at each boundary
    ///      (`duration/tranches · k`). Full unlock when `elapsed >= duration`.
    /// @param l Storage pointer to the lock row.
    /// @return Vested raw token units at `block.timestamp`.
    function _unlockedOf(IDiggers.Lock storage l) private view returns (uint256) {
        uint256 elapsed = block.timestamp - l.start;
        if (elapsed >= l.duration) return l.total;
        uint256 vestedTranches = (elapsed * l.tranches) / l.duration;
        return (uint256(l.total) * vestedTranches) / l.tranches;
    }
}
