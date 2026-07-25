// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3} from "./libs/DiggerV3.sol";
import {DiggerCharset} from "./libs/DiggerCharset.sol";
import {DiggerQuotes} from "./libs/DiggerQuotes.sol";
import {DiggerSwapViews} from "./libs/DiggerSwapViews.sol";
import {DiggerHarvestViews} from "./libs/DiggerHarvestViews.sol";
import {DiggerGraduationMath} from "./libs/DiggerGraduationMath.sol";
import {DiggerGraduationLib} from "./libs/DiggerGraduationLib.sol";
import {DiggerTwapOracle} from "./libs/DiggerTwapOracle.sol";
import {IDiggers} from "./interfaces/IDiggers.sol";
import {IDiggersHub} from "./interfaces/IDiggersHub.sol";
import {IDiggersToken} from "./interfaces/IDiggersToken.sol";

/**
 * @title IDiggersConfig
 * @notice Minimal Diggers surface the hub reads lazily for chain-parameter immutables
 *         and the raw-slot storage window.
 * @dev Getters are already public on the concrete Diggers. Views are eth_call territory,
 *      so the staticcall round-trips cost users nothing.
 * @author BasedDopamine
 */
interface IDiggersConfig {
    /// @notice Canonical Uniswap V3 factory this Diggers instance uses.
    /// @return Factory address.
    function V3_FACTORY() external view returns (address);

    /// @notice Quote token (WETH9 or dual-native USDT0) — token0 of every pool.
    /// @return Quote ERC-20 address.
    function WETH() external view returns (address);

    /// @notice Wei-per-pool-unit scale of the quote side (`10^(18−decimals)`).
    /// @return Quote scale factor.
    function QUOTE_SCALE() external view returns (uint256);

    /// @notice Spacing-aligned launch tick used for every new pool.
    /// @return Launch tick.
    function START_TICK() external view returns (int24);

    /// @notice Graduation pool-balance threshold: TOTAL_SUPPLY x (1 - GRAD_SOLD_WAD).
    /// @return Raw token units the pool balance must fall to for graduation.
    function GRAD_POOL_BALANCE() external view returns (uint256);

    /// @notice Blue-chip volume bar (NATIVE_USD dollars or plain-ETH wei fallback).
    /// @return Volume threshold.
    function BLUECHIP_VOLUME() external view returns (uint256);

    /// @notice Blue-chip mean-tick mcap bar (same mode semantics as volume).
    /// @return Market-cap threshold.
    function BLUECHIP_MCAP() external view returns (uint256);

    /// @notice Blue-chip holder-count threshold (live leg).
    /// @return Minimum unique holders.
    function BLUECHIP_HOLDERS() external view returns (uint32);

    /// @notice Whether the quote itself is USD (oracle machinery inert when true).
    /// @return True on Stable/USDT0-style deployments.
    function NATIVE_USD() external view returns (bool);

    /// @notice Blue-chip volume bar in USD 1e18 (ETH-quote chains only; 0 when NATIVE_USD).
    /// @return USD volume bar.
    function BLUECHIP_VOLUME_USD() external view returns (uint256);

    /// @notice Blue-chip mcap bar in USD 1e18 (ETH-quote chains only; 0 when NATIVE_USD).
    /// @return USD mcap bar.
    function BLUECHIP_MCAP_USD() external view returns (uint256);

    /// @notice Raw storage-slot reader on Diggers (Uniswap V4 extsload pattern).
    /// @param slot Storage slot to read.
    /// @return Raw 32-byte contents.
    function extsload(bytes32 slot) external view returns (bytes32);
}

/**
 * @title DiggersHub
 * @notice The protocol's ONE address for the outside world: every protocol event prints
 *         here and every ecosystem view is served here, so the UX and the indexer
 *         connect to the hub and nothing else. The size-constrained Diggers singleton
 *         keeps only the engine.
 *
 *         EVENTS — emitter-gated relays: the launchpad binds itself at construction
 *         (`bind`, one-shot) and registers the locker and every token clone it deploys
 *         (`register`, launchpad-only), so ONLY family code can print. A token event's
 *         token identity is always `msg.sender` — a registered token cannot spoof
 *         another token's feed, and a foreign contract cannot enter the stream at all.
 *
 *         VIEWS — the hub owns no protocol state; it reads the launchpad's storage
 *         through the raw-slot `extsload` window (slot table pinned below against the
 *         compiler layout), calls pools/tokens directly, and mirrors the launchpad's
 *         chain-parameter immutables through their public getters. All view logic that
 *         used to live on the singleton (registry keys, records, quotes, pool state,
 *         TWAP bar preview, progress) is compiled in here instead.
 * @dev Diggers V2 architecture: Diggers is factory + router + fee splitter (engine only);
 *      DiggersToken clones and DiggersLocker are registered emitters that relay here;
 *      this hub has no owner, no funds, and no power over protocol state — pure
 *      telemetry + lens. A front-run `bind` on a freshly deployed hub only forces a
 *      redeploy: the launchpad constructor binds in the same transaction that deploys
 *      it, and a hub bound to anything else reverts that construction.
 * @author BasedDopamine
 */
contract DiggersHub is IDiggersHub {
    // ------------------------------------------------- Diggers storage slot table

    /// @dev Diggers' compiler storage layout (forge inspect, pinned 2026-07-23). The
    ///      whole migrated view suite reads through these constants, so any layout
    ///      drift fails the tests loudly. Slots 0..2 (owner/feeRecipient/teamShareWad),
    ///      6 (ethOwed), 9..12 and 14 keep their public getters on the launchpad and
    ///      are not duplicated here.
    uint256 private constant SLOT_CREATE_NONCE = 3;
    uint256 private constant SLOT_IS_TOKEN = 4;
    uint256 private constant SLOT_TOKEN_RECORDS = 5;
    uint256 private constant SLOT_FEE_SPLIT_COUNT = 7;
    uint256 private constant SLOT_FEE_SPLITS = 8;
    uint256 private constant SLOT_GLUE_SHARES = 13;
    uint256 private constant SLOT_NAME_LOCKS = 15;
    uint256 private constant SLOT_KEY_GRACE = 16;
    uint256 private constant SLOT_ORACLE_ASSETS = 17;
    uint256 private constant SLOT_BAR_CACHE = 18;
    uint256 private constant SLOT_GRADUATED_AT = 20;
    uint256 private constant SLOT_BLUECHIPPED_AT = 21;
    uint256 private constant SLOT_TOKEN_KEYS = 22;

    // ---------------------------------------------------------------- storage

    /// @inheritdoc IDiggersHub
    address public DIGGERS;

    /// @inheritdoc IDiggersHub
    mapping(address => bool) public isEmitter;

    // ------------------------------------------------------------------ binding

    /// @notice Restricts every `log*` endpoint to the emitter set (launchpad, locker,
    ///         registered token clones).
    /// @dev Reverts {NotEmitter} for foreign callers — the factory itself vouches family
    ///      code via {register}.
    modifier onlyEmitter() {
        if (!isEmitter[msg.sender]) revert NotEmitter();
        _;
    }

    /// @inheritdoc IDiggersHub
    /// @dev Also marks the caller as the first emitter and emits {EmitterRegistered}.
    function bind() external {
        if (DIGGERS != address(0)) revert AlreadyBound();
        DIGGERS = msg.sender;
        isEmitter[msg.sender] = true;
        emit EmitterRegistered(msg.sender);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Diggers calls this for the locker at construction and for every token clone
    ///      at create — never for arbitrary addresses.
    function register(address emitter) external {
        if (msg.sender != DIGGERS) revert NotDiggers();
        isEmitter[emitter] = true;
        emit EmitterRegistered(emitter);
    }

    // ----------------------------------------------- log endpoints: token clones

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender` (unspoofable by another registered clone).
    function logPoolTrade(
        address trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethValue,
        int24 tick,
        uint32 holdersAfter,
        uint256 volumeEthCumAfter,
        uint256 epoch
    ) external onlyEmitter {
        emit PoolTrade(msg.sender, trader, isBuy, tokenAmount, ethValue, tick, holdersAfter, volumeEthCumAfter, epoch);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender`.
    function logPoints(
        uint256 epoch,
        address trader,
        bool isBuy,
        uint256 pointsEarned,
        uint256 newScore,
        uint256 lifetimeScore
    ) external onlyEmitter {
        emit PointsCredited(msg.sender, epoch, trader, isBuy, pointsEarned, newScore, lifetimeScore);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender`.
    function logPointsRevoked(
        uint256 epoch,
        address trader,
        bool wasBuy,
        uint256 pointsRemoved,
        uint256 newScore,
        uint256 lifetimeScore
    ) external onlyEmitter {
        emit PointsRevoked(msg.sender, epoch, trader, wasBuy, pointsRemoved, newScore, lifetimeScore);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender`.
    function logLeaderboard(uint256 epoch, address entrant, address evicted, uint256 entrantScore)
        external
        onlyEmitter
    {
        emit LeaderboardChanged(msg.sender, epoch, entrant, evicted, entrantScore);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender`.
    function logHolderCount(address holder, bool added, uint32 holderCountAfter) external onlyEmitter {
        emit HolderCountChanged(msg.sender, holder, added, holderCountAfter);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender`.
    function logEpochSettled(uint256 epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline)
        external
        onlyEmitter
    {
        emit EpochSettled(msg.sender, epoch, potPerWinner, rolledOver, nextDeadline);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Token identity is always `msg.sender`.
    function logAirdropPaid(uint256 epoch, address winner, uint256 amount) external onlyEmitter {
        emit AirdropPaid(msg.sender, epoch, winner, amount);
    }

    // --------------------------------------------------- log endpoints: the locker

    /// @inheritdoc IDiggersHub
    /// @dev Called by DiggersLocker; aggregates on the event are post-lock still-locked totals.
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
    ) external onlyEmitter {
        emit Locked(token, wallet, index, funder, amount, start, duration, tranches, walletLocked, tokenLockedSupply);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Called by DiggersLocker; aggregates on the event are post-payout still-locked totals.
    function logWithdrawn(
        address token,
        address wallet,
        uint256 index,
        uint256 amount,
        uint256 walletLocked,
        uint256 tokenLockedSupply
    ) external onlyEmitter {
        emit Withdrawn(token, wallet, index, amount, walletLocked, tokenLockedSupply);
    }

    // ------------------------------------------------- log endpoints: the launchpad

    /// @inheritdoc IDiggersHub
    /// @dev Called by Diggers / DiggerCreateLib at launch.
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
    ) external onlyEmitter {
        emit Created(token, creator, name, symbol, metadataURI, pool, startSqrtPriceX96, poolFee, burnShareWad);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Emitted once at create with the initial fee-split table.
    function logFeeSplitConfigured(address token, address[] calldata recipients, uint256[] calldata shares)
        external
        onlyEmitter
    {
        emit FeeSplitConfigured(token, recipients, shares);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Emitted on fee-owner {setFeeSplits}.
    function logFeeSplitUpdated(address token, address[] calldata recipients, uint256[] calldata shares)
        external
        onlyEmitter
    {
        emit FeeSplitUpdated(token, recipients, shares);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Emitted at create and on every burn-owner {setTokenomics}.
    function logTokenomicsUpdated(
        address token,
        uint256 buybackShareWad,
        uint256 backingShareWad,
        uint256 stakingShareWad,
        uint256 burnShareWad,
        uint256 stakeShareWad
    ) external onlyEmitter {
        emit TokenomicsUpdated(token, buybackShareWad, backingShareWad, stakingShareWad, burnShareWad, stakeShareWad);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Diggers ships post-trade pool state already computed (warm SLOADs on the engine).
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
    ) external onlyEmitter {
        emit Swapped(
            token,
            trader,
            isBuy,
            ethAmount,
            tokenAmount,
            sqrtPriceAfterX96,
            tickAfter,
            liquidityAfter,
            ethInPool,
            tokenInPool
        );
    }

    /// @inheritdoc IDiggersHub
    /// @dev Called from Diggers harvest distribution; glue fields are 0 when deposit failed open.
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
    ) external onlyEmitter {
        emit Harvested(
            token,
            caller,
            ethTotal,
            ethToTeam,
            ethToCreators,
            ethToBuyback,
            ethToGlue,
            tokensBurned,
            tokensToGlue,
            tokensToPot
        );
    }

    /// @inheritdoc IDiggersHub
    /// @dev Failed fee-split push parked for later {claim}.
    function logFeeParked(address token, address recipient, uint256 amount) external onlyEmitter {
        emit FeeParked(token, recipient, amount);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Pull-payment ETH claim settled on Diggers.
    function logClaimed(address account, uint256 amount) external onlyEmitter {
        emit Claimed(account, amount);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Emits BOTH {Graduated} (rich indexer payload) and {TokenGraduated} (minimal
    ///      integrator companion with `pool`) in the same call.
    function logGraduated(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        uint32 holders,
        uint256 volumeEthCum,
        uint256 supplySold,
        address pool
    ) external onlyEmitter {
        emit Graduated(token, nameKey, symbolKey, holders, volumeEthCum, supplySold);
        emit TokenGraduated(token, pool);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Name+symbol objects gain one live blue-chip lock each.
    function logBlueChip(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        uint256 volumeEthCum,
        uint256 avgMcapEth,
        uint32 holders
    ) external onlyEmitter {
        emit BlueChip(token, nameKey, symbolKey, volumeEthCum, avgMcapEth, holders);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Name+symbol unlock; `graceUntil` protects a last-lock demotion for 48h.
    function logBlueChipLost(
        address token,
        bytes32 nameKey,
        bytes32 symbolKey,
        uint256 avgMcapEth,
        uint32 holders,
        uint64 graceUntil
    ) external onlyEmitter {
        emit BlueChipLost(token, nameKey, symbolKey, avgMcapEth, holders, graceUntil);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Post-buy pot spend; sized so output never exceeds the carrying user buy.
    function logBuybackBurned(address token, uint256 ethIn, uint256 tokensBurned) external onlyEmitter {
        emit BuybackBurned(token, ethIn, tokensBurned);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Owner registration on ETH-quote chains; `unit` is `10**decimals`.
    function logOracleAssetAdded(address asset, uint96 unit) external onlyEmitter {
        emit OracleAssetAdded(asset, unit);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Owner removal; empty set falls back to cached / plain-ETH bars.
    function logOracleAssetRemoved(address asset) external onlyEmitter {
        emit OracleAssetRemoved(asset);
    }

    /// @inheritdoc IDiggersHub
    /// @dev ONE-SHOT Diggers owner activation of Glue V2.
    function logGlueActivated(address glue) external onlyEmitter {
        emit GlueActivated(glue);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Global Diggers owner config change.
    function logTeamShareUpdated(uint256 teamShareWad) external onlyEmitter {
        emit TeamShareUpdated(teamShareWad);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Global Diggers owner config change.
    function logFeeRecipientUpdated(address feeRecipient) external onlyEmitter {
        emit FeeRecipientUpdated(feeRecipient);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Global Diggers owner config change (creation gate open/pause).
    function logCreationOpenSet(bool open) external onlyEmitter {
        emit CreationOpenSet(open);
    }

    /// @inheritdoc IDiggersHub
    /// @dev `newOwner == 0` means renounced forever.
    function logOwnershipTransferred(address previousOwner, address newOwner) external onlyEmitter {
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Per-token fee-split ownership; `newOwner == 0` means renounced.
    function logFeeOwnershipTransferred(address token, address previousOwner, address newOwner) external onlyEmitter {
        emit FeeOwnershipTransferred(token, previousOwner, newOwner);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Per-token burn/tokenomics ownership; `newOwner == 0` means renounced.
    function logBurnOwnershipTransferred(address token, address previousOwner, address newOwner) external onlyEmitter {
        emit BurnOwnershipTransferred(token, previousOwner, newOwner);
    }

    // ---------------------------------------------------------- views: registry

    /// @inheritdoc IDiggersHub
    function isNameFree(string calldata name) external view returns (bool) {
        return _keyFree(DiggerCharset.nameKey(name));
    }

    /// @inheritdoc IDiggersHub
    function isSymbolFree(string calldata symbol) external view returns (bool) {
        return _keyFree(DiggerCharset.symbolKey(symbol));
    }

    /// @inheritdoc IDiggersHub
    function keyStateOf(string calldata name, string calldata symbol)
        external
        view
        returns (uint32 nameLocks, uint32 symbolLocks, uint64 nameGraceUntil, uint64 symbolGraceUntil)
    {
        bytes32 nameKey = DiggerCharset.nameKey(name);
        bytes32 symbolKey = DiggerCharset.symbolKey(symbol);
        nameLocks = uint32(uint256(_sload(_slotOf(nameKey, SLOT_NAME_LOCKS))));
        symbolLocks = uint32(uint256(_sload(_slotOf(symbolKey, SLOT_NAME_LOCKS))));
        nameGraceUntil = uint64(uint256(_sload(_slotOf(nameKey, SLOT_KEY_GRACE))));
        symbolGraceUntil = uint64(uint256(_sload(_slotOf(symbolKey, SLOT_KEY_GRACE))));
    }

    /// @notice Whether a registry key object is free for creation right now.
    /// @dev Free = no live blue-chip lock AND past any post-demotion grace stamp.
    /// @param key Folded name or symbol key.
    /// @return True if the key may be used in a new launch.
    function _keyFree(bytes32 key) private view returns (bool) {
        return _sload(_slotOf(key, SLOT_NAME_LOCKS)) == bytes32(0)
            && block.timestamp >= uint64(uint256(_sload(_slotOf(key, SLOT_KEY_GRACE))));
    }

    // ------------------------------------------------------- views: token status

    /// @inheritdoc IDiggersHub
    function tokenKeys(address token) external view returns (IDiggers.TokenKeys memory) {
        _requireToken(token);
        return _tokenKeysOf(token);
    }

    /// @inheritdoc IDiggersHub
    function graduatedAt(address token) external view returns (uint64) {
        _requireToken(token);
        return uint64(uint256(_sload(_slotOf(token, SLOT_GRADUATED_AT))));
    }

    /// @inheritdoc IDiggersHub
    function blueChippedAt(address token) external view returns (uint64) {
        _requireToken(token);
        return uint64(uint256(_sload(_slotOf(token, SLOT_BLUECHIPPED_AT))));
    }

    /// @inheritdoc IDiggersHub
    /// @dev Composes token.graduationStats, the supply-sold graduation check, and
    ///      blue-chip bar evaluation; `blueChipMcapPass` shows the deciding side
    ///      (promotion bar vs retention bar) based on current blue-chip status.
    function progressOf(address token) external view returns (IDiggers.Progress memory p) {
        _requireToken(token);
        IDiggers.TokenKeys memory k = _tokenKeysOf(token);
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();

        int24 meanTick;
        uint16 daysTracked;
        (p.holders, p.volumeEth, meanTick, daysTracked) = IDiggersToken(token).graduationStats();

        IDiggers.TokenRecord memory rec = _recordOf(token);
        uint256 gradPoolBalance = _cfg().GRAD_POOL_BALANCE();
        (bool gradPass, uint256 poolBalance) =
            DiggerGraduationMath.evaluateGraduation(token, rec.pool, gradPoolBalance);
        p.graduationPass = gradPass;
        p.supplySold = DiggerGraduationMath.TOTAL_SUPPLY - poolBalance;
        p.supplySoldTarget = DiggerGraduationMath.TOTAL_SUPPLY - gradPoolBalance;

        p.graduatedAt = uint64(uint256(_sload(_slotOf(token, SLOT_GRADUATED_AT))));
        p.blueChippedAt = uint64(uint256(_sload(_slotOf(token, SLOT_BLUECHIPPED_AT))));

        (DiggerGraduationLib.BlueChipBars memory bars,,) = _bars();
        bool mcapPassHi;
        bool mcapPassLo;
        (p.blueChipPass, p.avgMcapEth, p.blueChipVolumePass, mcapPassHi, mcapPassLo, p.blueChipHoldersPass) =
        DiggerGraduationMath.evaluateBlueChip(
            p.holders, p.volumeEth, meanTick, daysTracked, bars.volume, bars.mcapHi, bars.mcapLo, bars.holders,
            bars.quoteScale
        );
        // The mcap flag shows the side that currently DECIDES: the promotion bar for a
        // token chasing the status, the retention bar for a live blue chip.
        p.blueChipMcapPass = p.blueChippedAt == 0 ? mcapPassHi : mcapPassLo;

        p.nameLocks = uint32(uint256(_sload(_slotOf(k.nameKey, SLOT_NAME_LOCKS))));
        p.symbolLocks = uint32(uint256(_sload(_slotOf(k.symbolKey, SLOT_NAME_LOCKS))));
    }

    // ------------------------------------------------------------ views: oracle

    /// @inheritdoc IDiggersHub
    function oracleAssets() external view returns (address[] memory assets) {
        DiggerTwapOracle.OracleAsset[] memory list = _loadOracleAssets();
        assets = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            assets[i] = list[i].asset;
        }
    }

    /// @inheritdoc IDiggersHub
    function blueChipBars()
        external
        view
        returns (uint256 volumeBar, uint256 mcapBarHi, uint256 mcapBarLo, bool oracleLive, uint64 cacheUpdatedAt)
    {
        (DiggerGraduationLib.BlueChipBars memory bars, bool live, uint64 updatedAt) = _bars();
        return (bars.volume, bars.mcapHi, bars.mcapLo, live, updatedAt);
    }

    /// @notice Read-only blue-chip bar preview over extsload-loaded oracle state.
    /// @dev A FRESH conversion when the oracles answer, else the cached bars, else the
    ///      plain fallback — exactly what the launchpad's next state-changing check would use.
    /// @return bars Volume / mcapHi / mcapLo / holders / quoteScale bundle.
    /// @return live True when a fresh oracle conversion was used.
    /// @return updatedAt Unix timestamp of the last bar-cache write.
    function _bars() private view returns (DiggerGraduationLib.BlueChipBars memory, bool, uint64) {
        return DiggerTwapOracle.previewBarsMem(_loadBarCache(), _loadOracleAssets(), _barConfig());
    }

    /// @notice Rebuilds the launchpad's bar config from its public chain-parameter getters.
    /// @return BarConfig for {DiggerTwapOracle} preview / conversion helpers.
    function _barConfig() private view returns (DiggerTwapOracle.BarConfig memory) {
        IDiggersConfig cfg = _cfg();
        return DiggerTwapOracle.BarConfig({
            factory: cfg.V3_FACTORY(),
            weth: cfg.WETH(),
            nativeUsd: cfg.NATIVE_USD(),
            volumeUsd: cfg.BLUECHIP_VOLUME_USD(),
            mcapUsd: cfg.BLUECHIP_MCAP_USD(),
            fallbackVolume: cfg.BLUECHIP_VOLUME(),
            fallbackMcap: cfg.BLUECHIP_MCAP(),
            holders: cfg.BLUECHIP_HOLDERS(),
            quoteScale: cfg.QUOTE_SCALE()
        });
    }

    /// @notice The registered-asset array, one raw slot per packed {asset, unit} element.
    /// @return arr Oracle assets mirrored from Diggers' `_oracleAssets` storage.
    function _loadOracleAssets() private view returns (DiggerTwapOracle.OracleAsset[] memory arr) {
        uint256 len = uint256(_sload(bytes32(SLOT_ORACLE_ASSETS)));
        arr = new DiggerTwapOracle.OracleAsset[](len);
        uint256 dataSlot = uint256(keccak256(abi.encode(SLOT_ORACLE_ASSETS)));
        for (uint256 i; i < len; ++i) {
            uint256 raw = uint256(_sload(bytes32(dataSlot + i)));
            arr[i] = DiggerTwapOracle.OracleAsset({asset: address(uint160(raw)), unit: uint96(raw >> 160)});
        }
    }

    /// @notice The two packed bar-cache slots (volumeHi|mcapHi|updatedAt, then mcapLo).
    /// @return c Diggers' `_barCache` decoded for oracle preview.
    function _loadBarCache() private view returns (DiggerTwapOracle.BarCache memory c) {
        uint256 slot0 = uint256(_sload(bytes32(SLOT_BAR_CACHE)));
        c.volumeHi = uint96(slot0);
        c.mcapHi = uint96(slot0 >> 96);
        c.updatedAt = uint64(slot0 >> 192);
        c.mcapLo = uint96(uint256(_sload(bytes32(SLOT_BAR_CACHE + 1))));
    }

    // ------------------------------------------------------------ views: records

    /// @inheritdoc IDiggersHub
    function isDiggersToken(address token) external view returns (bool) {
        return _isToken(token);
    }

    /// @inheritdoc IDiggersHub
    function tokenRecord(address token) external view returns (IDiggers.TokenRecord memory) {
        _requireToken(token);
        return _recordOf(token);
    }

    /// @inheritdoc IDiggersHub
    function createNonce() external view returns (uint256) {
        return uint256(_sload(bytes32(SLOT_CREATE_NONCE)));
    }

    /// @inheritdoc IDiggersHub
    /// @dev ETH reserve scaled pool-units→wei via {QUOTE_SCALE} to match event fields.
    function poolState(address token)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 ethInPool, uint256 tokenInPool)
    {
        _requireToken(token);
        IDiggers.TokenRecord memory rec = _recordOf(token);
        DiggerSwapViews.State memory s = DiggerSwapViews.afterSwap(rec.pool, rec.tickLower, rec.tickUpper);
        return (s.sqrtPriceX96, s.tick, s.liquidity, s.ethInPool * _cfg().QUOTE_SCALE(), s.tokenInPool);
    }

    /// @inheritdoc IDiggersHub
    /// @dev ETH fees scaled pool-units→wei via {QUOTE_SCALE}.
    function pendingFees(address token) external view returns (uint256 ethFees, uint256 tokenFees) {
        _requireToken(token);
        IDiggers.TokenRecord memory rec = _recordOf(token);
        (ethFees, tokenFees) = DiggerHarvestViews.pendingFees(rec.pool, DIGGERS, rec.tickLower, rec.tickUpper);
        ethFees *= _cfg().QUOTE_SCALE(); // pool units -> wei
    }

    /// @inheritdoc IDiggersHub
    function feeSplitCount(address token) external view returns (uint8) {
        _requireToken(token);
        return _feeSplitCountOf(token);
    }

    /// @inheritdoc IDiggersHub
    /// @dev FeeSplit rows live behind a nested mapping:
    ///      `row base = keccak(index, keccak(token, SLOT_FEE_SPLITS))`.
    function feeSplitAt(address token, uint256 index) external view returns (IDiggers.FeeSplit memory) {
        _requireToken(token);
        if (index >= _feeSplitCountOf(token)) revert IDiggers.UnknownToken();
        // FeeSplit rows live behind a nested mapping: row base = keccak(index, keccak(token, slot)).
        bytes32 rowSlot = keccak256(abi.encode(index, _slotOf(token, SLOT_FEE_SPLITS)));
        return IDiggers.FeeSplit({
            to: address(uint160(uint256(_sload(rowSlot)))),
            share: uint256(_sload(bytes32(uint256(rowSlot) + 1)))
        });
    }

    /// @inheritdoc IDiggersHub
    /// @dev Packed Diggers slot: backingWad | stakingWad | stakeWad (each uint64).
    function glueSharesOf(address token) external view returns (IDiggers.GlueShares memory) {
        _requireToken(token);
        uint256 raw = uint256(_sload(_slotOf(token, SLOT_GLUE_SHARES)));
        return IDiggers.GlueShares({
            backingWad: uint64(raw),
            stakingWad: uint64(raw >> 64),
            stakeWad: uint64(raw >> 128)
        });
    }

    // ------------------------------------------------------------- views: quotes

    /// @inheritdoc IDiggersHub
    /// @dev Buy inputs floor wei→pool units via {QUOTE_SCALE}; sub-unit inputs quote to 0.
    function quoteBuy(address token, uint256 ethIn) external view returns (uint256 amountOut) {
        _requireToken(token);
        IDiggers.TokenRecord memory rec = _recordOf(token);
        // Quotes cross the wei⇄pool-unit boundary exactly like the swap they predict:
        // buy inputs floor to units, sell outputs scale back up to wei.
        uint256 unitsIn = ethIn / _cfg().QUOTE_SCALE();
        if (unitsIn == 0) return 0;
        return DiggerQuotes.quoteExactInput(rec.pool, rec.poolFee, true, unitsIn);
    }

    /// @inheritdoc IDiggersHub
    /// @dev Sell outputs scale pool units→wei via {QUOTE_SCALE}.
    function quoteSell(address token, uint256 tokenIn) external view returns (uint256 amountOut) {
        _requireToken(token);
        IDiggers.TokenRecord memory rec = _recordOf(token);
        return DiggerQuotes.quoteExactInput(rec.pool, rec.poolFee, false, tokenIn) * _cfg().QUOTE_SCALE();
    }

    /// @inheritdoc IDiggersHub
    /// @dev Derived from Diggers' {START_TICK} via Uniswap tick math — identical for every pool.
    function START_SQRT_PRICE_X96() external view returns (uint160) {
        return DiggerV3.getSqrtRatioAtTick(_cfg().START_TICK());
    }

    // ----------------------------------------------------------- slot plumbing

    /// @notice Bound Diggers cast to the config+extsload surface.
    /// @return Launchpad as {IDiggersConfig}.
    function _cfg() private view returns (IDiggersConfig) {
        return IDiggersConfig(DIGGERS);
    }

    /// @notice One raw storage slot of the launchpad.
    /// @param slot Storage slot to read via Diggers.extsload.
    /// @return Raw 32-byte contents.
    function _sload(bytes32 slot) private view returns (bytes32) {
        return _cfg().extsload(slot);
    }

    /// @notice Value slot of `mapping(address => ...)` at `base` for `key`.
    /// @param key Mapping key (token address, etc.).
    /// @param base Declared storage slot of the mapping.
    /// @return keccak256(abi.encode(key, base)).
    function _slotOf(address key, uint256 base) private pure returns (bytes32) {
        return keccak256(abi.encode(key, base));
    }

    /// @notice Value slot of `mapping(bytes32 => ...)` at `base` for `key`.
    /// @param key Mapping key (folded name/symbol).
    /// @param base Declared storage slot of the mapping.
    /// @return keccak256(abi.encode(key, base)).
    function _slotOf(bytes32 key, uint256 base) private pure returns (bytes32) {
        return keccak256(abi.encode(key, base));
    }

    /// @notice Whether Diggers' `isDiggersToken` mapping marks `token` as launched here.
    /// @param token Address to check.
    /// @return True if the raw slot is nonzero.
    function _isToken(address token) private view returns (bool) {
        return _sload(_slotOf(token, SLOT_IS_TOKEN)) != bytes32(0);
    }

    /// @notice Reverts {IDiggers.UnknownToken} when `token` was not launched by Diggers.
    /// @param token Address that must be a DiggersToken clone.
    function _requireToken(address token) private view {
        if (!_isToken(token)) revert IDiggers.UnknownToken();
    }

    /// @notice Decodes a TokenRecord from its three Diggers slots.
    /// @dev Layout: creator | pool+ticks+fee packed | burnShareWad.
    /// @param token Launched DiggersToken.
    /// @return rec On-chain {IDiggers.TokenRecord}.
    function _recordOf(address token) private view returns (IDiggers.TokenRecord memory rec) {
        bytes32 base = _slotOf(token, SLOT_TOKEN_RECORDS);
        rec.creator = address(uint160(uint256(_sload(base))));
        uint256 packed = uint256(_sload(bytes32(uint256(base) + 1)));
        rec.pool = address(uint160(packed));
        rec.tickLower = int24(uint24(packed >> 160));
        rec.tickUpper = int24(uint24(packed >> 184));
        rec.poolFee = uint24(packed >> 208);
        rec.burnShareWad = uint128(uint256(_sload(bytes32(uint256(base) + 2))));
    }

    /// @notice Loads a token's folded name + symbol registry keys from Diggers storage.
    /// @param token Launched DiggersToken.
    /// @return k `{nameKey, symbolKey}` pair.
    function _tokenKeysOf(address token) private view returns (IDiggers.TokenKeys memory k) {
        bytes32 base = _slotOf(token, SLOT_TOKEN_KEYS);
        k.nameKey = _sload(base);
        k.symbolKey = _sload(bytes32(uint256(base) + 1));
    }

    /// @notice Active creator fee-split row count for `token` (Diggers storage).
    /// @param token Launched DiggersToken.
    /// @return Number of active fee-split rows.
    function _feeSplitCountOf(address token) private view returns (uint8) {
        return uint8(uint256(_sload(_slotOf(token, SLOT_FEE_SPLIT_COUNT))));
    }
}
