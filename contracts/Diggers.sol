// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title Diggers
 * @notice Singleton launchpad (Uniswap V3 edition): deploys DiggersToken clones, creates +
 *         owns every WETH/token 1% V3 pool and its single permanent position, and hosts the
 *         swap router, fee harvester, name registry, and graduation/blue-chip machinery.
 *         The LP fee is FORCED to 1%. Economics (graduation sold-fraction, blue-chip
 *         thresholds, creation fee, start tick) are chain-parameterized at deploy so the
 *         same code runs on Stable (USDT0-denominated) and Robinhood (ETH-denominated).
 *         Graduation is pump.fun-style supply-sold: it fires when the pool's token
 *         balance falls to GRAD_POOL_BALANCE — i.e. GRAD_SOLD_WAD of the fixed supply
 *         was bought out of the pool (price-path independent; foreign LP can only make
 *         the bar harder) — dropping the token's anti-whale shield forever. Harvested
 *         fees are ALWAYS split in full (no reinvest leg). Blue chip is a LIVE revocable
 *         status (lifetime volume + mean-tick mcap + holders, re-checked both ways on
 *         every post-graduation trade; dormant before graduation) that locks the token's
 *         name + symbol in the registry
 *         while held — the ONLY name gate (no launch lock, no paid reservations).
 *         Every token address doubles as a buyback pot (open donations + an optional
 *         creator-fee redirect); after each user BUY the pot buys the token back and burns
 *         it, sized so the buyback output never exceeds the user's own (anti-sandwich).
 * @dev Diggers V2 architecture: this contract is the ENGINE only — factory + V3 callback
 *      host + swap router + fee splitter + registry + graduation/blue-chip state.
 *      DiggersHub offloads EVERY protocol event and EVERY ecosystem view (bound one-shot
 *      at construction; locker + each clone registered as emitters). DiggersToken is an
 *      EIP-1167 clone of {TOKEN_IMPLEMENTATION}. DiggersLocker is the standalone vesting
 *      escrow ({LOCKER}); create-time / buyAndLock tables call `lockFor` there. No
 *      upgradeable proxies, no pause, no owner power over balances/supply/liquidity —
 *      owner governs config only (team share, fee recipient, Glue activation, oracles).
 * @author BasedDopamine
 */
import {DiggerV3, DiggerV3Base, IWETH9, IUniswapV3Factory} from "./libs/DiggerV3.sol";
import {DiggerSwapViews} from "./libs/DiggerSwapViews.sol";
import {DiggerHarvestViews} from "./libs/DiggerHarvestViews.sol";
import {DiggerHarvestLib} from "./libs/DiggerHarvestLib.sol";
import {DiggerCreateLib} from "./libs/DiggerCreateLib.sol";
import {DiggerRegistryLib} from "./libs/DiggerRegistryLib.sol";
import {DiggerGraduationLib} from "./libs/DiggerGraduationLib.sol";
import {DiggerGraduationMath} from "./libs/DiggerGraduationMath.sol";
import {DiggerTwapOracle} from "./libs/DiggerTwapOracle.sol";
import {DiggerBuybackLib} from "./libs/DiggerBuybackLib.sol";
import {DiggersToken} from "./DiggersToken.sol";
import {DiggersLocker} from "./DiggersLocker.sol";
import {IDiggers} from "./interfaces/IDiggers.sol";
import {IDiggersHub} from "./interfaces/IDiggersHub.sol";
import {IDiggersLocker} from "./interfaces/IDiggersLocker.sol";

/**
 * @title IQuoteDecimals
 * @notice Minimal ERC-20 metadata read used once in the Diggers constructor.
 * @dev Catches a quote-decimals fat-finger against the deployer-supplied value; a token
 *      that reverts or reports 0 is treated as unverifiable and defers to the passed value.
 * @author BasedDopamine
 */
interface IQuoteDecimals {
    /// @notice ERC-20 decimals of the quote token.
    /// @return Decimals reported by the token (0 treated as unverifiable).
    function decimals() external view returns (uint8);
}

contract Diggers is DiggerV3Base, IDiggers {
    // -------------------------------------------------- constants / immutables

    /// @dev 1e18 == 100%. Percentages are ALWAYS 1e18-scaled, never bps.
    uint256 private constant WAD = 1e18;

    /// @dev EIP-1153 transient slot for approve-free sell settlement.
    bytes32 private constant SELL_PAYER_SLOT = keccak256("diggers.router.sellPayer");

    /// @dev EIP-1153 transient reentrancy latch for the ETH-sending paths.
    bytes32 private constant REENTRANCY_SLOT = keccak256("diggers.reentrancy.lock");

    /// @dev Opportunistic harvest token-side floor (1 whole DiggersToken). Quote-side
    ///      floor is {WRAP_MIN_THRESHOLD} (chain-parameterized) — never a hardcoded
    ///      native constant, which collapses in dollar value on NATIVE_USD chains.
    uint256 private constant HARVEST_THRESHOLD_TOKEN = 1e18;

    /// @dev Default team share of ETH fees at deploy: 30% (owner-editable afterwards).
    uint256 private constant DEFAULT_TEAM_SHARE_WAD = 3e17;

    /// @dev USD-bar ceiling (1e18-scaled dollars, i.e. 1e15 whole dollars): keeps the
    ///      bar-conversion md512 unconditionally overflow-free even at extreme-tick
    ///      oracle prices, so the hot-path refresh can never revert a trade.
    uint256 private constant MAX_USD_BAR = 1e33;

    /// @dev NATIVE_USD launch-mcap anchor: on a dollar-quote chain the start tick must
    ///      imply a $2.6K–$3K launch market cap (several spacing-200 ticks qualify,
    ///      e.g. 404_200 on a 6-dec quote, 128_000 on an 18-dec one). Ctor-only.
    uint256 private constant MIN_USD_START_MCAP = 2_600e18;
    uint256 private constant MAX_USD_START_MCAP = 3_000e18;

    /// @notice Flat creation fee, REQUIRED on every `create` (wei). Runs a real burned pool
    ///         buy so every pool's first swap lands in its creation block.
    uint256 public immutable CREATION_FEE;

    /// @notice Spacing-aligned launch tick (off-chain derived from the start price).
    int24 public immutable START_TICK;

    /// @notice The shared DiggersToken implementation (EIP-1167 clone target).
    address public immutable TOKEN_IMPLEMENTATION;

    /// @notice The standalone vesting-lock escrow (see {IDiggersLocker}). Lock entrypoints
    ///         and views live there; `Locked`/`Withdrawn` events print from the {HUB}.
    address public immutable LOCKER;

    /// @notice The DiggersHub events + views singleton this launchpad bound to itself at
    ///         construction (one-shot `bind`). EVERY protocol event prints there and
    ///         every ecosystem view is served there — this contract is the engine only.
    address public immutable HUB;

    /// @notice Graduation sold-fraction (1e18-scaled): the share of the fixed 1e9 supply
    ///         that must be bought OUT of the pool for a token to graduate. Production
    ///         8e17 (80% — pump.fun parity; a ~25x price multiple on the launch curve).
    uint256 public immutable GRAD_SOLD_WAD;

    /// @notice Graduation pool-balance threshold (raw token units), derived at deploy:
    ///         TOTAL_SUPPLY x (1 - {GRAD_SOLD_WAD}). A token graduates when
    ///         `token.balanceOf(pool) <= GRAD_POOL_BALANCE`. Price plays no role; foreign
    ///         LP positions only ADD tokens to the pool — harder, never easier.
    uint256 public immutable GRAD_POOL_BALANCE;

    /// @notice Blue-chip cumulative-volume threshold. On NATIVE_USD deployments this IS
    ///         the bar (USD-1e18 through the USDT0 quote); on ETH-quote chains it is the
    ///         plain-ETH (wei) fallback served until the oracle cache first fills.
    uint256 public immutable BLUECHIP_VOLUME;

    /// @notice Blue-chip mean-tick market-cap threshold. Same NATIVE_USD/fallback
    ///         semantics as {BLUECHIP_VOLUME}. LIVE leg.
    uint256 public immutable BLUECHIP_MCAP;

    /// @notice Blue-chip holder-count threshold (production 500). LIVE leg — never
    ///         currency-denominated, identical in both deploy modes.
    uint32 public immutable BLUECHIP_HOLDERS;

    /// @notice Whether the quote itself is USD (Stable/USDT0): bars used as-is, the
    ///         oracle machinery inert forever. False on ETH-quote chains (Robinhood).
    bool public immutable NATIVE_USD;

    /// @notice Blue-chip volume bar in USD (1e18-scaled dollars); converted to wei
    ///         through the TWAP oracles. Zero (unused) on NATIVE_USD deployments.
    uint256 public immutable BLUECHIP_VOLUME_USD;

    /// @notice Blue-chip mcap bar in USD (1e18-scaled dollars); converted to wei through
    ///         the TWAP oracles. Zero (unused) on NATIVE_USD deployments.
    uint256 public immutable BLUECHIP_MCAP_USD;

    /// @notice Dual-purpose native floor (wei), set per chain at deploy:
    ///         (1) buyback wrap-step gas-dust floor — parked native donations on a token
    ///         are folded into its WETH pot only once they reach this many wei; NOT a
    ///         buyback trigger (sizing is capped by the carrying buy);
    ///         (2) opportunistic harvest quote-side floor — pending LP fees must clear
    ///         this (converted to quote units via {QUOTE_SCALE}) before a trade-path
    ///         harvest fires, batching gas instead of splitting dust every trade.
    ///         Production: 0.001 ETH on ETH-quote chains, $1 on Stable.
    uint256 public immutable WRAP_MIN_THRESHOLD;

    // ---------------------------------------------------------------- storage

    /// @notice Protocol owner (config only).
    address public owner;

    /// @notice Team treasury — receives its ETH fee share via push/pull.
    address public feeRecipient;

    /// @notice Team share of collected ETH fees (1e18-scaled). Creator side is the remainder.
    uint256 public teamShareWad;

    /// @dev Monotonic CREATE2 salt nonce.
    uint256 private _createNonce;

    /// @dev Whether an address is a token launched here.
    mapping(address => bool) public isDiggersToken;

    /// @dev Per-token pool metadata.
    mapping(address => TokenRecord) private _tokenRecords;

    /// @dev Pull-payment ETH credits (wei).
    mapping(address => uint256) public ethOwed;

    /// @dev Creator fee-split row count per token.
    mapping(address => uint8) private _feeSplitCount;

    /// @dev Creator fee-split table per token.
    mapping(address => mapping(uint256 => FeeSplit)) private _feeSplits;

    /// @notice Per-token fee-split owner (0 once renounced).
    mapping(address => address) public feeOwner;

    /// @notice Per-token burn-share owner (0 once renounced).
    mapping(address => address) public burnOwner;

    /// @notice Per-token creator-fee buyback redirect (1e18-scaled share of the fresh
    ///         creator ETH side pushed to the token's pot at each harvest; 0 = off).
    mapping(address => uint256) public creatorBuybackWad;

    /// @notice The Glue V2 deposit router. ZERO until the owner activates the integration
    ///         (ONE-SHOT — never rotated, never unset); while zero, every glue fee share
    ///         is forced to 0 (nonzero values revert creates and edits).
    address public glueDeposit;

    /// @dev Per-token Glue fee shares (backing/staking off the creator ETH side + the
    ///      token-side stake), packed to one slot.
    mapping(address => GlueShares) private _glueShares;

    /// @notice Creator ETH fee slices that failed delivery, parked per token (wei).
    mapping(address => uint256) public pendingEth;

    /// @dev The shared name-object registry: per-key LIVE blue-chip lock counts (folded
    ///      names and folded symbols share one set). Nonzero = the name is taken.
    mapping(bytes32 => uint32) private _nameLocks;

    /// @dev Per-key post-demotion creation-grace deadline (seconds). Stamped when a key's
    ///      LAST blue-chip lock drops; creation additionally requires `now` past it.
    mapping(bytes32 => uint64) private _keyGraceUntil;

    /// @dev Registered USD oracle stables (ETH-quote chains only; bounded, owner-managed).
    DiggerTwapOracle.OracleAsset[] private _oracleAssets;

    /// @dev The converted blue-chip bar cache (wei), lazily refreshed once per TTL.
    DiggerTwapOracle.BarCache private _barCache;

    /// @dev Per-token graduation timestamp (0 = never).
    mapping(address => uint64) private _graduatedAt;

    /// @dev Per-token blue-chip timestamp (0 = never).
    mapping(address => uint64) private _blueChippedAt;

    /// @dev The two registry objects each token holds.
    mapping(address => TokenKeys) private _tokenKeys;

    /// @notice Whether anyone (not just the protocol {owner}) may call {create}/{createFull}.
    /// @dev Starts `false` at deploy — only the owner can launch until {setCreationOpen}(true).
    ///      Owner can pause creation back to closed later. APPENDED at the end of the
    ///      storage layout so Hub extsload slot pins stay unchanged for slots 0..22.
    bool public creationOpen;

    // ------------------------------------------------------------ constructor

    /**
     * @notice Deploys the Diggers engine: binds {HUB}, deploys {LOCKER} + {TOKEN_IMPLEMENTATION},
     *         wires chain economics, and permanently reserves the "Diggers"/"DIG" brand keys.
     * @dev Hardens EIP-1153, the 1% fee tier, quote decimals, start tick, and USD/ETH bar
     *      mode before any launch can occur. Order: hub bind → USD wiring → locker →
     *      token impl → register locker → brand reserve.
     * @param v3Factory Canonical Uniswap V3 factory (immutable).
     * @param weth The quote token — token0 of every pool. WETH9 on Robinhood; the
     *        dual-native USDT0 ERC-20 on Stable.
     * @param quoteDecimals The quote token's ERC-20 decimals, set per chain at deploy
     *        (18 on Robinhood, 6 on Stable). Drives QUOTE_SCALE = 10^(18−decimals): pool
     *        amounts are quote units, everything else stays 18-dec wei on every chain.
     * @param dualNative True when the quote ERC-20 shares ONE balance with native gas
     *        (Stable's USDT0): no wrap/unwrap anywhere. Sub-18 decimals require this.
     * @param feeRecipient_ Initial team ETH fee recipient.
     * @param startTick Spacing-aligned launch tick.
     * @param owner_ Initial protocol owner.
     * @param gradSoldWad Graduation sold-fraction (1e18-scaled share of supply that must
     *        be bought out of the pool; production 8e17 = 80%). Must be in (0, 1e18).
     * @param bcVolume Blue-chip lifetime-volume threshold — THE bar on NATIVE_USD chains
     *        (USD through the USDT0 quote), the plain-ETH fallback (wei) otherwise.
     * @param bcMcap Blue-chip market-cap threshold; same mode semantics (live leg).
     * @param bcHolders Blue-chip holder-count threshold (live leg; production 500).
     * @param creationFee Flat creation fee (wei).
     * @param wrapMinThreshold Buyback wrap-step gas-dust floor (see {WRAP_MIN_THRESHOLD}).
     * @param nativeUsd True when the quote IS a dollar (Stable/USDT0): bars used as-is,
     *        USD params + oracle assets must be empty. False on ETH-quote chains.
     * @param bcVolumeUsd Blue-chip volume bar in USD 1e18 (ETH-quote chains only).
     * @param bcMcapUsd Blue-chip mcap bar in USD 1e18 (ETH-quote chains only).
     * @param oracleAssets_ Initial USD oracle stables (USDC/USDT; ETH-quote chains only,
     *        owner-extendable later, max 4 total).
     * @param hub The pre-deployed, still-unbound DiggersHub (deployed separately — its
     *        code cannot ride inside this initcode, EIP-3860). Bound here one-shot.
     */
    constructor(
        address v3Factory,
        address weth,
        uint8 quoteDecimals,
        bool dualNative,
        address feeRecipient_,
        int24 startTick,
        address owner_,
        uint256 gradSoldWad,
        uint256 bcVolume,
        uint256 bcMcap,
        uint32 bcHolders,
        uint256 creationFee,
        uint256 wrapMinThreshold,
        bool nativeUsd,
        uint256 bcVolumeUsd,
        uint256 bcMcapUsd,
        address[] memory oracleAssets_,
        address hub
    ) DiggerV3Base(v3Factory, weth, quoteDecimals, dualNative) {
        if (feeRecipient_ == address(0)) revert TreasuryRequired();
        if (owner_ == address(0)) revert OwnerRequired();

        // ---- chain-config hardening (all ctor-only; zero runtime bytes) ----
        // (Base DiggerV3Base already vetted: factory/weth nonzero, decimals<=18,
        //  sub-18 decimals require dual-native. These layer on top.)

        // EIP-1153 is load-bearing (every swap + the reentrancy latch use transient
        // storage). Prove it round-trips NOW so a pre-Cancun chain fails at deploy,
        // not at the first trade.
        {
            bytes32 probe = keccak256("diggers.ctor.tstoreProbe");
            uint256 roundTrip;
            assembly {
                tstore(probe, 0xd16)
                roundTrip := tload(probe)
                tstore(probe, 0)
            }
            if (roundTrip != 0xd16) revert TransientStorageUnavailable();
        }

        // The factory must expose the forced 1% tier at the canonical spacing 200 —
        // every pool is created there. A non-canonical fork / wrong address fails here
        // instead of silently at the first createPool.
        if (IUniswapV3Factory(v3Factory).feeAmountTickSpacing(POOL_FEE) != 200) revert FactoryUnsupported();

        // Quote-decimals fat-finger: QUOTE_SCALE is derived from the deployer-supplied
        // `quoteDecimals`, so cross-check it against what the token reports. We reject
        // only a DEFINITIVE nonzero disagreement (token clearly says 6, deployer passed
        // 18 — or the reverse); a token that reverts or reports 0 (no `decimals()`, or an
        // uninitialized proxy) is unverifiable and defers to the passed value. All real
        // quote tokens report their true nonzero decimals, so the realistic fat-finger is
        // still caught.
        try IQuoteDecimals(weth).decimals() returns (uint8 reported) {
            if (reported != 0 && reported != quoteDecimals) revert DecimalsMismatch();
        } catch {}

        // startTick must be spacing-200 aligned and inside the usable seed range: the
        // seed spans [fullRangeTicks(200).lower = -887200, startTick], so a misaligned
        // or out-of-range tick either bricks initialize or strands the single-sided seed.
        if (startTick % 200 != 0 || startTick <= -887200 || startTick > 887200) revert StartTickInvalid();

        // A sub-unit creation fee floors to zero pool units in _swapV3
        // (creationFee / QUOTE_SCALE == 0 -> ZeroSwapAmount), bricking EVERY create; a
        // sub-unit wrap floor makes a triggered buyback spend zero. Both must clear one
        // whole quote unit.
        if (creationFee < QUOTE_SCALE || wrapMinThreshold < QUOTE_SCALE) revert FeeConfigInvalid();

        // The sold-fraction must be a real fraction: 0 would graduate every token at
        // birth (pool balance == supply == threshold), 1e18+ could never be reached
        // (a pool balance of 0 needs the impossible full-supply buyout).
        if (gradSoldWad == 0 || gradSoldWad >= 1e18) revert GradConfigInvalid();

        feeRecipient = feeRecipient_;
        START_TICK = startTick;
        owner = owner_;
        teamShareWad = DEFAULT_TEAM_SHARE_WAD;
        GRAD_SOLD_WAD = gradSoldWad;
        GRAD_POOL_BALANCE = DiggerGraduationMath.TOTAL_SUPPLY
            - (DiggerGraduationMath.TOTAL_SUPPLY / 1e18) * gradSoldWad;
        BLUECHIP_VOLUME = bcVolume;
        BLUECHIP_MCAP = bcMcap;
        BLUECHIP_HOLDERS = bcHolders;
        CREATION_FEE = creationFee;
        WRAP_MIN_THRESHOLD = wrapMinThreshold;

        // Bind the event/view hub to THIS launchpad before anything can log (the oracle
        // registrations below already print there). Reverts if the hub is bound already.
        HUB = hub;
        IDiggersHub(hub).bind();

        // USD mode wiring. NATIVE_USD deployments must not carry any oracle surface;
        // ETH-quote deployments must carry BOTH USD bars (a zero bar would auto-pass
        // everything), bounded so the conversion math can never overflow-revert.
        NATIVE_USD = nativeUsd;
        BLUECHIP_VOLUME_USD = bcVolumeUsd;
        BLUECHIP_MCAP_USD = bcMcapUsd;
        if (nativeUsd) {
            if (bcVolumeUsd != 0 || bcMcapUsd != 0 || oracleAssets_.length != 0) revert UsdBarsInvalid();
            // Dollar-quote chains anchor the launch mcap: the start tick must imply a
            // $2.6K–$3K starting market cap (checked AFTER the bar guard so config
            // mismatch keeps its own error). ETH-quote chains have no trustable USD
            // anchor at construction time — their launch mcap stays a plain deploy choice.
            uint256 startMcap = DiggerGraduationMath.mcapAtTick(startTick, QUOTE_SCALE);
            if (startMcap < MIN_USD_START_MCAP || startMcap > MAX_USD_START_MCAP) revert StartMcapInvalid();
        } else {
            if (bcVolumeUsd == 0 || bcMcapUsd == 0 || bcVolumeUsd > MAX_USD_BAR || bcMcapUsd > MAX_USD_BAR) {
                revert UsdBarsInvalid();
            }
            for (uint256 i; i < oracleAssets_.length; ++i) {
                DiggerTwapOracle.register(_oracleAssets, false, weth, oracleAssets_[i], hub);
            }
        }

        // Order matters: the locker first, so the token implementation can pin it as an
        // immutable (cap exemption + approve-free carve + telemetry skip).
        LOCKER = address(new DiggersLocker(hub));
        TOKEN_IMPLEMENTATION = address(new DiggersToken(QUOTE_SCALE, LOCKER, hub));
        IDiggersHub(hub).register(LOCKER);

        // Platform brand guard: permanently block "Diggers" / "DIG".
        DiggerRegistryLib.reserveForever(_nameLocks, "Diggers", "DIG");
    }

    // ------------------------------------------------------------ ownership

    /// @notice Restricts config entrypoints to the protocol {owner}.
    /// @dev Reverts {NotOwner}. After {renounceOwnership}, all onlyOwner paths are frozen.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Restricts fee-split edits to the per-token {feeOwner}.
    /// @dev Reverts {NotFeeOwner}. Renounced tokens (`feeOwner == 0`) cannot edit.
    /// @param token Launched DiggersToken whose fee owner is checked.
    modifier onlyFeeOwner(address token) {
        if (msg.sender != feeOwner[token]) revert NotFeeOwner();
        _;
    }

    /// @notice Restricts tokenomics edits to the per-token {burnOwner}.
    /// @dev Reverts {NotBurnOwner}. Renounced tokens (`burnOwner == 0`) cannot edit.
    /// @param token Launched DiggersToken whose burn owner is checked.
    modifier onlyBurnOwner(address token) {
        if (msg.sender != burnOwner[token]) revert NotBurnOwner();
        _;
    }

    /// @notice Transient (EIP-1153) reentrancy latch for ETH-sending paths ({claim}, {_harvest}).
    /// @dev Reverts {Reentrancy} via custom-error selector `0xab143c06`.
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

    /// @inheritdoc IDiggers
    /// @dev Relays {TeamShareUpdated} through DiggersHub.
    function setTeamShareWad(uint256 newTeamShareWad) external onlyOwner {
        if (newTeamShareWad > WAD) revert TeamShareTooHigh();
        teamShareWad = newTeamShareWad;
        IDiggersHub(HUB).logTeamShareUpdated(newTeamShareWad);
    }

    /// @inheritdoc IDiggers
    /// @dev Relays {FeeRecipientUpdated} through DiggersHub.
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert TreasuryRequired();
        feeRecipient = newFeeRecipient;
        IDiggersHub(HUB).logFeeRecipientUpdated(newFeeRecipient);
    }

    /// @inheritdoc IDiggers
    /// @dev ONE-SHOT: must be a deployed contract (EOA would brick harvest-time Glue calls).
    ///      Relays {GlueActivated} through DiggersHub.
    function setGlueDeposit(address glue) external onlyOwner {
        if (glueDeposit != address(0)) revert GlueAlreadySet();
        // Must be a DEPLOYED contract (covers address(0) too): the harvest-time try/catch
        // cannot catch the caller-side no-code check, so an EOA here would brick harvests.
        if (glue.code.length == 0) revert GlueNotActive();
        glueDeposit = glue;
        IDiggersHub(HUB).logGlueActivated(glue);
    }

    /// @inheritdoc IDiggers
    /// @dev Relays {OwnershipTransferred} through DiggersHub.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnerRequired();
        address prev = owner;
        owner = newOwner;
        IDiggersHub(HUB).logOwnershipTransferred(prev, newOwner);
    }

    /// @inheritdoc IDiggers
    /// @dev Sets owner to zero forever; relays {OwnershipTransferred} through DiggersHub.
    ///      Reverts {CreationClosed} while creation is still gated — renouncing then would
    ///      permanently brick every launch (only the owner can create while closed).
    function renounceOwnership() external onlyOwner {
        if (!creationOpen) revert CreationClosed();
        address prev = owner;
        owner = address(0);
        IDiggersHub(HUB).logOwnershipTransferred(prev, address(0));
    }

    /// @inheritdoc IDiggers
    /// @dev Owner-only open/pause for public token creation. Relays {CreationOpenSet}.
    function setCreationOpen(bool open) external onlyOwner {
        creationOpen = open;
        IDiggersHub(HUB).logCreationOpenSet(open);
    }

    // ------------------------------------------------------------- receive

    /// @notice Accepts native value from WETH unwraps (fee/sell paths) and buyback sweeps.
    /// @dev No accounting here — value is spent in the same outer call that deposited it,
    ///      or parked briefly for the buyback / claim paths.
    receive() external payable {}

    // -------------------------------------------------------------- create

    /// @inheritdoc IDiggers
    /// @dev Standard launch: lib bakes in 50% burn / 50% daily trader pot / 0% staking,
    ///      no buyback, no glue. Both per-token ownerships stay renounced from birth; empty
    ///      fee-split defaults to {caller, 100% of the creator side}; excess msg.value runs
    ///      the plain initial buy to the caller (minOut 0 is safe — pool created+seeded in
    ///      this same tx). Hub events are emitted inside DiggerCreateLib / {_finishCreate}.
    function create(string calldata name, string calldata symbol, string calldata metadataURI)
        external
        payable
        returns (address token)
    {
        _requireCreationOpen();
        // The standard launch: the lib bakes in 50% burn / 50% daily trader pot /
        // 0% staking, no buyback, no glue. Both per-token ownerships stay renounced from
        // birth, the empty fee-split table defaults to {caller, 100% of the creator side},
        // and excess msg.value runs the plain initial buy to the caller (minOut 0 is safe
        // — the pool is created AND seeded in this same tx, so the price is deterministic).
        (bytes32 nameKey, bytes32 symbolKey) = DiggerRegistryLib.precheck(_nameLocks, _keyGraceUntil, name, symbol);
        token = DiggerCreateLib.createStandard(
            isDiggersToken,
            _tokenRecords,
            _feeSplitCount,
            _feeSplits,
            creatorBuybackWad,
            _glueShares,
            V3_FACTORY,
            WETH,
            START_TICK,
            _bumpNonce(),
            name,
            symbol,
            metadataURI,
            TOKEN_IMPLEMENTATION,
            HUB
        );
        _finishCreate(token, nameKey, symbolKey, address(0), new LockOrder[](0), 0);
    }

    /// @inheritdoc IDiggers
    /// @dev Full path: custom tokenomics + fee-split + optional vesting table against the
    ///      initial buy. Registry precheck then DiggerCreateLib.create + {_finishCreate}.
    function createFull(
        TokenParams calldata params,
        FeeSplit[] calldata feeSplits,
        LockOrder[] calldata locks,
        uint256 initialBuyMinOut
    ) external payable returns (address token) {
        _requireCreationOpen();
        (bytes32 nameKey, bytes32 symbolKey) =
            DiggerRegistryLib.precheck(_nameLocks, _keyGraceUntil, params.name, params.symbol);
        token = DiggerCreateLib.create(
            isDiggersToken,
            _tokenRecords,
            _feeSplitCount,
            _feeSplits,
            creatorBuybackWad,
            _glueShares,
            V3_FACTORY,
            WETH,
            START_TICK,
            _bumpNonce(),
            glueDeposit != address(0),
            params,
            feeSplits,
            TOKEN_IMPLEMENTATION,
            HUB
        );
        _finishCreate(token, nameKey, symbolKey, params.owner, locks, initialBuyMinOut);
    }

    /// @notice Post-increments the CREATE2 salt nonce.
    /// @return nonce Salt nonce used for this create (pre-increment value).
    function _bumpNonce() private returns (uint256 nonce) {
        nonce = _createNonce;
        unchecked {
            ++_createNonce;
        }
    }

    /// @notice Shared launch tail: registry keys, per-token ownerships, the mandatory
    ///         creation-fee buy (burned), and the optional initial buy.
    /// @dev Creation itself locks NOTHING in the name registry — only a live blue-chip
    ///      promotion arms name locks. Creation-fee buy is a real pool leg to this
    ///      contract (cap/points-exempt) whose output is burned.
    /// @param token Fresh DiggersToken clone.
    /// @param nameKey Folded name registry key (from precheck).
    /// @param symbolKey Folded symbol registry key (from precheck).
    /// @param tokenOwner Initial fee+burn owner (`address(0)` = renounced from birth).
    /// @param locks Optional create-time distribution table (requires buy value).
    /// @param initialBuyMinOut Slippage floor for the optional initial buy.
    function _finishCreate(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        address tokenOwner,
        LockOrder[] memory locks,
        uint256 initialBuyMinOut
    ) private {
        // Record the token's two registry objects. Creation itself locks NOTHING — only a
        // live blue-chip promotion arms the name locks.
        _tokenKeys[token] = TokenKeys({nameKey: nameKey, symbolKey: symbolKey});

        if (tokenOwner != address(0)) {
            feeOwner[token] = tokenOwner;
            burnOwner[token] = tokenOwner;
            IDiggersHub(HUB).logFeeOwnershipTransferred(token, address(0), tokenOwner);
            IDiggersHub(HUB).logBurnOwnershipTransferred(token, address(0), tokenOwner);
        }

        // Mandatory creation-fee buy: a REAL pool leg bought to the launchpad
        // (cap/points-exempt) whose output is burned, so every pool's first swap lands in
        // its creation block.
        if (msg.value < CREATION_FEE) revert CreationFeeRequired();
        address pool = _tokenRecords[token].pool;
        DiggerV3.SwapOutcome memory feeOut = _swapV3(pool, token, true, CREATION_FEE, address(this), 0);
        _emitSwapped(token, msg.sender, true, feeOut.amountIn, feeOut.amountOut);
        DiggersToken(payable(token)).burn(feeOut.amountOut);

        uint256 buyValue = msg.value - CREATION_FEE;
        if (buyValue > 0) {
            _initialBuy(token, locks, initialBuyMinOut, buyValue);
        } else if (locks.length != 0) {
            revert LocksWithoutBuy();
        }
    }

    /// @notice Atomic create-time buy of `amount` native units.
    /// @dev With a lock table the swap delivers straight to the locker, which validates
    ///      and books it via {IDiggersLocker.lockFor}; otherwise tokens go to msg.sender.
    /// @param token Fresh DiggersToken.
    /// @param locks Distribution / vesting table (empty = plain delivery to caller).
    /// @param minOut Slippage floor on token output.
    /// @param amount Native wei to spend on the buy (msg.value − CREATION_FEE).
    function _initialBuy(address token, LockOrder[] memory locks, uint256 minOut, uint256 amount) private {
        bool split = locks.length > 0;
        address recipient = split ? LOCKER : msg.sender;

        DiggerV3.SwapOutcome memory out = _swapV3(_pool(token), token, true, amount, recipient, minOut);
        _emitSwapped(token, msg.sender, true, out.amountIn, out.amountOut);

        if (split) IDiggersLocker(LOCKER).lockFor(token, msg.sender, out.amountOut, locks);
    }

    // ----------------------------------------------------------- graduation

    /// @inheritdoc IDiggers
    /// @dev Permissionless; lib marks graduated, drops token anti-whale, and relays
    ///      Graduated/TokenGraduated through DiggersHub.
    function graduate(address token) external {
        _requireToken(token);
        DiggerGraduationLib.graduate(_graduatedAt, _tokenKeys, _tokenRecords, token, GRAD_POOL_BALANCE, HUB);
    }

    /// @inheritdoc IDiggers
    /// @dev Permissionless grant; locks name+symbol objects (+1 each) while status is held.
    ///      Blue chip is dormant pre-graduation: reverts {NotGraduated} until the token
    ///      graduates (no market-cap / volume evaluation happens before that).
    function blueChip(address token) external {
        _requireToken(token);
        if (_graduatedAt[token] == 0) revert NotGraduated();
        DiggerGraduationLib.blueChip(_blueChippedAt, _nameLocks, _tokenKeys, token, _blueChipBars(), HUB);
    }

    /// @inheritdoc IDiggers
    /// @dev Permissionless demotion; unlocks name+symbol and may stamp a 48h creation grace.
    function blueChipLost(address token) external {
        _requireToken(token);
        DiggerGraduationLib.blueChipLost(
            _blueChippedAt, _nameLocks, _keyGraceUntil, _tokenKeys, token, _blueChipBars(), HUB
        );
    }

    /// @inheritdoc IDiggers
    /// @dev ETH-quote chains only — reverts {NativeUsdMode} on NATIVE_USD deployments.
    function addOracleAsset(address asset) external onlyOwner {
        DiggerTwapOracle.register(_oracleAssets, NATIVE_USD, WETH, asset, HUB);
    }

    /// @inheritdoc IDiggers
    /// @dev With none left, the bar cache keeps serving last values (or plain-ETH fallback).
    function removeOracleAsset(address asset) external onlyOwner {
        DiggerTwapOracle.drop(_oracleAssets, NATIVE_USD, asset, HUB);
    }

    /// @notice Blue-chip thresholds every STATE-CHANGING check reads.
    /// @dev Constructor bars as-is on NATIVE_USD deployments, else the lazily refreshed
    ///      oracle cache (single source of truth — `autoBlueChip` and the explicit
    ///      entrypoints can never disagree on the bars within a block).
    /// @return Volume / mcap / holders bars (and quoteScale) for graduation math.
    function _blueChipBars() private returns (DiggerGraduationLib.BlueChipBars memory) {
        return DiggerTwapOracle.tradeBars(_barCache, _oracleAssets, _barConfig());
    }

    /// @notice Bundles the mode flag + oracle-conversion immutables for the lib calls.
    /// @return BarConfig for {DiggerTwapOracle.tradeBars}.
    function _barConfig() private view returns (DiggerTwapOracle.BarConfig memory) {
        return DiggerTwapOracle.BarConfig({
            factory: V3_FACTORY,
            weth: WETH,
            nativeUsd: NATIVE_USD,
            volumeUsd: BLUECHIP_VOLUME_USD,
            mcapUsd: BLUECHIP_MCAP_USD,
            fallbackVolume: BLUECHIP_VOLUME,
            fallbackMcap: BLUECHIP_MCAP,
            holders: BLUECHIP_HOLDERS,
            quoteScale: QUOTE_SCALE
        });
    }

    // --------------------------------------------------------------- fees

    /// @inheritdoc IDiggers
    /// @dev Thin external wrapper over {_harvest} (opportunistic harvests use the same path).
    function harvest(address token) external {
        _harvest(token);
    }

    /// @inheritdoc IDiggers
    /// @dev Pull-payment: zeroes `ethOwed[msg.sender]` before the ETH transfer; Hub
    ///      emits {Claimed}.
    function claim() external nonReentrant {
        uint256 owed = ethOwed[msg.sender];
        if (owed == 0) revert NothingToClaim();
        ethOwed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert EthTransferFailed();
        IDiggersHub(HUB).logClaimed(msg.sender, owed);
    }

    // ---------------------------------------------------- per-token ownership

    /// @inheritdoc IDiggers
    /// @dev Atomic replace of the creator ETH fee-split table; Hub emits {FeeSplitUpdated}.
    function setFeeSplits(address token, FeeSplit[] calldata rows) external onlyFeeOwner(token) {
        DiggerCreateLib.updateFeeSplits(_feeSplitCount, _feeSplits, token, rows, HUB);
    }

    /// @inheritdoc IDiggers
    /// @dev Atomic whole-config replace; nonzero Glue shares revert while Glue inactive.
    ///      Hub emits {TokenomicsUpdated}.
    function setTokenomics(
        address token,
        uint256 buybackShareWad,
        uint256 backingShareWad,
        uint256 stakingShareWad,
        uint256 burnShareWad,
        uint256 stakeShareWad
    ) external onlyBurnOwner(token) {
        DiggerCreateLib.updateTokenomics(
            _tokenRecords,
            creatorBuybackWad,
            _glueShares,
            token,
            glueDeposit != address(0),
            buybackShareWad,
            backingShareWad,
            stakingShareWad,
            burnShareWad,
            stakeShareWad,
            HUB
        );
    }

    /// @inheritdoc IDiggers
    /// @dev Relays {FeeOwnershipTransferred} through DiggersHub.
    function transferFeeOwnership(address token, address newOwner) external onlyFeeOwner(token) {
        if (newOwner == address(0)) revert OwnerRequired();
        feeOwner[token] = newOwner;
        IDiggersHub(HUB).logFeeOwnershipTransferred(token, msg.sender, newOwner);
    }

    /// @inheritdoc IDiggers
    /// @dev Forever; relays {FeeOwnershipTransferred} with `newOwner == 0`.
    function renounceFeeOwnership(address token) external onlyFeeOwner(token) {
        feeOwner[token] = address(0);
        IDiggersHub(HUB).logFeeOwnershipTransferred(token, msg.sender, address(0));
    }

    /// @inheritdoc IDiggers
    /// @dev Relays {BurnOwnershipTransferred} through DiggersHub.
    function transferBurnOwnership(address token, address newOwner) external onlyBurnOwner(token) {
        if (newOwner == address(0)) revert OwnerRequired();
        burnOwner[token] = newOwner;
        IDiggersHub(HUB).logBurnOwnershipTransferred(token, msg.sender, newOwner);
    }

    /// @inheritdoc IDiggers
    /// @dev Forever; relays {BurnOwnershipTransferred} with `newOwner == 0`.
    function renounceBurnOwnership(address token) external onlyBurnOwner(token) {
        burnOwner[token] = address(0);
        IDiggersHub(HUB).logBurnOwnershipTransferred(token, msg.sender, address(0));
    }

    // -------------------------------------------------------------- router

    /// @inheritdoc IDiggers
    /// @dev `to == address(0)` delivers to msg.sender. Opportunistic harvest + auto
    ///      graduate/blue-chip + post-buy buyback all ride inside {_trade}.
    function buy(address token, uint256 minOut, address to) external payable {
        if (msg.value == 0) revert ZeroEth();
        _trade(token, true, msg.value, minOut, to == address(0) ? msg.sender : to, false);
    }

    /// @inheritdoc IDiggers
    /// @dev Approve-free: stashes msg.sender as sell payer so {_transferToken} pulls via
    ///      DiggersToken.transferFrom allowance skip. `to == address(0)` → msg.sender.
    function sell(address token, uint256 amountIn, uint256 minOut, address to) external {
        if (amountIn == 0) revert ZeroSwapAmount();
        _trade(token, false, amountIn, minOut, to == address(0) ? msg.sender : to, true);
    }

    /// @inheritdoc IDiggers
    /// @dev Swap recipient is always {LOCKER}; books via lockFor. Same post-trade
    ///      auto-graduate / auto-blue-chip / buyback as {_trade}.
    function buyAndLock(address token, uint256 minOut, LockOrder[] calldata locks) external payable {
        if (msg.value == 0) revert ZeroEth();
        _requireToken(token);

        _maybeHarvest(token);
        DiggerV3.SwapOutcome memory out = _swapV3(_pool(token), token, true, msg.value, LOCKER, minOut);
        _emitSwapped(token, msg.sender, true, out.amountIn, out.amountOut);
        IDiggersLocker(LOCKER).lockFor(token, msg.sender, out.amountOut, locks);

        DiggerGraduationLib.autoGraduate(_graduatedAt, _tokenKeys, _tokenRecords, token, GRAD_POOL_BALANCE, HUB);
        if (_graduatedAt[token] != 0) {
            DiggerGraduationLib.autoBlueChip(
                _blueChippedAt, _nameLocks, _keyGraceUntil, _tokenKeys, token, _blueChipBars(), HUB
            );
        }
        _maybeBuyback(token, out.amountOut);
    }

    // ------------------------------------------------------------------ views

    /// @dev Every ecosystem view lives on the {HUB}; it reads this contract's state
    ///      through the raw-slot window below (Uniswap V4's extsload pattern) — strictly
    ///      read-only, exposing nothing an archive node would not.

    /// @inheritdoc IDiggers
    /// @dev DiggersHub's view window — Uniswap V4's extsload pattern. Read-only by
    ///      construction: exposes nothing a public archive node would not.
    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    /// @inheritdoc IDiggers
    /// @dev Batch twin of single-slot {extsload}.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            bytes32 value;
            assembly ("memory-safe") {
                value := sload(slot)
            }
            values[i] = value;
        }
    }

    // --------------------------------------------------------------- internal

    /// @notice Reverts {UnknownToken} when `token` was not launched by this Diggers.
    /// @param token Address that must be a DiggersToken clone from this instance.
    function _requireToken(address token) private view {
        if (!isDiggersToken[token]) revert UnknownToken();
    }

    /// @notice Returns the WETH/token V3 pool for a launched token.
    /// @param token Launched DiggersToken.
    /// @return Pool address from {_tokenRecords}.
    function _pool(address token) private view returns (address) {
        return _tokenRecords[token].pool;
    }

    /// @notice Shared buy/sell path: opportunistic harvest, V3 swap, Swapped event,
    ///         auto-graduate / auto-blue-chip, and post-buy buyback.
    /// @dev Sell mode stashes msg.sender in transient storage for approve-free
    ///      {_transferToken}. Auto status checks are silent (never revert the trade).
    ///      Buyback rides on buys only (anti-sandwich).
    /// @param token Launched DiggersToken.
    /// @param isBuy True for ETH→token, false for token→ETH.
    /// @param amountIn Exact input (wei for buys, raw tokens for sells).
    /// @param minOut Slippage floor on output.
    /// @param recipient Swap output recipient.
    /// @param sellMode True when this is a sell (enables sell-payer stash).
    function _trade(
        address token,
        bool isBuy,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        bool sellMode
    ) private {
        _requireToken(token);
        _maybeHarvest(token);
        if (sellMode) _stashSellPayer(msg.sender);
        DiggerV3.SwapOutcome memory out = _swapV3(_pool(token), token, isBuy, amountIn, recipient, minOut);
        if (sellMode) _dropSellPayer();
        _emitSwapped(
            token,
            msg.sender,
            isBuy,
            isBuy ? out.amountIn : out.amountOut,
            isBuy ? out.amountOut : out.amountIn
        );

        // Auto-graduation + BOTH-direction blue-chip check (silent, never reverts the
        // trade): promote when all legs pass, demote when a live leg fails. Blue chip is
        // dormant until graduation — no bar refresh, no evaluation, no oracle touch
        // (checked AFTER autoGraduate so the graduating trade itself already qualifies).
        DiggerGraduationLib.autoGraduate(_graduatedAt, _tokenKeys, _tokenRecords, token, GRAD_POOL_BALANCE, HUB);
        if (_graduatedAt[token] != 0) {
            DiggerGraduationLib.autoBlueChip(
                _blueChippedAt, _nameLocks, _keyGraceUntil, _tokenKeys, token, _blueChipBars(), HUB
            );
        }

        // Buyback rides on BUYS only (anti-sandwich: sizing is capped by the user's own
        // output, so a sell must never unlock a pot spend).
        if (isBuy) _maybeBuyback(token, out.amountOut);
    }

    /// @notice Opportunistic harvest before a trade when pending fees clear the floors.
    /// @dev Pool-side pending fees are quote UNITS; the wei floor converts down via
    ///      {QUOTE_SCALE}. Quote-side floor is {WRAP_MIN_THRESHOLD} (chain-parameterized);
    ///      token-side floor is {HARVEST_THRESHOLD_TOKEN}.
    /// @param token Launched DiggersToken about to be traded.
    function _maybeHarvest(address token) private {
        TokenRecord memory rec = _tokenRecords[token];
        // Pool-side pending fees are quote UNITS; the wei floor converts down to match.
        if (
            !DiggerHarvestViews.shouldHarvest(
                rec.pool,
                address(this),
                rec.tickLower,
                rec.tickUpper,
                WRAP_MIN_THRESHOLD / QUOTE_SCALE,
                HARVEST_THRESHOLD_TOKEN
            )
        ) return;
        _harvest(token);
    }

    /// @notice Gates {create}/{createFull}: public launches require {creationOpen}; the
    ///         protocol {owner} may always create (canary / bootstrap while closed).
    /// @dev Reverts {CreationClosed} for non-owners when the gate is shut.
    function _requireCreationOpen() private view {
        if (!creationOpen && msg.sender != owner) revert CreationClosed();
    }

    /// @notice Collects LP fees and splits them IN FULL (team / creators / buyback / Glue /
    ///         burn / pot). No reinvest leg: the seed position's liquidity is permanent
    ///         and constant — graduation is supply-sold, so fees never need to grow L.
    /// @dev `nonReentrant` guards the ETH-push path. Hub emits Harvested / FeeParked as
    ///      applicable.
    /// @param token Launched DiggersToken whose position fees to harvest.
    function _harvest(address token) private nonReentrant {
        _requireToken(token);
        TokenRecord memory rec = _tokenRecords[token];

        (uint256 ethFees, uint256 tokenFees) = _collectFeesV3(rec.pool, rec.tickLower, rec.tickUpper);

        uint256 carried = pendingEth[token];
        if (ethFees == 0 && tokenFees == 0 && carried == 0) return;
        if (carried > 0) pendingEth[token] = 0;

        GlueShares memory glue = _glueShares[token];
        DiggerHarvestLib.distribute(
            ethOwed,
            pendingEth,
            _feeSplits[token],
            DiggerHarvestLib.DistributeParams({
                count: _feeSplitCount[token],
                teamTreasury: feeRecipient,
                feeOwner: feeOwner[token],
                token: token,
                caller: msg.sender,
                glue: glueDeposit,
                hub: HUB,
                ethFees: ethFees,
                carriedPending: carried,
                tokenFees: tokenFees,
                teamShareWad: teamShareWad,
                creatorBuybackWad: creatorBuybackWad[token],
                backingWad: glue.backingWad,
                stakingWad: glue.stakingWad,
                burnShareWad: rec.burnShareWad,
                stakeWad: glue.stakeWad
            })
        );
    }

    // ------------------------------------------------------------- buyback

    /// @notice Fire-and-forget buyback attempt after a settled user BUY.
    /// @dev The external self-call puts the whole flow (wrap step + quote + swap + burn)
    ///      behind one try/catch, so no buyback problem can ever revert the carrying trade.
    ///      Cheap pre-check skips the self-call when the pot is empty / below wrap dust.
    /// @param token Launched DiggersToken whose pot to spend.
    /// @param userAmountOut Token output of the carrying user buy (buyback size cap).
    function _maybeBuyback(address token, uint256 userAmountOut) private {
        // Cheap pre-check: anything wrappable or spendable parked on the token? In
        // dual-native mode the native balance IS the pot (one shared balance — reading
        // the ERC-20 side too would double-count): spendable from 1 pool unit up.
        if (DUAL_NATIVE) {
            if (address(token).balance < QUOTE_SCALE) return;
        } else if (address(token).balance < WRAP_MIN_THRESHOLD && IWETH9(WETH).balanceOf(token) == 0) {
            return;
        }
        try this.execBuyback(token, userAmountOut) {} catch {}
    }

    /// @inheritdoc IDiggers
    /// @dev ONLY callable by this contract (try/caught self-call from {_maybeBuyback}).
    ///      Prepare lives in DiggerBuybackLib; swap + burn stay here for V3 callback access.
    ///      Hub emits {BuybackBurned}.
    function execBuyback(address token, uint256 userAmountOut) external {
        if (msg.sender != address(this)) revert NotSelf();

        // Wrap step + anti-sandwich sizing + pot pull live in the delegatecall lib; the
        // launchpad keeps the swap (internal V3 callback plumbing) and the burn.
        TokenRecord memory rec = _tokenRecords[token];
        (uint256 spend, uint256 minOut) = DiggerBuybackLib.prepare(
            token, WETH, rec.pool, rec.poolFee, userAmountOut, WRAP_MIN_THRESHOLD, QUOTE_SCALE, DUAL_NATIVE
        );
        if (spend == 0) return;

        DiggerV3.SwapOutcome memory out = _swapV3(rec.pool, token, true, spend, address(this), minOut);
        DiggersToken(payable(token)).burn(out.amountOut);
        IDiggersHub(HUB).logBuybackBurned(token, spend, out.amountOut);
    }

    /// @notice Relays a rich {Swapped} event through DiggersHub with post-trade pool state.
    /// @dev Pool state is computed HERE (record + range are one warm SLOAD away) and
    ///      shipped whole to the hub, which is already warm from the token's own telemetry
    ///      calls in the same trade. ETH amounts / reserves are in wei.
    /// @param token Launched DiggersToken traded.
    /// @param trader Router caller.
    /// @param isBuy True for ETH→token.
    /// @param ethAmount ETH side in wei.
    /// @param tokenAmount Token side in raw units.
    function _emitSwapped(address token, address trader, bool isBuy, uint256 ethAmount, uint256 tokenAmount) private {
        TokenRecord memory rec = _tokenRecords[token];
        DiggerSwapViews.State memory s = DiggerSwapViews.afterSwap(rec.pool, rec.tickLower, rec.tickUpper);

        IDiggersHub(HUB).logSwapped(
            token,
            trader,
            isBuy,
            ethAmount,
            tokenAmount,
            s.sqrtPriceX96,
            s.tick,
            s.liquidity,
            s.ethInPool * QUOTE_SCALE, // reserves in wei, like every other event field
            s.tokenInPool
        );
    }

    /// @notice Stashes the outer sell caller in transient storage for approve-free pulls.
    /// @dev Namespaced by `address(this)` so a malicious token cannot collide the slot.
    /// @param payer Outer `msg.sender` of {sell} (must equal transferFrom `from`).
    function _stashSellPayer(address payer) private {
        bytes32 slot = keccak256(abi.encodePacked(address(this), SELL_PAYER_SLOT));
        assembly {
            tstore(slot, payer)
        }
    }

    /// @notice Reads the stashed sell payer (zero outside an active sell).
    /// @return payer Address stashed by {_stashSellPayer}, or zero.
    function _loadSellPayer() private view returns (address payer) {
        bytes32 slot = keccak256(abi.encodePacked(address(this), SELL_PAYER_SLOT));
        assembly {
            payer := tload(slot)
        }
    }

    /// @notice Clears the transient sell-payer latch after the V3 callback completes.
    function _dropSellPayer() private {
        bytes32 slot = keccak256(abi.encodePacked(address(this), SELL_PAYER_SLOT));
        assembly {
            tstore(slot, 0)
        }
    }

    /// @inheritdoc DiggerV3Base
    /// @dev During sells, pulls from the stashed payer via DiggersToken.transferFrom
    ///      (allowance skip). Otherwise transfers from this contract's own balance
    ///      (buys delivering to recipients, fee burns, etc.).
    function _transferToken(address token, address to, uint256 amount) internal override {
        address payer = _loadSellPayer();
        if (payer != address(0)) {
            DiggersToken(payable(token)).transferFrom(payer, to, amount);
        } else {
            DiggersToken(payable(token)).transfer(to, amount);
        }
    }
}
