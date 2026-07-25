// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IDiggers} from "./IDiggers.sol";

/**
 * @title IDiggersHub
 * @notice Interface of the DiggersHub singleton — the protocol's ONE address for the
 *         outside world. EVERY protocol event prints here (the launchpad, the locker,
 *         and every launched token relay through emitter-gated `log*` endpoints) and
 *         every ecosystem view is served here (raw-slot `extsload` reads of the
 *         launchpad's storage plus direct pool/token staticcalls). The UX and the
 *         indexer connect to the hub and nothing else.
 * @dev The hub is bound to its launchpad once (`bind`, called from the Diggers
 *      constructor) and holds no other state than the emitter set. It has no owner, no
 *      funds, and no power over protocol state — pure telemetry + lens. Event
 *      signatures are byte-identical to the pre-hub Diggers ABI, only the emitting
 *      address changed. Struct types are shared from {IDiggers}.
 * @author BasedDopamine
 */
interface IDiggersHub {
    // ----------------------------------------------------------------- events

    /// @notice A new token was deployed, its V3 pool created + initialized, and liquidity
    ///         seeded. Carries the per-token launch config an indexer cannot cheaply derive.
    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string metadataURI,
        address pool,
        uint160 startSqrtPriceX96,
        uint24 poolFee,
        uint128 burnShareWad
    );

    /// @notice The creator ETH fee-split table for a launch, emitted once at create.
    event FeeSplitConfigured(address indexed token, address[] recipients, uint256[] shares);

    /// @notice The fee owner replaced a token's creator ETH fee-split table.
    event FeeSplitUpdated(address indexed token, address[] recipients, uint256[] shares);

    /// @notice A token's full tokenomics config — the single indexer source of truth,
    ///         emitted once at create and again on every `setTokenomics` edit. ETH side:
    ///         buyback/backing/staking carves of the fresh creator slice (sum <= 1e18,
    ///         remainder to the fee-split rows). Token side: burn + stake (sum <= 1e18,
    ///         the airdrop pot is the exact remainder).
    event TokenomicsUpdated(
        address indexed token,
        uint256 buybackShareWad,
        uint256 backingShareWad,
        uint256 stakingShareWad,
        uint256 burnShareWad,
        uint256 stakeShareWad
    );

    /// @notice A per-token fee-split owner changed (`newOwner == 0` == renounced forever).
    event FeeOwnershipTransferred(address indexed token, address indexed previousOwner, address indexed newOwner);

    /// @notice A per-token burn-share owner changed (`newOwner == 0` == renounced forever).
    event BurnOwnershipTransferred(address indexed token, address indexed previousOwner, address indexed newOwner);

    /// @notice A creator fee-split slice could not be delivered and was parked for retry.
    event FeeParked(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Router swap settled. Carries post-trade pool state for indexer upserts.
    event Swapped(
        address indexed token,
        address indexed trader,
        bool indexed isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint160 sqrtPriceAfterX96,
        int24 tickAfter,
        uint128 liquidityAfter,
        uint256 ethInPool,
        uint256 tokenInPool
    );

    /// @notice LP fees collected and split. Team / creator only (no platform), plus
    ///         optional carves off the fresh creator side — buyback pot and the Glue
    ///         backing+staking deposit; `ethToCreators` is already net of `ethToBuyback`
    ///         AND `ethToGlue`. On a failed glue deposit the carve fails open back into
    ///         the normal split, so `ethToGlue`/`tokensToGlue` are 0 and the totals stay
    ///         conserved.
    event Harvested(
        address indexed token,
        address indexed caller,
        uint256 ethTotal,
        uint256 ethToTeam,
        uint256 ethToCreators,
        uint256 ethToBuyback,
        uint256 ethToGlue,
        uint256 tokensBurned,
        uint256 tokensToGlue,
        uint256 tokensToPot
    );

    /// @notice The owner activated the Glue V2 integration (ONE-SHOT — never rotated,
    ///         never unset). Before this, all glue fee shares are forced to zero.
    event GlueActivated(address indexed glue);

    /// @notice A buyback executed after a user buy: the token's pot (donations + creator
    ///         redirect) bought `tokensBurned` tokens on the pool and burned them. Sized so
    ///         the buyback output never exceeds the carrying user buy's output.
    event BuybackBurned(address indexed token, uint256 ethIn, uint256 tokensBurned);

    /// @notice Pull-payment ETH claim settled.
    event Claimed(address indexed account, uint256 amount);

    /// @notice A token graduated: enough of the fixed supply was bought OUT of its pool
    ///         (`balanceOf(pool)` fell to the sold-fraction threshold; price plays no
    ///         role, foreign LP only makes the bar harder). Sets its `graduatedAt` and
    ///         drops the anti-whale shield forever.
    event Graduated(
        address indexed token,
        bytes32 indexed nameKey,
        bytes32 indexed symbolKey,
        uint32 holders,
        uint256 volumeEthCum,
        uint256 supplySold
    );

    /// @notice Minimal integrator-facing companion of {Graduated} ("open market now"),
    ///         emitted in the same breath. Third-party terminals subscribe to this one
    ///         topic; `pool` is where the liquidity lives. Our indexer keeps using the
    ///         rich {Graduated}.
    event TokenGraduated(address indexed token, address indexed pool);

    /// @notice A token gained (or regained) the LIVE blue-chip status: lifetime volume,
    ///         mean-tick market cap, AND holder count all clear their thresholds. Sets its
    ///         `blueChippedAt` and locks its name + symbol objects (lock count +1 each).
    event BlueChip(
        address indexed token,
        bytes32 indexed nameKey,
        bytes32 indexed symbolKey,
        uint256 volumeEthCum,
        uint256 avgMcapEth,
        uint32 holders
    );

    /// @notice A blue-chip token lost the status: a LIVE leg (mean-tick market cap or
    ///         holder count) fell below its retention threshold. Clears its
    ///         `blueChippedAt` and unlocks its name + symbol objects (lock count -1
    ///         each). A key whose LAST lock dropped stays uncreatable until `graceUntil`
    ///         (24h) so the token can regain the status before anyone snipes the name.
    event BlueChipLost(
        address indexed token,
        bytes32 indexed nameKey,
        bytes32 indexed symbolKey,
        uint256 avgMcapEth,
        uint32 holders,
        uint64 graceUntil
    );

    /// @notice The owner registered a USD oracle stable (ETH-quote chains only). `unit`
    ///         is 10^decimals — raw asset units per whole USD, cached at registration.
    event OracleAssetAdded(address indexed asset, uint96 unit);

    /// @notice The owner removed a USD oracle stable.
    event OracleAssetRemoved(address indexed asset);

    /// @notice The protocol owner changed (address(0) `newOwner` == renounced forever).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The owner updated the global team share of ETH fees (1e18-scaled).
    event TeamShareUpdated(uint256 teamShareWad);

    /// @notice The owner rotated the team ETH fee-recipient wallet.
    event FeeRecipientUpdated(address indexed feeRecipient);

    /// @notice The owner opened or paused public token creation.
    /// @param open True when anyone may create; false when only the protocol owner may.
    event CreationOpenSet(bool open);

    /// @notice The primary trade feed for a token pool leg.
    event PoolTrade(
        address indexed token,
        address indexed trader,
        bool indexed isBuy,
        uint256 tokenAmount,
        uint256 ethValue,
        int24 tick,
        uint32 holdersAfter,
        uint256 volumeEthCumAfter,
        uint256 epoch
    );

    /// @notice Points credited to a trader on a pool leg.
    event PointsCredited(
        address indexed token,
        uint256 indexed epoch,
        address indexed trader,
        bool isBuy,
        uint256 pointsEarned,
        uint256 newScore,
        uint256 lifetimeScore
    );

    /// @notice Points clawed back from a trader by the same-block round-trip guard
    ///         (flash-loan defense). `newScore`/`lifetimeScore` are the reduced totals.
    event PointsRevoked(
        address indexed token,
        uint256 indexed epoch,
        address indexed trader,
        bool wasBuy,
        uint256 pointsRemoved,
        uint256 newScore,
        uint256 lifetimeScore
    );

    /// @notice The top-10 board changed.
    event LeaderboardChanged(
        address indexed token, uint256 indexed epoch, address indexed entrant, address evicted, uint256 entrantScore
    );

    /// @notice The unique-holder counter changed.
    event HolderCountChanged(address indexed token, address indexed holder, bool added, uint32 holderCountAfter);

    /// @notice A token's epoch closed and its airdrop pot was distributed.
    event EpochSettled(
        address indexed token, uint256 indexed epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline
    );

    /// @notice One leaderboard winner received its share of a token's day pot.
    event AirdropPaid(address indexed token, uint256 indexed epoch, address indexed winner, uint256 amount);

    /// @notice A new vesting lock was escrowed on the locker. `index` is the position in
    ///         the wallet's per-token lock list (the on-chain handle, with token +
    ///         wallet). Indexer-complete: besides the per-lock detail, `walletLocked` and
    ///         `tokenLockedSupply` are the LIVE still-locked aggregates AFTER this lock
    ///         (total minus withdrawn), so a UI can print any wallet's locked balance —
    ///         and the token's locked supply — from the latest event alone, no
    ///         aggregation needed. `funder` is event-only data (never stored).
    event Locked(
        address indexed token,
        address indexed wallet,
        uint256 indexed index,
        address funder,
        uint256 amount,
        uint64 start,
        uint64 duration,
        uint32 tranches,
        uint256 walletLocked,
        uint256 tokenLockedSupply
    );

    /// @notice Vested tokens were paid out of a lock to its wallet. `walletLocked` and
    ///         `tokenLockedSupply` are the still-locked aggregates AFTER the payout.
    event Withdrawn(
        address indexed token,
        address indexed wallet,
        uint256 indexed index,
        uint256 amount,
        uint256 walletLocked,
        uint256 tokenLockedSupply
    );

    /// @notice A new emitter joined the gated set (the launchpad at bind, the locker and
    ///         every token clone via `register`).
    event EmitterRegistered(address indexed emitter);

    // ----------------------------------------------------------------- errors

    /// @notice `bind` was called on an already-bound hub.
    error AlreadyBound();
    /// @notice A `log*` endpoint was called by an address outside the emitter set.
    error NotEmitter();
    /// @notice `register` was called by anyone but the bound launchpad.
    error NotDiggers();

    // ------------------------------------------------------------------ binding

    /// @notice One-shot: the caller becomes the bound launchpad (called from the Diggers
    ///         constructor) and its first emitter. Reverts {AlreadyBound} afterwards.
    function bind() external;

    /// @notice Adds an emitter (the locker at construction, every token clone at create).
    ///         Launchpad-only — the factory itself vouches that `emitter` is family code,
    ///         so a foreign contract can never print into the event stream.
    /// @param emitter Address allowed to call gated `log*` endpoints.
    function register(address emitter) external;

    /// @notice The bound Diggers launchpad (zero until `bind`).
    /// @return The Diggers launchpad address.
    function DIGGERS() external view returns (address);

    /// @notice Whether `account` may print events here (launchpad, locker, token clones).
    /// @param account Address to check.
    /// @return True if `account` is in the emitter set.
    function isEmitter(address account) external view returns (bool);

    // ------------------------------------------------------- log endpoints (gated)

    // Called by token clones (the token identity is ALWAYS msg.sender — unspoofable).

    /// @notice Emitter-gated: emits {PoolTrade} for the calling token.
    /// @param trader Counterparty of the pool leg.
    /// @param isBuy True for buy (from pool), false for sell (to pool).
    /// @param tokenAmount Raw token units moved on the pool leg.
    /// @param ethValue ETH notional of the leg in wei (spot-priced).
    /// @param tick Pool tick after the leg.
    /// @param holdersAfter Counted holder count after the leg.
    /// @param volumeEthCumAfter Lifetime volume after the leg (wei).
    /// @param epoch Token points epoch at emission time.
    function logPoolTrade(
        address trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethValue,
        int24 tick,
        uint32 holdersAfter,
        uint256 volumeEthCumAfter,
        uint256 epoch
    ) external;

    /// @notice Emitter-gated: emits {PointsCredited} for the calling token.
    /// @param epoch Points epoch credited.
    /// @param trader Address that earned points.
    /// @param isBuy Whether the earning leg was a buy.
    /// @param pointsEarned Points added this leg.
    /// @param newScore Trader's epoch score after credit.
    /// @param lifetimeScore Trader's lifetime score after credit.
    function logPoints(
        uint256 epoch,
        address trader,
        bool isBuy,
        uint256 pointsEarned,
        uint256 newScore,
        uint256 lifetimeScore
    ) external;

    /// @notice Emitter-gated: emits {PointsRevoked} for the calling token.
    /// @param epoch Points epoch revoked from.
    /// @param trader Address that lost points.
    /// @param wasBuy Whether the original earning leg was a buy.
    /// @param pointsRemoved Points subtracted.
    /// @param newScore Trader's epoch score after revocation.
    /// @param lifetimeScore Trader's lifetime score after revocation.
    function logPointsRevoked(
        uint256 epoch,
        address trader,
        bool wasBuy,
        uint256 pointsRemoved,
        uint256 newScore,
        uint256 lifetimeScore
    ) external;

    /// @notice Emitter-gated: emits {LeaderboardChanged} for the calling token.
    /// @param epoch Points epoch of the board.
    /// @param entrant Address that entered (or moved on) the board.
    /// @param evicted Address pushed off the board (zero if none).
    /// @param entrantScore Entrant's score after the change.
    function logLeaderboard(uint256 epoch, address entrant, address evicted, uint256 entrantScore) external;

    /// @notice Emitter-gated: emits {HolderCountChanged} for the calling token.
    /// @param holder Address added or removed from the counted set.
    /// @param added True when counted, false when uncounted.
    /// @param holderCountAfter Holder count after the change.
    function logHolderCount(address holder, bool added, uint32 holderCountAfter) external;

    /// @notice Emitter-gated: emits {EpochSettled} for the calling token.
    /// @param epoch Epoch that just closed.
    /// @param potPerWinner Token units paid to each still-holding leader.
    /// @param rolledOver Remainder rolled into the next pot.
    /// @param nextDeadline Unix timestamp of the next epoch end.
    function logEpochSettled(uint256 epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline) external;

    /// @notice Emitter-gated: emits {AirdropPaid} for the calling token.
    /// @param epoch Settled epoch.
    /// @param winner Leaderboard winner paid.
    /// @param amount Raw token units paid.
    function logAirdropPaid(uint256 epoch, address winner, uint256 amount) external;

    // Called by the locker.

    /// @notice Emitter-gated: emits {Locked}.
    /// @param token Escrowed Diggers token.
    /// @param wallet Lock owner / eventual payout recipient.
    /// @param index New lock index in the wallet's per-token list.
    /// @param funder Outer caller that funded the lock (event-only).
    /// @param amount Raw token units locked.
    /// @param start Vesting start timestamp.
    /// @param duration Vesting duration in seconds.
    /// @param tranches Number of equal unlock slices.
    /// @param walletLocked Wallet's still-locked aggregate AFTER this lock.
    /// @param tokenLockedSupply Token-wide still-locked supply AFTER this lock.
    function logLocked(
        address token,
        address wallet,
        uint256 index,
        address funder,
        uint256 amount,
        uint64 start,
        uint64 duration,
        uint32 tranches,
        uint256 walletLocked,
        uint256 tokenLockedSupply
    ) external;

    /// @notice Emitter-gated: emits {Withdrawn}.
    /// @param token Escrowed Diggers token.
    /// @param wallet Lock owner / payout recipient.
    /// @param index Lock index withdrawn from.
    /// @param amount Raw token units paid out.
    /// @param walletLocked Wallet's still-locked aggregate AFTER the payout.
    /// @param tokenLockedSupply Token-wide still-locked supply AFTER the payout.
    function logWithdrawn(
        address token,
        address wallet,
        uint256 index,
        uint256 amount,
        uint256 walletLocked,
        uint256 tokenLockedSupply
    ) external;

    // Called by the launchpad (directly or from its delegatecall libraries).

    /// @notice Emitter-gated: emits {Created}.
    /// @param token Newly launched DiggersToken.
    /// @param creator Launch creator (msg.sender of create).
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param metadataURI Launch metadata URI.
    /// @param pool WETH/token V3 pool address.
    /// @param startSqrtPriceX96 Launch sqrt price (Q64.96).
    /// @param poolFee V3 fee tier (always 10000 = 1%).
    /// @param burnShareWad Initial token-side burn share (1e18-scaled).
    function logCreated(
        address token,
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        address pool,
        uint160 startSqrtPriceX96,
        uint24 poolFee,
        uint128 burnShareWad
    ) external;

    /// @notice Emitter-gated: emits {FeeSplitConfigured}.
    /// @param token Launched Diggers token.
    /// @param recipients Fee-split recipient addresses.
    /// @param shares Matching 1e18-scaled shares (sum to 1e18).
    function logFeeSplitConfigured(address token, address[] calldata recipients, uint256[] calldata shares) external;

    /// @notice Emitter-gated: emits {FeeSplitUpdated}.
    /// @param token Launched Diggers token.
    /// @param recipients New fee-split recipient addresses.
    /// @param shares Matching 1e18-scaled shares (sum to 1e18).
    function logFeeSplitUpdated(address token, address[] calldata recipients, uint256[] calldata shares) external;

    /// @notice Emitter-gated: emits {TokenomicsUpdated}.
    /// @param token Launched Diggers token.
    /// @param buybackShareWad ETH-side buyback carve (1e18-scaled).
    /// @param backingShareWad ETH-side Glue NAV-backing carve (1e18-scaled).
    /// @param stakingShareWad ETH-side Glue staking carve (1e18-scaled).
    /// @param burnShareWad Token-side burn share (1e18-scaled).
    /// @param stakeShareWad Token-side Glue staking share (1e18-scaled).
    function logTokenomicsUpdated(
        address token,
        uint256 buybackShareWad,
        uint256 backingShareWad,
        uint256 stakingShareWad,
        uint256 burnShareWad,
        uint256 stakeShareWad
    ) external;

    /// @notice Emitter-gated: emits {Swapped}.
    /// @param token Launched Diggers token traded.
    /// @param trader Router caller.
    /// @param isBuy True for ETH→token, false for token→ETH.
    /// @param ethAmount ETH side of the swap in wei.
    /// @param tokenAmount Token side of the swap in raw units.
    /// @param sqrtPriceAfterX96 Pool sqrt price after the trade (Q64.96).
    /// @param tickAfter Pool tick after the trade.
    /// @param liquidityAfter In-range liquidity after the trade.
    /// @param ethInPool WETH (or quote) reserve after the trade.
    /// @param tokenInPool Token reserve after the trade.
    function logSwapped(
        address token,
        address trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint160 sqrtPriceAfterX96,
        int24 tickAfter,
        uint128 liquidityAfter,
        uint256 ethInPool,
        uint256 tokenInPool
    ) external;

    /// @notice Emitter-gated: emits {Harvested}.
    /// @param token Launched Diggers token harvested.
    /// @param caller Address that triggered harvest.
    /// @param ethTotal Gross ETH fees collected (wei).
    /// @param ethToTeam Team slice (wei).
    /// @param ethToCreators Creator fee-split slice net of buyback/Glue (wei).
    /// @param ethToBuyback Buyback pot carve (wei).
    /// @param ethToGlue Glue deposit carve (wei); 0 if deposit failed open.
    /// @param tokensBurned Token fees burned.
    /// @param tokensToGlue Token fees sent to Glue staking; 0 if failed open.
    /// @param tokensToPot Token fees added to the daily airdrop pot.
    function logHarvested(
        address token,
        address caller,
        uint256 ethTotal,
        uint256 ethToTeam,
        uint256 ethToCreators,
        uint256 ethToBuyback,
        uint256 ethToGlue,
        uint256 tokensBurned,
        uint256 tokensToGlue,
        uint256 tokensToPot
    ) external;

    /// @notice Emitter-gated: emits {FeeParked}.
    /// @param token Launched Diggers token.
    /// @param recipient Fee-split recipient whose push failed.
    /// @param amount Parked wei for later claim.
    function logFeeParked(address token, address recipient, uint256 amount) external;

    /// @notice Emitter-gated: emits {Claimed}.
    /// @param account Address that received the pull-payment.
    /// @param amount Wei paid out.
    function logClaimed(address account, uint256 amount) external;

    /// @notice Emits BOTH {Graduated} and its integrator companion {TokenGraduated}.
    /// @param token Graduated Diggers token.
    /// @param nameKey Folded name registry key.
    /// @param symbolKey Folded symbol registry key.
    /// @param holders Counted holders at graduation.
    /// @param volumeEthCum Lifetime volume at graduation (wei).
    /// @param supplySold Tokens bought out of the pool at graduation (raw units).
    /// @param pool Token's V3 pool (for {TokenGraduated}).
    function logGraduated(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        uint32 holders,
        uint256 volumeEthCum,
        uint256 supplySold,
        address pool
    ) external;

    /// @notice Emitter-gated: emits {BlueChip}.
    /// @param token Diggers token that gained blue-chip status.
    /// @param nameKey Folded name registry key.
    /// @param symbolKey Folded symbol registry key.
    /// @param volumeEthCum Lifetime volume at grant (wei).
    /// @param avgMcapEth Mean-tick market cap at grant.
    /// @param holders Counted holders at grant.
    function logBlueChip(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        uint256 volumeEthCum,
        uint256 avgMcapEth,
        uint32 holders
    ) external;

    /// @notice Emitter-gated: emits {BlueChipLost}.
    /// @param token Diggers token that lost blue-chip status.
    /// @param nameKey Folded name registry key.
    /// @param symbolKey Folded symbol registry key.
    /// @param avgMcapEth Mean-tick market cap at demotion.
    /// @param holders Counted holders at demotion.
    /// @param graceUntil Unix timestamp until which the keys stay uncreatable.
    function logBlueChipLost(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        uint256 avgMcapEth,
        uint32 holders,
        uint64 graceUntil
    ) external;

    /// @notice Emitter-gated: emits {BuybackBurned}.
    /// @param token Diggers token bought back and burned.
    /// @param ethIn WETH/ETH spent from the pot (wei).
    /// @param tokensBurned Raw token units burned.
    function logBuybackBurned(address token, uint256 ethIn, uint256 tokensBurned) external;

    /// @notice Emitter-gated: emits {OracleAssetAdded}.
    /// @param asset Registered USD oracle stable.
    /// @param unit `10 ** decimals` cached at registration.
    function logOracleAssetAdded(address asset, uint96 unit) external;

    /// @notice Emitter-gated: emits {OracleAssetRemoved}.
    /// @param asset Removed USD oracle stable.
    function logOracleAssetRemoved(address asset) external;

    /// @notice Emitter-gated: emits {GlueActivated}.
    /// @param glue Glue V2 deposit router address.
    function logGlueActivated(address glue) external;

    /// @notice Emitter-gated: emits {TeamShareUpdated}.
    /// @param teamShareWad New global team share (1e18-scaled).
    function logTeamShareUpdated(uint256 teamShareWad) external;

    /// @notice Emitter-gated: emits {FeeRecipientUpdated}.
    /// @param feeRecipient New team fee-recipient wallet.
    function logFeeRecipientUpdated(address feeRecipient) external;

    /// @notice Emitter-gated: emits {CreationOpenSet}.
    /// @param open New public-creation gate state.
    function logCreationOpenSet(bool open) external;

    /// @notice Emitter-gated: emits {OwnershipTransferred}.
    /// @param previousOwner Prior protocol owner.
    /// @param newOwner New protocol owner (zero == renounced).
    function logOwnershipTransferred(address previousOwner, address newOwner) external;

    /// @notice Emitter-gated: emits {FeeOwnershipTransferred}.
    /// @param token Launched Diggers token.
    /// @param previousOwner Prior fee owner.
    /// @param newOwner New fee owner (zero == renounced).
    function logFeeOwnershipTransferred(address token, address previousOwner, address newOwner) external;

    /// @notice Emitter-gated: emits {BurnOwnershipTransferred}.
    /// @param token Launched Diggers token.
    /// @param previousOwner Prior burn owner.
    /// @param newOwner New burn owner (zero == renounced).
    function logBurnOwnershipTransferred(address token, address previousOwner, address newOwner) external;

    // -------------------------------------------------------------------- views

    /// @notice Whether a name could be created right now (no live blue chip holds it and
    ///         no post-demotion grace protects it).
    /// @param name Candidate token name.
    /// @return True if the name object is free for creation.
    function isNameFree(string calldata name) external view returns (bool);

    /// @notice Whether a symbol could be created right now (same gate as {isNameFree}).
    /// @param symbol Candidate token symbol.
    /// @return True if the symbol object is free for creation.
    function isSymbolFree(string calldata symbol) external view returns (bool);

    /// @notice Live blue-chip lock counts + post-demotion grace deadlines for a name
    ///         object and a symbol object (same shared set). Creation of the pair
    ///         requires both counts at zero AND `now` past both grace stamps.
    /// @param name Candidate token name.
    /// @param symbol Candidate token symbol.
    /// @return nameLocks Live blue-chip lock count on the name object.
    /// @return symbolLocks Live blue-chip lock count on the symbol object.
    /// @return nameGraceUntil Unix timestamp until which the name stays uncreatable.
    /// @return symbolGraceUntil Unix timestamp until which the symbol stays uncreatable.
    function keyStateOf(string calldata name, string calldata symbol)
        external
        view
        returns (uint32 nameLocks, uint32 symbolLocks, uint64 nameGraceUntil, uint64 symbolGraceUntil);

    /// @notice The two registry objects `token` holds (folded name + folded symbol).
    /// @param token Launched Diggers token.
    /// @return Folded `{nameKey, symbolKey}` pair.
    function tokenKeys(address token) external view returns (IDiggers.TokenKeys memory);

    /// @notice `token`'s graduation timestamp (0 = never).
    /// @param token Launched Diggers token.
    /// @return Graduation unix timestamp, or 0.
    function graduatedAt(address token) external view returns (uint64);

    /// @notice `token`'s blue-chip timestamp (0 = not currently blue chip).
    /// @param token Launched Diggers token.
    /// @return Blue-chip unix timestamp, or 0 when not blue chip.
    function blueChippedAt(address token) external view returns (uint64);

    /// @notice Graduation + blue-chip progress snapshot for UIs.
    /// @param token Launched Diggers token.
    /// @return Progress struct (holders, volume, mcap, liquidity, pass flags, etc.).
    function progressOf(address token) external view returns (IDiggers.Progress memory);

    /// @notice The registered USD oracle stables (empty on NATIVE_USD deployments).
    /// @return assets Registered oracle asset addresses.
    function oracleAssets() external view returns (address[] memory assets);

    /// @notice The blue-chip bars as the next state-changing check would see them (a
    ///         FRESH oracle conversion when at least one pool answers — `oracleLive` —
    ///         else the cached bars, else the plain-ETH fallback). On NATIVE_USD
    ///         deployments simply the constructor bars, both mcap sides equal.
    /// @return volumeBar Volume threshold (wei or 1e18-scaled USD per mode).
    /// @return mcapBarHi High mean-tick mcap threshold (grant side).
    /// @return mcapBarLo Low mean-tick mcap threshold (retention side).
    /// @return oracleLive True when a fresh oracle conversion was used.
    /// @return cacheUpdatedAt Unix timestamp of the last bar-cache write.
    function blueChipBars()
        external
        view
        returns (uint256 volumeBar, uint256 mcapBarHi, uint256 mcapBarLo, bool oracleLive, uint64 cacheUpdatedAt);

    /// @notice Whether `token` was launched by the bound launchpad.
    /// @param token Address to check.
    /// @return True if `token` is a DiggersToken from {DIGGERS}.
    function isDiggersToken(address token) external view returns (bool);

    /// @notice A launched token's pool record (creator, pool, position range, fee config).
    /// @param token Launched Diggers token.
    /// @return On-chain {IDiggers.TokenRecord}.
    function tokenRecord(address token) external view returns (IDiggers.TokenRecord memory);

    /// @notice The launchpad's monotonic CREATE2 salt nonce.
    /// @return Current create nonce.
    function createNonce() external view returns (uint256);

    /// @notice Live pool state for a launched token (reserves in wei/token units).
    /// @param token Launched Diggers token.
    /// @return sqrtPriceX96 Current sqrt price (Q64.96).
    /// @return tick Current tick.
    /// @return liquidity In-range liquidity.
    /// @return ethInPool Quote/WETH reserve in wei.
    /// @return tokenInPool Token reserve in raw units.
    function poolState(address token)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 ethInPool, uint256 tokenInPool);

    /// @notice Uncollected LP fees of the launchpad's position (ETH side in wei).
    /// @param token Launched Diggers token.
    /// @return ethFees Pending ETH fees in wei.
    /// @return tokenFees Pending token fees in raw units.
    function pendingFees(address token) external view returns (uint256 ethFees, uint256 tokenFees);

    /// @notice Active creator fee-split row count for `token`.
    /// @param token Launched Diggers token.
    /// @return Number of active fee-split rows.
    function feeSplitCount(address token) external view returns (uint8);

    /// @notice One creator fee-split row. Reverts `UnknownToken` past the active count.
    /// @param token Launched Diggers token.
    /// @param index Row index in `[0, feeSplitCount)`.
    /// @return Fee-split `{to, share}` row.
    function feeSplitAt(address token, uint256 index) external view returns (IDiggers.FeeSplit memory);

    /// @notice The token's Glue fee shares (all zero until set; forced zero pre-activation).
    /// @param token Launched Diggers token.
    /// @return Packed {IDiggers.GlueShares}.
    function glueSharesOf(address token) external view returns (IDiggers.GlueShares memory);

    /// @notice Exact-input buy quote, bit-exact against the swap it predicts.
    /// @param token Launched Diggers token.
    /// @param ethIn Exact ETH input in wei.
    /// @return amountOut Predicted token output in raw units.
    function quoteBuy(address token, uint256 ethIn) external view returns (uint256 amountOut);

    /// @notice Exact-input sell quote, bit-exact against the swap it predicts.
    /// @param token Launched Diggers token.
    /// @param tokenIn Exact token input in raw units.
    /// @return amountOut Predicted ETH output in wei.
    function quoteSell(address token, uint256 tokenIn) external view returns (uint256 amountOut);

    /// @notice Launch sqrt price of every pool (Q64.96).
    /// @return Fixed launch sqrt price used at pool initialize.
    function START_SQRT_PRICE_X96() external view returns (uint160);
}
