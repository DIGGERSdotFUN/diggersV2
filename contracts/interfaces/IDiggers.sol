// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggers
 * @notice Interface of the Diggers singleton launchpad (Uniswap V3 edition): factory,
 *         swap router, V3 mint/swap-callback host, fee harvester, and name registry.
 *         Self-contained (no implementation imports).
 * @dev V3 edition differences vs the V4 build: the LP fee is FORCED to 1% (no per-launch
 *      choice), each launch gets its own WETH/token V3 pool (WETH pinned as token0 via a
 *      CREATE2 salt grind), graduation is a single supply-sold criterion (pool balance
 *      falls to the sold-fraction threshold), blue chip is a LIVE revocable status
 *      (lifetime volume + mcap + holders; dormant until graduation) that locks the
 *      token's name + symbol while held (the ONLY name gate), vesting locks are ID-based
 *      positions escrowed on the standalone {LOCKER} (approve-free), and there is NO
 *      platform ETH fee slice. This contract is the ENGINE only: every protocol event
 *      and every ecosystem view lives on the {HUB} singleton (see {IDiggersHub}).
 * @author BasedDopamine
 */
interface IDiggers {
    // ------------------------------------------------------------------- types

    /// @notice Identity + per-launch burn config for a new launch. The LP fee is forced to
    ///         1% so it is not part of the params. Charset is enforced by the registry.
    /// @dev Percentages are ALWAYS 1e18-scaled (1e18 == 100%), never bps.
    struct TokenParams {
        string name;
        string symbol;
        string metadataURI;
        // Creator-chosen token-fee burn share, 1e18-scaled, in [0, 1e18]. The airdrop pot
        // share is the remainder (`1e18 - burnShareWad - stakeShareWad`). Editable
        // post-launch by the token's burn owner (see {setTokenomics}).
        uint256 burnShareWad;
        // ETH-side buyback redirect: share of the fresh creator ETH slice pushed to the
        // token's buyback pot at each harvest (1e18-scaled, 0 = off).
        uint256 buybackShareWad;
        // ETH-side Glue NAV-backing carve of the fresh creator slice (1e18-scaled).
        // Requires the owner to have activated Glue (see {setGlueDeposit}), else reverts.
        uint256 backingShareWad;
        // ETH-side Glue staking carve of the fresh creator slice (1e18-scaled). Rule:
        // buyback + backing + staking <= 1e18; the remainder goes to the fee-split rows.
        uint256 stakingShareWad;
        // Token-side Glue staking share (1e18-scaled). Rule: burn + stake <= 1e18; the
        // daily airdrop pot takes the exact remainder (the three always sum to 100%).
        uint256 stakeShareWad;
        // Initial holder of BOTH per-token owner roles (fee-split owner + burn owner). A
        // ZERO address renounces both from birth (config frozen; fees still flow).
        address owner;
    }

    /// @notice Per-token Glue fee shares, packed to one slot (1e18 < 2^64). All zero until
    ///         the creator opts in — and FORCED zero while Glue is not activated.
    struct GlueShares {
        uint64 backingWad; // ETH side: NAV-backing carve of the fresh creator slice
        uint64 stakingWad; // ETH side: staking carve of the fresh creator slice
        uint64 stakeWad; // token side: staking share of collected token fees
    }

    /// @notice One create-time distribution slice of the initial buy. Shares are
    ///         1e18-scaled and MUST sum to exactly 1e18. `tranches == 0` is a plain
    ///         (unlocked) transfer; otherwise the slice becomes a fresh lock position on
    ///         the launchpad with the given vesting schedule for `to`.
    struct LockOrder {
        address to;
        uint256 shareWad;
        uint32 tranches;
        uint64 duration;
    }

    /// @notice One escrowed vesting position, addressed as `(token, wallet, index)` — the
    ///         book is `locks[token][wallet][]`, so a wallet can hold any number of locks,
    ///         each with its own schedule. `tranches` equal slices unlock across `duration`
    ///         from `start` (`tranches == 1` is a cliff at `duration`). Gas-packed: the
    ///         creation write is ONE hot slot (`total|start|duration|tranches` = 28 bytes;
    ///         `withdrawn` starts zero in slot 2). Token/wallet are the mapping keys and
    ///         the funder lives on the `Locked` event — none of the three burn storage.
    struct Lock {
        uint128 total;
        uint40 start;
        uint40 duration;
        uint16 tranches;
        uint128 withdrawn;
    }

    /// @notice A vesting schedule row for {multiLock}. Pass ONE to broadcast the same
    ///         schedule to every recipient, or exactly one per recipient.
    struct LockSchedule {
        uint32 tranches;
        uint64 duration;
    }

    /// @notice On-chain record of a launched token's pool, position bounds, and fee config.
    ///         The single seeded position `[tickLower, tickUpper]` sits entirely below the
    ///         launch spot (WETH is token0), so it is 100% token / 0 WETH.
    struct TokenRecord {
        address creator;
        address pool; // the WETH/token 1% Uniswap V3 pool
        int24 tickLower;
        int24 tickUpper;
        uint24 poolFee; // always 10000 (1%)
        uint128 burnShareWad;
    }

    /// @notice A creator ETH fee-share row (1e18-scaled). Set at create; replaceable by the
    ///         token's fee owner via {setFeeSplits}.
    struct FeeSplit {
        address to;
        uint256 share;
    }

    /// @notice The two registry objects a token holds (folded name + folded symbol).
    struct TokenKeys {
        bytes32 nameKey;
        bytes32 symbolKey;
    }

    /// @notice Graduation + blue-chip progress snapshot for UIs.
    /// @dev `supplySold`/`supplySoldTarget` drive graduation (raw token units bought out
    ///      of the pool vs the sold-fraction target); `avgMcapEth` is the mean-tick
    ///      market cap, used by blue chip only.
    ///      `nameLocks`/`symbolLocks` are the live blue-chip lock counts on the token's
    ///      two registry objects (creation of the same name needs both at zero).
    struct Progress {
        uint32 holders;
        uint256 volumeEth;
        uint256 avgMcapEth;
        uint256 supplySold;
        uint256 supplySoldTarget;
        uint64 graduatedAt;
        uint64 blueChippedAt;
        uint32 nameLocks;
        uint32 symbolLocks;
        bool graduationPass;
        bool blueChipPass;
        bool blueChipVolumePass;
        bool blueChipMcapPass;
        bool blueChipHoldersPass;
    }

    // ----------------------------------------------------------------- events

    /// @dev The V3 edition has NO events of its own: EVERY protocol event prints from the
    ///      DiggersHub singleton (see {IDiggersHub}) through emitter-gated `log*` relays,
    ///      so the indexer and the UX watch exactly one address. Only the tokens'
    ///      canonical ERC-20 `Transfer`/`Approval` stay on the tokens themselves.

    // ----------------------------------------------------------------- errors

    error NameRequired();
    error SymbolRequired();
    error MetadataRequired();
    error FeeSplitInvalid();
    error LockConfigInvalid();
    error LocksWithoutBuy();
    error CreationFeeRequired();
    error CloneFailed();
    error TreasuryRequired();
    error OwnerRequired();
    error NotOwner();
    error NotFeeOwner();
    error NotBurnOwner();
    error TeamShareTooHigh();
    error PoolAlreadyInitialized();
    error SeedIncomplete(uint256 expected, uint256 used);
    error UnknownToken();
    error ZeroEth();
    error NothingToClaim();
    error EthTransferFailed();
    error Reentrancy();
    error NameReserved();
    error SymbolReserved();
    error NotSelf();
    error NotLocker();
    error UnknownLock();
    error NothingToWithdraw();
    error TokenomicsInvalid();
    error GlueNotActive();
    error GlueAlreadySet();
    error AlreadyGraduated();
    error AlreadyBlueChip();
    error NotBlueChip();
    error CriteriaNotMet();
    error NameInGrace();
    error SymbolInGrace();
    error OracleAssetInvalid();
    error OracleAssetsFull();
    error OracleAssetUnknown();
    error NativeUsdMode();
    error UsdBarsInvalid();
    error StartMcapInvalid();
    error StartTickInvalid();
    error FeeConfigInvalid();
    error FactoryUnsupported();
    error DecimalsMismatch();
    error TransientStorageUnavailable();
    error CreationClosed();
    error GradConfigInvalid();
    error NotGraduated();

    /// @dev Slippage() and ZeroSwapAmount() are inherited from DiggerV3Base.

    // ------------------------------------------------------------- immutables

    /// @notice The DiggersHub events + views singleton this launchpad is bound to. The
    ///         launch sqrt price and every other ecosystem view live THERE.
    /// @return The bound hub address.
    function HUB() external view returns (address);

    /// @notice Spacing-aligned launch tick matching the fixed launch start price.
    /// @return The launch tick used for every new pool.
    function START_TICK() external view returns (int24);

    /// @dev WETH() and V3_FACTORY() getters are provided by the DiggerV3Base public
    ///      immutables on the concrete launchpad (not re-declared here to avoid a diamond
    ///      override clash with the state variables).

    /// @notice The shared DiggersToken implementation every launch is cloned from.
    /// @return The EIP-1167 clone implementation address.
    function TOKEN_IMPLEMENTATION() external view returns (address);

    /// @notice Flat creation fee in wei, REQUIRED on every `create` (burned fee buy).
    /// @return Creation fee in wei.
    function CREATION_FEE() external view returns (uint256);

    /// @notice Dual-purpose native floor (wei): buyback wrap-step gas-dust floor AND
    ///         opportunistic harvest quote-side floor (see Diggers.WRAP_MIN_THRESHOLD).
    /// @return Minimum native wei before wrap/sweep into the buyback pot / harvest fire.
    function WRAP_MIN_THRESHOLD() external view returns (uint256);

    // ------------------------------------------------------------- ownership

    /// @notice Protocol config owner (team share, fee recipient, Glue activation, oracle
    ///         assets, creation gate).
    /// @return The current owner; address(0) means ownership renounced (config frozen).
    function owner() external view returns (address);

    /// @notice Wallet that receives the team slice of harvested ETH fees.
    /// @return The team fee-recipient address.
    function feeRecipient() external view returns (address);

    /// @notice Global team share of ETH fees (1e18-scaled).
    /// @return Team share wad (`1e18` == 100%).
    function teamShareWad() external view returns (uint256);

    /// @notice Whether public token creation is open (anyone may call create/createFull).
    /// @return True when the gate is open; false means only {owner} may create.
    function creationOpen() external view returns (bool);

    /// @notice Owner-only: updates the global team share of ETH fees.
    /// @param newTeamShareWad New team share, 1e18-scaled (must stay within protocol caps).
    function setTeamShareWad(uint256 newTeamShareWad) external;

    /// @notice Owner-only: rotates the team ETH fee-recipient wallet.
    /// @param newFeeRecipient Non-zero address that will receive the team slice.
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Owner-only: open or pause public token creation.
    /// @dev Starts closed at deploy. Owner can always create regardless. Renouncing while
    ///      closed reverts ({CreationClosed}) so launches cannot be permanently bricked.
    /// @param open True to allow anyone to create; false to restrict to {owner}.
    function setCreationOpen(bool open) external;

    /// @notice Owner-only: transfers protocol ownership.
    /// @param newOwner Next owner; must be non-zero (use {renounceOwnership} to freeze).
    function transferOwnership(address newOwner) external;

    /// @notice Owner-only: renounces ownership forever (`owner == 0` freezes config).
    /// @dev Reverts {CreationClosed} while creation is still gated.
    function renounceOwnership() external;

    // -------------------------------------------------------------- create

    /// @notice Minimal quick-integration launch (GMGN-style terminals): standard tokenomics
    ///         baked in — 50% burn / 50% daily trader pot, no buyback/glue, both per-token
    ///         ownerships renounced, creator fees 100% to the caller. Any msg.value beyond
    ///         CREATION_FEE runs the plain initial buy delivered to the caller.
    /// @param name Token name (registry charset enforced).
    /// @param symbol Token symbol (registry charset enforced).
    /// @param metadataURI ipfs:// (or equivalent) metadata JSON URI.
    /// @return token Address of the newly launched DiggersToken clone.
    function create(string calldata name, string calldata symbol, string calldata metadataURI)
        external
        payable
        returns (address token);

    /// @notice Full launch path: custom tokenomics, fee-split table, vesting locks and an
    ///         initial-buy minOut.
    /// @param params Identity + tokenomics + initial per-token owner roles.
    /// @param feeSplits Creator ETH fee-split table (shares 1e18-scaled, sum to 1e18).
    /// @param locks Create-time distribution / vesting table against the initial buy
    ///        (empty when there is no buy; non-empty without a buy reverts).
    /// @param initialBuyMinOut Minimum tokens out for the optional initial buy (slippage).
    /// @return token Address of the newly launched DiggersToken clone.
    function createFull(
        TokenParams calldata params,
        FeeSplit[] calldata feeSplits,
        LockOrder[] calldata locks,
        uint256 initialBuyMinOut
    ) external payable returns (address token);

    // -------------------------------------------------------------- router

    /// @notice Exact-input ETH→token buy into `to`. `msg.value` is the ETH input.
    /// @param token Launched Diggers token to buy.
    /// @param minOut Minimum tokens out (slippage floor).
    /// @param to Recipient of the purchased tokens.
    function buy(address token, uint256 minOut, address to) external payable;

    /// @notice Exact-input token→ETH sell. Approve-free when the launchpad pulls from the
    ///         outer caller (allowance skip on DiggersToken.transferFrom).
    /// @param token Launched Diggers token to sell.
    /// @param amountIn Raw token units to sell.
    /// @param minOut Minimum ETH out in wei (slippage floor).
    /// @param to Recipient of the ETH proceeds.
    function sell(address token, uint256 amountIn, uint256 minOut, address to) external;

    /// @notice ETH→token buy whose output is distributed per `locks` (vesting / unlocked
    ///         slices) instead of a single recipient.
    /// @param token Launched Diggers token to buy.
    /// @param minOut Minimum tokens out of the swap (slippage floor).
    /// @param locks Distribution table (shares sum to 1e18) booked on the {LOCKER}.
    function buyAndLock(address token, uint256 minOut, LockOrder[] calldata locks) external payable;

    /// @dev quoteBuy/quoteSell live on the hub (see {IDiggersHub}).

    // -------------------------------------------------------------- locking

    /// @notice The standalone vesting-lock escrow (deployed by this contract's
    ///         constructor, immutable). All lock entrypoints and views live THERE —
    ///         see {IDiggersLocker} — while `Locked`/`Withdrawn` events print from the
    ///         hub via its locker-gated relays.
    /// @return The DiggersLocker address.
    function LOCKER() external view returns (address);

    // ------------------------------------------------------------- fees

    /// @notice Collects LP fees for `token` and splits them IN FULL (team / creators /
    ///         buyback / Glue / burn / pot). No reinvest leg.
    /// @param token Launched Diggers token whose position fees to harvest.
    function harvest(address token) external;

    /// @notice Pull-payment: sends the caller's accrued ETH (`ethOwed`) to msg.sender.
    function claim() external;

    /// @notice Accrued pull-payment ETH balance for `account` (wei).
    /// @param account Address whose parked ETH balance to read.
    /// @return Accrued wei claimable via {claim}.
    function ethOwed(address account) external view returns (uint256);

    /// @notice Uncollected ETH LP fees sitting on the launchpad's position for `token`.
    /// @param token Launched Diggers token.
    /// @return Pending ETH fees in wei (not yet harvested into the split).
    function pendingEth(address token) external view returns (uint256);

    // ---------------------------------------------------- per-token ownership

    /// @notice Per-token owner of the creator ETH fee-split table.
    /// @param token Launched Diggers token.
    /// @return Fee-split owner; address(0) means renounced.
    function feeOwner(address token) external view returns (address);

    /// @notice Per-token owner of burn/tokenomics config ({setTokenomics}).
    /// @param token Launched Diggers token.
    /// @return Burn owner; address(0) means renounced.
    function burnOwner(address token) external view returns (address);

    /// @notice Fee-owner-only: replaces the creator ETH fee-split table atomically.
    /// @param token Launched Diggers token.
    /// @param rows New fee-split rows (shares 1e18-scaled, sum to 1e18).
    function setFeeSplits(address token, FeeSplit[] calldata rows) external;

    /// @notice The token's creator-fee buyback redirect share (1e18-scaled, 0 = off).
    /// @param token Launched Diggers token.
    /// @return Buyback carve of the fresh creator ETH slice.
    function creatorBuybackWad(address token) external view returns (uint256);

    /// @notice Replaces the token's WHOLE tokenomics config atomically (burn-owner-gated).
    ///         ETH side: `buyback + backing + staking <= 1e18` (remainder to the fee-split
    ///         rows). Token side: `burn + stake <= 1e18` (the airdrop pot is the exact
    ///         remainder). Nonzero backing/staking/stake revert {GlueNotActive} while the
    ///         owner has not activated Glue.
    /// @param token Launched Diggers token.
    /// @param buybackShareWad ETH-side buyback redirect (1e18-scaled).
    /// @param backingShareWad ETH-side Glue NAV-backing carve (1e18-scaled).
    /// @param stakingShareWad ETH-side Glue staking carve (1e18-scaled).
    /// @param burnShareWad Token-side burn share of collected token fees (1e18-scaled).
    /// @param stakeShareWad Token-side Glue staking share (1e18-scaled).
    function setTokenomics(
        address token,
        uint256 buybackShareWad,
        uint256 backingShareWad,
        uint256 stakingShareWad,
        uint256 burnShareWad,
        uint256 stakeShareWad
    ) external;

    /// @notice The Glue V2 deposit router (0 until the owner activates the integration).
    /// @return Glue deposit router; address(0) until {setGlueDeposit}.
    function glueDeposit() external view returns (address);

    /// @notice ONE-SHOT owner activation of the Glue integration. Reverts if already set
    ///         or `glue` is zero. Never rotated, never unset.
    /// @param glue Glue V2 deposit router address.
    function setGlueDeposit(address glue) external;

    /// @notice Buyback execution body. ONLY callable by the launchpad itself (the buy paths
    ///         invoke it as a try/caught self-call so it can never revert a user trade).
    /// @param token Launched Diggers token whose pot to spend.
    /// @param userAmountOut Token output of the carrying user buy (buyback cap).
    function execBuyback(address token, uint256 userAmountOut) external;

    /// @notice Fee-owner-only: transfers fee-split ownership for `token`.
    /// @param token Launched Diggers token.
    /// @param newOwner Next fee owner (non-zero; use {renounceFeeOwnership} to freeze).
    function transferFeeOwnership(address token, address newOwner) external;

    /// @notice Fee-owner-only: renounces fee-split ownership forever for `token`.
    /// @param token Launched Diggers token.
    function renounceFeeOwnership(address token) external;

    /// @notice Burn-owner-only: transfers burn/tokenomics ownership for `token`.
    /// @param token Launched Diggers token.
    /// @param newOwner Next burn owner (non-zero; use {renounceBurnOwnership} to freeze).
    function transferBurnOwnership(address token, address newOwner) external;

    /// @notice Burn-owner-only: renounces burn/tokenomics ownership forever for `token`.
    /// @param token Launched Diggers token.
    function renounceBurnOwnership(address token) external;

    // -------------------------------------------------------------- registry

    /// @dev The registry views (isNameFree, isSymbolFree, keyStateOf, tokenKeys,
    ///      graduatedAt, blueChippedAt) live on the hub (see {IDiggersHub}).

    // ------------------------------------------------------------ graduation

    /// @notice Blue-chip holder-count threshold (live leg; the volume/mcap thresholds are
    ///         public immutables on the concrete launchpad).
    /// @return Minimum unique holders required for blue chip.
    function BLUECHIP_HOLDERS() external view returns (uint32);

    /// @notice Whether this deployment's quote is USD-denominated (Stable/USDT0). True
    ///         means the volume/mcap bars ARE dollars and the oracle machinery is inert;
    ///         false means USD-1e18 bars convert to wei through the TWAP oracles.
    /// @return True when quote asset is native USD (oracle unused).
    function NATIVE_USD() external view returns (bool);

    /// @notice Registers a USD oracle stable (owner-only, ETH-quote chains only — reverts
    ///         {NativeUsdMode} otherwise). Its WETH pools across the four canonical fee
    ///         tiers are auto-discovered at read time; the deepest one anchors the price.
    /// @param asset ERC-20 stablecoin used as a TWAP USD oracle asset.
    function addOracleAsset(address asset) external;

    /// @notice Removes a USD oracle stable (owner-only). With none left, the bar cache
    ///         keeps serving its last values (or the plain-ETH fallback if never filled).
    /// @param asset Previously registered oracle asset to remove.
    function removeOracleAsset(address asset) external;

    /// @dev oracleAssets()/blueChipBars() live on the hub (see {IDiggersHub}).

    /// @notice Permissionless: graduates `token` once enough of the supply was bought out
    ///         of its pool (`balanceOf(pool)` fell to the sold-fraction threshold).
    ///         Drops the anti-whale shield forever.
    /// @param token Launched Diggers token to graduate.
    function graduate(address token) external;

    /// @notice Permissionless: grants LIVE blue-chip status when volume, mean-tick mcap,
    ///         and holders all clear their thresholds. Locks the token's name + symbol.
    ///         Dormant pre-graduation: reverts {NotGraduated} until the token graduates.
    /// @param token Launched Diggers token to blue-chip.
    function blueChip(address token) external;

    /// @notice Permissionless demotion: strips a blue-chip token whose LIVE legs (mean-tick
    ///         mcap or holders) no longer pass, unlocking its name + symbol objects.
    ///         Reverts {NotBlueChip} when not blue chip, {CriteriaNotMet} while healthy.
    /// @param token Blue-chip Diggers token to demote.
    function blueChipLost(address token) external;

    /// @dev progressOf lives on the hub (see {IDiggersHub}).

    // ------------------------------------------------------------------ views

    /// @notice Whether `token` was launched by this Diggers instance.
    /// @param token Address to check.
    /// @return True if `token` is a DiggersToken clone from this launchpad.
    function isDiggersToken(address token) external view returns (bool);

    /// @dev tokenRecord/createNonce/poolState/pendingFees and every other ecosystem view
    ///      live on the hub (see {IDiggersHub}), served through the raw-slot window below.

    /// @notice Reads one raw storage slot of this contract (the hub's view window —
    ///         Uniswap V4's extsload pattern). Read-only by construction: exposes
    ///         nothing a public archive node would not.
    /// @param slot Storage slot to read.
    /// @return value Raw 32-byte contents of `slot`.
    function extsload(bytes32 slot) external view returns (bytes32 value);

    /// @notice Batch twin of {extsload}.
    /// @param slots Storage slots to read.
    /// @return values Raw 32-byte contents, one per input slot.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values);
}
