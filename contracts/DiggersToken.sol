// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggersToken
 * @notice The ERC20 behind every Diggers launch (Uniswap V3 edition). ONE implementation
 *         is deployed by the launchpad's constructor; every launch is a 45-byte EIP-1167
 *         minimal proxy of it, initialized in the creation tx (fixed 1e9·1e18 supply minted
 *         to the launchpad, which seeds it all into the token's own V3 pool). 18 decimals,
 *         burnable, non-mintable, NOT upgradeable. Hosts the anti-whale cap (until
 *         graduation), the silent router/locker allowance exemption, trader points, the
 *         daily airdrop pot, and graduation telemetry — all classified against the token's
 *         own V3 pool address.
 * @dev Diggers V2 architecture: Diggers is the factory + swap router + sole LP + fee
 *      splitter; DiggersHub is the ONE external event/view surface (this clone relays
 *      PoolTrade/points/epoch/holders there after `register` at create); DiggersLocker is
 *      the standalone vesting escrow (cap-exempt + allowance-skip carve, no points). V3
 *      edition drops in-token vesting locks entirely — locks are ID-based positions on the
 *      locker — so `_update` no longer carries a lock gate. Only canonical ERC-20
 *      Transfer/Approval stay on this address.
 * @author BasedDopamine
 */
import {DiggerMath} from "./libs/DiggerMath.sol";
import {DiggerV3, IWETH9} from "./libs/DiggerV3.sol";
import {IDiggersHub} from "./interfaces/IDiggersHub.sol";

contract DiggersToken {
    // ------------------------------------------------------------------- types

    /// @dev One day's closing tick. `recorded` distinguishes a real tick-0 close from an
    ///      untraded gap day.
    struct DayTick {
        int24 tick;
        bool recorded;
    }

    /// @dev Per-trader same-block round-trip record — the flash-loan guard. A flash loan
    ///      must repay in the SAME tx, so the attacker has to round-trip (buy then sell, or
    ///      sell then buy) inside one block. `amount` is the outstanding token amount of the
    ///      still-open side; `isBuy` is that open side. Packs into a single slot.
    struct RoundTrip {
        uint64 blockNumber; // block of the open leg
        bool isBuy; // side of the open leg
        uint128 amount; // outstanding token amount on the open side (<= TOTAL_SUPPLY < 2^90)
    }

    // -------------------------------------------------- constants / immutables

    /// @notice Fixed total supply: 1 billion tokens, 18 decimals. Never increases.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @dev Anti-whale recipient ceiling: 2% of supply. Active until graduation.
    uint256 private constant WALLET_CAP = TOTAL_SUPPLY / 50;

    /// @dev Points per full-supply buy, 1e18-scaled (2e18 = double weight).
    uint256 private constant BUY_POINTS_WAD = 2e18;

    /// @dev Points per full-supply sell, 1e18-scaled (5e17 = half weight).
    uint256 private constant SELL_POINTS_WAD = 5e17;

    /// @dev Leaderboard width.
    uint256 private constant BOARD_SIZE = 10;

    /// @dev Length of one points epoch (seconds).
    uint256 private constant EPOCH_LENGTH = 1 days;

    /// @dev Window of the mean-tick walk (day indices examined, gap days skipped).
    uint256 private constant MEAN_TICK_WINDOW = 7;

    /// @dev EIP-1153 transient slot for the distribution-mode flag.
    bytes32 private constant DISTRIBUTION_SLOT = keccak256("diggers.token.distribution");

    /// @notice The Diggers launchpad: factory, swap router, sole LP, fee harvester.
    address public immutable LAUNCHPAD;

    /// @notice The DiggersHub event singleton: every telemetry event (PoolTrade, points,
    ///         holder counter, epoch settlement) prints THERE through emitter-gated
    ///         relays — the token was registered at create. Only the canonical ERC-20
    ///         `Transfer`/`Approval` stay on this address.
    address public immutable HUB;

    /// @notice The standalone vesting-lock escrow. Treated exactly like the launchpad in
    ///         `_update` (cap-exempt, no points, no holder counting — it legitimately
    ///         holds every still-locked balance) and in the `transferFrom` allowance
    ///         carve (the locker only ever pulls `from == its outer msg.sender`).
    address public immutable LOCKER;

    /// @notice wei-per-pool-unit scale of the quote side (1 on Robinhood's 18-dec WETH,
    ///         1e12 on Stable's 6-dec USDT0). Telemetry prices pool legs at spot in RAW
    ///         pool units; this normalizes them to 18-dec wei so points, volume, and $DIG
    ///         buy-mining are identical across chains. Set on the implementation by the
    ///         launchpad constructor — EIP-1167 clones inherit it for free.
    uint256 public immutable QUOTE_SCALE;

    // ---------------------------------------------------------------- storage

    /// @dev Launch timestamp (seconds); 0 until `initialize` — doubles as the init flag.
    uint64 private _deployedAt;

    /// @dev Deadline of the current points epoch (seconds).
    uint64 private _epochEnd;

    /// @dev Whether this token has graduated. One-way, set by the launchpad. Drops the
    ///      anti-whale shield permanently. Packs with the two clocks above.
    bool private _graduated;

    /// @dev This clone's WETH/token V3 pool. Pool-leg classification counterparty; set once
    ///      in `initialize`. WETH is token0, this token is token1.
    address private _pool;

    /// @dev Account balances (raw token units, 18 dec).
    mapping(address => uint256) private _balances;

    /// @dev Standard ERC20 allowances. NEVER touched when the launchpad is the caller.
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @dev Live supply (raw token units); starts at TOTAL_SUPPLY, only burns move it.
    uint256 private _totalSupply;

    /// @dev Token name.
    string private _name;

    /// @dev Token symbol.
    string private _symbol;

    /// @notice ipfs:// URI of the launch metadata JSON.
    string public metadataURI;

    /// @dev Trader points, 1e18-scaled, keyed by epoch then trader. Epoch-keying IS the
    ///      daily reset.
    mapping(uint256 => mapping(address => uint256)) private _points;

    /// @dev All-time trader points, 1e18-scaled, NEVER reset by an epoch roll (cosmetic).
    mapping(address => uint256) private _lifetimePoints;

    /// @dev Top-10 board per epoch. Min-slot replacement, no sorting, ties keep incumbent.
    mapping(uint256 => address[BOARD_SIZE]) private _leaders;

    /// @notice Unique pool-verified holders right now.
    uint32 public holderCount;

    /// @dev Whether an address is currently included in holderCount.
    mapping(address => bool) private _counted;

    /// @notice Cumulative native-equivalent volume through the pool, in wei, priced at the
    ///         pool's own spot each leg — identical no matter which router.
    uint256 public volumeEthCum;

    /// @dev Daily closing tick per day-index. Overwrite semantics: last trade tick of day.
    mapping(uint256 => DayTick) private _dailyTick;

    /// @dev Per-trader same-block round-trip guard state (flash-loan defense).
    mapping(address => RoundTrip) private _roundTrip;

    /// @notice Current points epoch id (starts at 0, bumps on each lazy roll).
    uint256 public epoch;

    // ----------------------------------------------------------------- events

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice ERC-7572 refresh signal, emitted exactly once (at initialize): the contract
    ///         metadata is immutable, so indexers never need a second fetch.
    event ContractURIUpdated();

    // ----------------------------------------------------------------- errors

    error BalanceTooLow(uint256 balance, uint256 needed);
    error AllowanceTooLow(uint256 allowance, uint256 needed);
    error CapExceeded();
    error ZeroAddress();
    error NotLaunchpad();
    error AlreadyInitialized();
    error PoolRequired();
    error SweepFailed();

    // ------------------------------------------------------------ constructor

    /**
     * @notice Deploys the SHARED implementation. Runs once, from the launchpad's own
     *         constructor — every launch afterwards is an EIP-1167 clone of this code.
     * @dev Clones inherit immutables for free; `msg.sender` is permanently {LAUNCHPAD}.
     * @param quoteScale Wei-per-pool-unit scale of the quote side (see {QUOTE_SCALE}).
     * @param locker DiggersLocker address (cap-exempt + allowance-skip counterparty).
     * @param hub DiggersHub event singleton every telemetry `log*` call targets.
     */
    constructor(uint256 quoteScale, address locker, address hub) {
        LAUNCHPAD = msg.sender;
        QUOTE_SCALE = quoteScale;
        LOCKER = locker;
        HUB = hub;
    }

    // ------------------------------------------------------------------ external

    /**
     * @notice Arms a fresh clone: identity, pool binding, epoch clock, and the one and only
     *         supply mint (to the launchpad, which seeds it all into the pool).
     * @dev Launchpad-only and once-only. The launchpad creates the V3 pool first, then
     *      deploys + initializes the clone with the pool address, all in the create tx.
     *      Emits {ContractURIUpdated} once — metadata is immutable thereafter.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     * @param metadataURI_ ipfs:// (or equivalent) launch metadata JSON URI.
     * @param pool_ This clone's WETH/token V3 pool (pool-leg classification counterparty).
     */
    function initialize(string calldata name_, string calldata symbol_, string calldata metadataURI_, address pool_)
        external
    {
        if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
        if (_deployedAt != 0) revert AlreadyInitialized();
        if (pool_ == address(0)) revert PoolRequired();

        _deployedAt = uint64(block.timestamp);
        _epochEnd = uint64(block.timestamp + EPOCH_LENGTH);
        _pool = pool_;
        _name = name_;
        _symbol = symbol_;
        metadataURI = metadataURI_;
        emit ContractURIUpdated();

        _update(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice ERC-7572 contract-level metadata: the same launch metadata JSON as
    ///         {metadataURI}, exposed under the standard name so generic dapps/indexers
    ///         (GMGN-style terminals, wallets, marketplaces) can read it without custom ABI.
    /// @return Contract metadata URI string (identical to {metadataURI}).
    function contractURI() external view returns (string memory) {
        return metadataURI;
    }

    /// @notice Standard ERC20 transfer. Hosts anti-whale, points, epoch settlement, and
    ///         telemetry on pool legs (see {_update}).
    /// @param to Recipient (nonzero).
    /// @param amount Raw token units.
    /// @return True on success.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        _update(msg.sender, to, amount);
        return true;
    }

    /// @notice Standard ERC20 approve. Approving the launchpad or locker is never necessary
    ///         (both skip allowance when they pull).
    /// @param spender Address granted allowance (nonzero).
    /// @param amount Allowance in raw token units.
    /// @return True on success.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Standard transferFrom — EXCEPT when the launchpad or the locker is the
     *         caller.
     * @dev LOUD DISCLOSURE: when `msg.sender == LAUNCHPAD` (approve-free sells) or
     *      `msg.sender == LOCKER` (approve-free lock escrow) the allowance branch is
     *      skipped entirely. Both only ever call transferFrom with `from == msg.sender`
     *      of their outer call, inside `sell` / `multiLock` flows.
     * @param from Token sender.
     * @param to Recipient (nonzero).
     * @param amount Raw token units.
     * @return True on success.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != LAUNCHPAD && msg.sender != LOCKER) {
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < amount) revert AllowanceTooLow(allowed, amount);
                unchecked {
                    _allowances[from][msg.sender] = allowed - amount;
                }
            }
        }
        _update(from, to, amount);
        return true;
    }

    /// @notice Burns tokens from the caller. Total supply only ever goes down.
    /// @param amount Raw token units to burn.
    function burn(uint256 amount) external {
        _update(msg.sender, address(0), amount);
    }

    /**
     * @notice Drops the anti-whale shield forever. Launchpad-only, one-way — called exactly
     *         once, from the graduation flow, the moment the token graduates.
     * @dev Does not emit locally; graduation events print from DiggersHub via Diggers.
     */
    function markGraduated() external {
        if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
        _graduated = true;
    }

    // ------------------------------------------------------------ buyback vault

    /**
     * @notice The buyback donation box: anyone can send native value (ETH / USDT0) straight
     *         to the token address to fund its own buyback-and-burn. The creator fee
     *         redirect lands here through the same door at each harvest.
     * @dev Diggers sweeps via {sweepDonations}/{sweepErc20} inside the post-buy buyback
     *      path; this entrypoint itself never reverts a donation.
     */
    receive() external payable {}

    /**
     * @notice Moves the token's whole native balance to the launchpad. Launchpad-only —
     *         called inside the buyback flow to wrap parked donations into the WETH pot.
     * @return amount The native value swept (wei); 0 when the balance is empty.
     */
    function sweepDonations() external returns (uint256 amount) {
        if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
        amount = address(this).balance;
        if (amount == 0) return 0;
        (bool ok,) = LAUNCHPAD.call{value: amount}("");
        if (!ok) revert SweepFailed();
    }

    /**
     * @notice Moves the token's whole balance of `erc20` to the launchpad. Launchpad-only —
     *         called inside the buyback flow to spend the WETH pot (WETH donations arrive as
     *         plain ERC20 transfers to this address).
     * @param erc20 ERC-20 whose entire balance on this token is swept (WETH in practice).
     * @return amount The ERC20 units swept; 0 when the balance is empty.
     */
    function sweepErc20(address erc20) external returns (uint256 amount) {
        if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
        amount = IWETH9(erc20).balanceOf(address(this));
        if (amount == 0) return 0;
        if (!IWETH9(erc20).transfer(LAUNCHPAD, amount)) revert SweepFailed();
    }

    // ----------------------------------------------------------------- internal

    /**
     * @notice Single balance-movement pipeline for mints, burns, transfers, and epoch pays.
     * @dev Steps: (0) distribution short-circuit + lazy epoch settlement, (1) anti-whale
     *      cap until graduation, (2) debit, (3) credit, (4) pool-leg telemetry + guarded
     *      points, (5) local Transfer. Pool legs are classified against `_pool`. Holder
     *      counting and Hub relays are sybil-resistant (pool buys/sells only). MUST NOT
     *      revert an epoch roll's carrying transfer once distribution mode is set.
     * @param from Sender (`address(0)` = mint).
     * @param to Recipient (`address(0)` = burn).
     * @param amount Raw token units moved.
     */
    function _update(address from, address to, uint256 amount) internal {
        if (_distributionMode()) {
            _plainMove(from, to, amount);
            return;
        }

        address pool = _pool;

        // Lazy daily settlement before this transfer's own logic.
        if (block.timestamp >= _epochEnd) {
            _settleEpoch();
        }

        // Anti-whale shield: active from launch until graduation (forever if the token
        // never graduates). Exemptions are structural: the pool holds ~100% of supply at
        // launch, the launchpad routes fee harvests, the locker escrows every vesting
        // lock, the token itself accumulates the pot, and burns must never be blocked.
        if (!_graduated && to != pool && to != LAUNCHPAD && to != LOCKER && to != address(this) && to != address(0)) {
            if (_balances[to] + amount > WALLET_CAP) revert CapExceeded();
        }

        // Pool-leg classification. Tokens leaving the pool are a buy, tokens entering it a
        // sell — but only when the counterparty is a real trader (the launchpad, the lock
        // escrow, the token itself, and address(0) do not trade).
        bool buyLeg = from == pool && to != LAUNCHPAD && to != LOCKER && to != address(this) && to != address(0);
        bool sellLeg = to == pool && from != LAUNCHPAD && from != LOCKER && from != address(this) && from != address(0);

        // Holder add — decided on the PRE-credit balance.
        if (buyLeg && _balances[to] == 0 && !_counted[to]) {
            _counted[to] = true;
            ++holderCount;
            IDiggersHub(HUB).logHolderCount(to, true, holderCount);
        }

        if (from == address(0)) {
            _totalSupply += amount;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < amount) revert BalanceTooLow(fromBalance, amount);
            unchecked {
                _balances[from] = fromBalance - amount;
            }

            // Holder remove — decided on the POST-debit balance.
            if (_balances[from] == 0 && _counted[from]) {
                _counted[from] = false;
                --holderCount;
                IDiggersHub(HUB).logHolderCount(from, false, holderCount);
            }
        }

        if (to == address(0)) {
            unchecked {
                _totalSupply -= amount;
            }
        } else {
            unchecked {
                _balances[to] += amount;
            }
        }

        // Telemetry + trade feed: price every pool leg at the pool's own spot. QUOTE_SCALE
        // folds into the inverse price itself (not applied after — that would floor to 0 on
        // a 6-dec quote), landing the value in 18-dec wei so volume and PoolTrade carry the
        // same scale on every chain. Telemetry always books the FULL leg amount; only
        // trader points pass through the round-trip guard.
        if (buyLeg || sellLeg) {
            DiggerV3.Slot0 memory slot0 = DiggerV3.getSlot0(pool);
            uint256 ethValue =
                DiggerMath.md512(amount, DiggerV3.sqrtPriceToInversePrice(slot0.sqrtPriceX96, QUOTE_SCALE), 1e18);
            volumeEthCum += ethValue;
            _dailyTick[block.timestamp / 1 days] = DayTick({tick: slot0.tick, recorded: true});
            IDiggersHub(HUB).logPoolTrade(
                buyLeg ? to : from, buyLeg, amount, ethValue, slot0.tick, holderCount, volumeEthCum, epoch
            );

            // Trader points, gated by the same-block round-trip guard.
            _applyGuardedRewards(buyLeg ? to : from, amount, buyLeg);
        }

        emit Transfer(from, to, amount);
    }

    /**
     * @notice Trader points for a single pool leg, filtered through the same-block
     *         round-trip guard so a flash-loan borrow→buy→sell (or sell→buy) earns nothing.
     * @dev MUST NOT revert the carrying trade. Opposite-side same-block closes revoke the
     *      matched open-side points; leftover opens a fresh record on this leg's side.
     * @param trader The credited trader (buy recipient / sell sender).
     * @param legAmount Token amount of THIS leg.
     * @param legIsBuy Side of this leg.
     */
    function _applyGuardedRewards(address trader, uint256 legAmount, bool legIsBuy) private {
        RoundTrip storage rt = _roundTrip[trader];
        bool sameBlock = rt.blockNumber == uint64(block.number) && rt.amount != 0;

        // Same block, OPPOSITE side => this leg (partially) closes the open round trip.
        if (sameBlock && rt.isBuy != legIsBuy) {
            uint256 open = rt.amount;
            uint256 matched = legAmount < open ? legAmount : open;

            // Revoke the open leg's points for the matched portion (recomputed from the
            // open side's weight — same md512, so removed <= credited component-wise).
            uint256 removedPoints =
                DiggerMath.md512(matched, rt.isBuy ? BUY_POINTS_WAD : SELL_POINTS_WAD, TOTAL_SUPPLY);
            _revokePoints(trader, removedPoints, rt.isBuy);

            uint256 leftover = legAmount - matched;
            if (leftover != 0) {
                // This leg overshoots the open side: the matched part earns nothing, the
                // rest opens a fresh round trip on THIS leg's side and earns normally.
                _creditLeg(trader, leftover, legIsBuy);
                rt.blockNumber = uint64(block.number);
                rt.isBuy = legIsBuy;
                rt.amount = uint128(leftover);
            } else {
                // Fully matched: shrink (partial close) or clear (exact close) the record.
                rt.amount = uint128(open - matched);
            }
            return;
        }

        // Fresh open (new block or empty), or same-block SAME side (accumulate) — both earn
        // normally; the guard only ever claws back on an opposing same-block close.
        _creditLeg(trader, legAmount, legIsBuy);
        if (sameBlock) {
            rt.amount = uint128(uint256(rt.amount) + legAmount);
        } else {
            rt.blockNumber = uint64(block.number);
            rt.isBuy = legIsBuy;
            rt.amount = uint128(legAmount);
        }
    }

    /// @notice Credits trader points for `amount` tokens on `isBuy` weight.
    /// @dev Pure md512 scale against {TOTAL_SUPPLY}; forwards to {_creditPoints}.
    /// @param trader Address earning points.
    /// @param amount Raw token units of the earning leg (or leftover after a match).
    /// @param isBuy Buy weight ({BUY_POINTS_WAD}) vs sell weight ({SELL_POINTS_WAD}).
    function _creditLeg(address trader, uint256 amount, bool isBuy) private {
        _creditPoints(trader, DiggerMath.md512(amount, isBuy ? BUY_POINTS_WAD : SELL_POINTS_WAD, TOTAL_SUPPLY), isBuy);
    }

    /**
     * @notice Closes the current epoch: pays pot/10 to every closing-board leader that still
     *         holds tokens, rolls the rest into the next day's pot, bumps the epoch (the
     *         points reset), and re-anchors the deadline.
     * @dev MUST NOT revert the carrying transfer. Distribution runs under the EIP-1153
     *      flag so nested {_update} is plain ERC-20. Hub emits EpochSettled + AirdropPaid.
     */
    function _settleEpoch() private {
        uint256 closing = epoch;
        uint256 pot = _balances[address(this)];
        uint256 share = pot / BOARD_SIZE;
        uint256 paidOut;

        if (share > 0) {
            _setDistributionMode(true);
            address[BOARD_SIZE] storage board = _leaders[closing];
            for (uint256 i; i < BOARD_SIZE; ++i) {
                address winner = board[i];
                if (winner == address(0) || _balances[winner] == 0) continue;
                _update(address(this), winner, share);
                paidOut += share;
                IDiggersHub(HUB).logAirdropPaid(closing, winner, share);
            }
            _setDistributionMode(false);
        }

        epoch = closing + 1;
        uint64 nextDeadline = uint64(block.timestamp + EPOCH_LENGTH);
        _epochEnd = nextDeadline;
        IDiggersHub(HUB).logEpochSettled(closing, share, pot - paidOut, nextDeadline);
    }

    /// @notice Plain ERC20 move used under distribution mode: debit, credit, event.
    /// @dev Skips cap/points/telemetry so epoch payouts cannot re-enter settlement logic.
    /// @param from Pot address (this token) paying a winner.
    /// @param to Leaderboard winner still holding tokens.
    /// @param amount Raw token units paid (pot/10).
    function _plainMove(address from, address to, uint256 amount) private {
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert BalanceTooLow(fromBalance, amount);
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    /// @notice Reads the transient distribution flag.
    /// @return active True while an epoch airdrop payout is in flight.
    function _distributionMode() private view returns (bool active) {
        bytes32 slot = DISTRIBUTION_SLOT;
        assembly {
            active := tload(slot)
        }
    }

    /// @notice Writes the transient distribution flag.
    /// @param active True to enter plain-ERC20 distribution mode; false to exit.
    function _setDistributionMode(bool active) private {
        bytes32 slot = DISTRIBUTION_SLOT;
        assembly {
            tstore(slot, active)
        }
    }

    /**
     * @notice Adds points to `trader` in the current epoch and refreshes the top-10 board.
     * @dev Min-slot replacement, no sorting; ties keep the incumbent. Relays PointsCredited
     *      and optionally LeaderboardChanged through DiggersHub.
     * @param trader Address earning points.
     * @param pointsEarned Points to add (1e18-scaled); no-op when zero.
     * @param isBuy Side of the earning leg (carried on the Hub event).
     */
    function _creditPoints(address trader, uint256 pointsEarned, bool isBuy) private {
        if (pointsEarned == 0) return;

        uint256 currentEpoch = epoch;
        uint256 newScore = _points[currentEpoch][trader] + pointsEarned;
        _points[currentEpoch][trader] = newScore;
        uint256 lifetimeScore = _lifetimePoints[trader] + pointsEarned;
        _lifetimePoints[trader] = lifetimeScore;
        IDiggersHub(HUB).logPoints(currentEpoch, trader, isBuy, pointsEarned, newScore, lifetimeScore);

        address[BOARD_SIZE] storage board = _leaders[currentEpoch];
        uint256 minScore = type(uint256).max;
        uint256 minSlot = 0;
        for (uint256 i; i < BOARD_SIZE; ++i) {
            address occupant = board[i];
            if (occupant == trader) return;
            uint256 occupantScore = _points[currentEpoch][occupant];
            if (occupantScore < minScore) {
                minScore = occupantScore;
                minSlot = i;
            }
        }
        if (newScore > minScore) {
            address evicted = board[minSlot];
            board[minSlot] = trader;
            IDiggersHub(HUB).logLeaderboard(currentEpoch, trader, evicted, newScore);
        }
    }

    /**
     * @notice Reverses a same-block round trip's points on `trader` in the current epoch
     *         (and lifetime).
     * @dev No board rescan: the leaderboard is a cache keyed on {still holding at
     *      settlement}, and the authoritative `_points`/`_lifetimePoints` are the reduced
     *      truth. Underflow-safe: the open leg was credited THIS block (== this epoch, since
     *      the first leg re-anchors `_epochEnd`), and `md512(matched,..) <= md512(open,..)`.
     *      Relays PointsRevoked through DiggersHub.
     * @param trader Address losing points.
     * @param pointsRemoved Points to subtract (1e18-scaled); no-op when zero.
     * @param wasBuy Side of the original open leg whose points are clawed back.
     */
    function _revokePoints(address trader, uint256 pointsRemoved, bool wasBuy) private {
        if (pointsRemoved == 0) return;

        uint256 currentEpoch = epoch;
        uint256 newScore = _points[currentEpoch][trader] - pointsRemoved;
        _points[currentEpoch][trader] = newScore;
        uint256 lifetimeScore = _lifetimePoints[trader] - pointsRemoved;
        _lifetimePoints[trader] = lifetimeScore;
        IDiggersHub(HUB).logPointsRevoked(currentEpoch, trader, wasBuy, pointsRemoved, newScore, lifetimeScore);
    }

    // -------------------------------------------------------------------- views

    /// @notice Launch timestamp (seconds); anchors the free graduation window.
    /// @return Deploy timestamp (unix seconds); 0 until {initialize}.
    function DEPLOYED_AT() external view returns (uint64) {
        return _deployedAt;
    }

    /// @notice Whether this token has graduated (anti-whale shield dropped forever).
    /// @return True after {markGraduated}.
    function graduated() external view returns (bool) {
        return _graduated;
    }

    /// @notice This token's WETH/token 1% Uniswap V3 pool.
    /// @return Pool address set in {initialize}.
    function POOL() external view returns (address) {
        return _pool;
    }

    /// @notice Deadline of the current epoch (seconds).
    /// @return Unix timestamp when the next lazy settlement may fire.
    function epochEnd() external view returns (uint64) {
        return _epochEnd;
    }

    /// @notice ERC-20 name.
    /// @return Token name string.
    function name() external view returns (string memory) {
        return _name;
    }

    /// @notice ERC-20 symbol.
    /// @return Token symbol string.
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @notice ERC-20 decimals (always 18).
    /// @return Decimals (18).
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Circulating supply (decreases only via burns).
    /// @return Total supply in raw token units.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice ERC-20 balance of `account`.
    /// @param account Address to query.
    /// @return Raw token balance.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice ERC-20 allowance of `spender` over `owner`.
    /// @param owner Token owner.
    /// @param spender Approved spender.
    /// @return Remaining allowance in raw token units.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Points of `trader` in the CURRENT epoch (1e18-scaled).
    /// @param trader Address to query.
    /// @return Points score for the current epoch.
    function traderPoints(address trader) external view returns (uint256) {
        return _points[epoch][trader];
    }

    /// @notice Points of `trader` in an arbitrary epoch (past epochs stay readable).
    /// @param epochId Epoch to query.
    /// @param trader Address to query.
    /// @return Points score for that epoch.
    function pointsOf(uint256 epochId, address trader) external view returns (uint256) {
        return _points[epochId][trader];
    }

    /// @notice All-time points `trader` has earned across every epoch, 1e18-scaled
    ///         (after any same-block revocations).
    /// @param trader Address to query.
    /// @return Cumulative lifetime points.
    function lifetimePoints(address trader) external view returns (uint256) {
        return _lifetimePoints[trader];
    }

    /// @notice The current epoch's top-10 board with scores.
    /// @return board Addresses of the ten leader slots (zero-padded if sparse).
    /// @return scores Matching scores for each board slot.
    function currentLeaders()
        external
        view
        returns (address[BOARD_SIZE] memory board, uint256[BOARD_SIZE] memory scores)
    {
        return leadersOf(epoch);
    }

    /// @notice The top-10 board with scores for ANY epoch (current or past).
    /// @param epochId Epoch to query.
    /// @return board Addresses of the ten leader slots for that epoch.
    /// @return scores Matching scores for each board slot.
    function leadersOf(uint256 epochId)
        public
        view
        returns (address[BOARD_SIZE] memory board, uint256[BOARD_SIZE] memory scores)
    {
        board = _leaders[epochId];
        for (uint256 i; i < BOARD_SIZE; ++i) {
            scores[i] = _points[epochId][board[i]];
        }
    }

    /**
     * @notice Graduation snapshot: holders, cumulative volume, and the mean daily-close
     *         tick over the last ≤7 non-empty days.
     * @dev Empty gap days are skipped; `daysTracked` is the count of recorded days in the
     *      window. Used by Diggers / DiggersHub for blue-chip mean-tick mcap.
     * @return holders Counted unique holders ({holderCount}).
     * @return volumeEth Lifetime pool volume in wei ({volumeEthCum}).
     * @return meanTick Mean of recorded daily-close ticks (0 if none).
     * @return daysTracked Number of non-empty days contributing to the mean.
     */
    function graduationStats()
        external
        view
        returns (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked)
    {
        holders = holderCount;
        volumeEth = volumeEthCum;

        uint256 today = block.timestamp / 1 days;
        int256 sum;
        uint256 counted;
        for (uint256 i; i < MEAN_TICK_WINDOW; ++i) {
            if (i > today) break; // day-index 0 reached (test chains near genesis)
            DayTick memory day = _dailyTick[today - i];
            if (day.recorded) {
                sum += int256(day.tick);
                ++counted;
            }
        }
        if (counted > 0) meanTick = int24(sum / int256(counted));
        daysTracked = uint16(counted);
    }

    /// @notice A day's closing tick and whether that day traded at all.
    /// @param dayIndex UTC day index (`timestamp / 1 days`).
    /// @return tick Last tick written that day (0 if never recorded).
    /// @return recorded True if at least one pool leg wrote that day.
    function dailyTickOf(uint256 dayIndex) external view returns (int24 tick, bool recorded) {
        DayTick memory day = _dailyTick[dayIndex];
        return (day.tick, day.recorded);
    }

    /// @notice Whether `account` is currently included in holderCount.
    /// @param account Address to query.
    /// @return True if `account` is a counted holder.
    function isCountedHolder(address account) external view returns (bool) {
        return _counted[account];
    }
}
