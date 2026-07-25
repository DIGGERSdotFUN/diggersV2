// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";
import {DiggerV3, IUniswapV3Factory, IUniswapV3Pool} from "./DiggerV3.sol";
import {DiggerLaunchLiquidity} from "./DiggerLaunchLiquidity.sol";
import {DiggersToken} from "../DiggersToken.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";
import {IDiggersHub} from "../interfaces/IDiggersHub.sol";

/**
 * @title DiggerCreateLib
 * @notice Launch orchestration executed via `delegatecall` from `Diggers`. Tokens are
 *         deployed as 45-byte EIP-1167 minimal proxies of the launchpad's single
 *         DiggersToken implementation; the CREATE2 salt is GROUND so the clone address is
 *         strictly greater than WETH, guaranteeing WETH is token0 of the pool (which keeps
 *         all the price/liquidity math identical to the V4 edition). The launchpad then
 *         creates + initializes the WETH/token 1% V3 pool, arms the clone with the pool
 *         address, and seeds the full supply single-sided below spot.
 * @dev Runs in Diggers' context: `address(this)` is the launchpad, so CREATE2 addresses,
 *      storage writes, and the transient mint-callback slot resolve as if `create` ran
 *      inline. The seed calls `pool.mint` directly; the callback returns to the launchpad's
 *      `uniswapV3MintCallback` (a fresh call) which pays the owed token1 from the supply.
 *      Post-launch edits ({updateTokenomics}, {updateFeeSplits}) share the same storage-
 *      pointer pattern so the Diggers singleton stays lean.
 * @author BasedDopamine
 */
library DiggerCreateLib {
    uint256 private constant WAD = 1e18;
    uint256 private constant TOKEN_SUPPLY = 1_000_000_000e18;
    int24 private constant POOL_TICK_SPACING = 200;
    uint24 private constant POOL_FEE = 10000; // forced 1%

    /// @dev Hard cap on creator fee-split rows (keeps harvest bounded).
    uint256 private constant MAX_FEE_SPLITS = 10;

    /**
     * @dev EIP-1153 mint-callback slot — must match DiggerV3Base._callbackPoolSlot().
     * @return Transient storage key for the authorized callback pool.
     */
    function _callbackPoolSlot() private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), "diggers.v3.callbackPool"));
    }

    /**
     * @notice Deploys a token (salt-ground so WETH < token), creates + seeds its V3 pool,
     *         records the per-token config, and writes the initial creator fee-split table.
     * @param isDiggersToken Registry-of-tokens flag map (storage pointer).
     * @param tokenRecords Per-token pool record map (storage pointer).
     * @param feeSplitCount Per-token fee-split row count map (storage pointer).
     * @param feeSplits Per-token fee-split table map (storage pointer).
     * @param creatorBuybackWad Per-token ETH-side buyback carve map (storage pointer).
     * @param glueShares Per-token Glue share pack map (storage pointer).
     * @param v3Factory Uniswap V3 factory.
     * @param weth Wrapped-native token (token0 of every pool).
     * @param startTick Spacing-aligned launch tick.
     * @param nonce Current CREATE2 salt nonce.
     * @param glueActive Whether Glue integration has been owner-activated.
     * @param params Identity + burn-share config for the launch.
     * @param feeSplitsIn Creator ETH fee-share table (empty ⇒ default `[{creator, 1e18}]`).
     * @param tokenImplementation The shared DiggersToken implementation to clone.
     * @param hub DiggersHub event singleton.
     * @return token Address of the new DiggersToken clone.
     */
    function create(
        mapping(address => bool) storage isDiggersToken,
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        mapping(address => uint256) storage creatorBuybackWad,
        mapping(address => IDiggers.GlueShares) storage glueShares,
        address v3Factory,
        address weth,
        int24 startTick,
        uint256 nonce,
        bool glueActive,
        IDiggers.TokenParams memory params,
        IDiggers.FeeSplit[] memory feeSplitsIn,
        address tokenImplementation,
        address hub
    ) external returns (address token) {
        return _run(
            isDiggersToken,
            tokenRecords,
            feeSplitCount,
            feeSplits,
            creatorBuybackWad,
            glueShares,
            v3Factory,
            weth,
            startTick,
            nonce,
            glueActive,
            params,
            feeSplitsIn,
            tokenImplementation,
            hub
        );
    }

    /**
     * @notice The minimal-create counterpart of {create}: builds the STANDARD launch
     *         params here (50% burn / 50% daily pot / 0% staking, no buyback, no glue)
     *         so the singleton never assembles the struct — bytecode lives on this lib.
     * @param isDiggersToken Registry-of-tokens flag map (storage pointer).
     * @param tokenRecords Per-token pool record map (storage pointer).
     * @param feeSplitCount Per-token fee-split row count map (storage pointer).
     * @param feeSplits Per-token fee-split table map (storage pointer).
     * @param creatorBuybackWad Per-token ETH-side buyback carve map (storage pointer).
     * @param glueShares Per-token Glue share pack map (storage pointer).
     * @param v3Factory Uniswap V3 factory.
     * @param weth Wrapped-native token (token0 of every pool).
     * @param startTick Spacing-aligned launch tick.
     * @param nonce Current CREATE2 salt nonce.
     * @param name Token name (charset-validated by the Diggers caller before entry).
     * @param symbol Token symbol (charset-validated by the Diggers caller before entry).
     * @param metadataURI Off-chain metadata URI (non-empty).
     * @param tokenImplementation The shared DiggersToken implementation to clone.
     * @param hub DiggersHub event singleton.
     * @return token Address of the new DiggersToken clone.
     */
    function createStandard(
        mapping(address => bool) storage isDiggersToken,
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        mapping(address => uint256) storage creatorBuybackWad,
        mapping(address => IDiggers.GlueShares) storage glueShares,
        address v3Factory,
        address weth,
        int24 startTick,
        uint256 nonce,
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        address tokenImplementation,
        address hub
    ) external returns (address token) {
        IDiggers.TokenParams memory params;
        params.name = name;
        params.symbol = symbol;
        params.metadataURI = metadataURI;
        params.burnShareWad = 5e17;
        return _run(
            isDiggersToken,
            tokenRecords,
            feeSplitCount,
            feeSplits,
            creatorBuybackWad,
            glueShares,
            v3Factory,
            weth,
            startTick,
            nonce,
            false,
            params,
            new IDiggers.FeeSplit[](0),
            tokenImplementation,
            hub
        );
    }

    /**
     * @dev Shared launch body of the two external entries.
     * @param isDiggersToken Registry-of-tokens flag map (storage pointer).
     * @param tokenRecords Per-token pool record map (storage pointer).
     * @param feeSplitCount Per-token fee-split row count map (storage pointer).
     * @param feeSplits Per-token fee-split table map (storage pointer).
     * @param creatorBuybackWad Per-token ETH-side buyback carve map (storage pointer).
     * @param glueShares Per-token Glue share pack map (storage pointer).
     * @param v3Factory Uniswap V3 factory.
     * @param weth Wrapped-native token (token0 of every pool).
     * @param startTick Spacing-aligned launch tick.
     * @param nonce Current CREATE2 salt nonce.
     * @param glueActive Whether Glue integration has been owner-activated.
     * @param params Identity + tokenomics config for the launch.
     * @param feeSplitsIn Creator ETH fee-share table (empty ⇒ default whole-to-creator).
     * @param tokenImplementation The shared DiggersToken implementation to clone.
     * @param hub DiggersHub event singleton.
     * @return token Address of the new DiggersToken clone.
     */
    function _run(
        mapping(address => bool) storage isDiggersToken,
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        mapping(address => uint256) storage creatorBuybackWad,
        mapping(address => IDiggers.GlueShares) storage glueShares,
        address v3Factory,
        address weth,
        int24 startTick,
        uint256 nonce,
        bool glueActive,
        IDiggers.TokenParams memory params,
        IDiggers.FeeSplit[] memory feeSplitsIn,
        address tokenImplementation,
        address hub
    ) private returns (address token) {
        _validate(params, glueActive);
        token = _deploy(isDiggersToken, weth, params, nonce, tokenImplementation, hub);
        _writeFeeSplits(feeSplitCount, feeSplits, token, feeSplitsIn, hub);
        _seedAndEmit(tokenRecords, v3Factory, weth, startTick, token, params, hub);
        _storeTokenomics(
            tokenRecords,
            creatorBuybackWad,
            glueShares,
            token,
            params.buybackShareWad,
            params.backingShareWad,
            params.stakingShareWad,
            params.burnShareWad,
            params.stakeShareWad,
            hub
        );
    }

    /**
     * @dev Creates + initializes the pool, arms the clone, seeds the supply, writes the
     *      record, and emits `Created`.
     * @param tokenRecords Per-token pool record map (storage pointer).
     * @param v3Factory Uniswap V3 factory.
     * @param weth Wrapped-native token (token0).
     * @param startTick Spacing-aligned launch tick (position upper bound / spot).
     * @param token Fresh DiggersToken clone address.
     * @param params Identity + burn-share config (name/symbol/URI used at initialize).
     * @param hub DiggersHub event singleton.
     */
    function _seedAndEmit(
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        address v3Factory,
        address weth,
        int24 startTick,
        address token,
        IDiggers.TokenParams memory params,
        address hub
    ) private {
        uint160 startSqrt = DiggerV3.getSqrtRatioAtTick(startTick);

        // Create + initialize the WETH/token 1% pool (WETH < token ⇒ token0 == WETH).
        address pool = IUniswapV3Factory(v3Factory).getPool(weth, token, POOL_FEE);
        if (pool == address(0)) pool = IUniswapV3Factory(v3Factory).createPool(weth, token, POOL_FEE);
        if (DiggerV3.isPoolInitialized(pool)) revert IDiggers.PoolAlreadyInitialized();
        IUniswapV3Pool(pool).initialize(startSqrt);

        // Arm the clone with the pool binding — this mints the full supply to the launchpad.
        DiggersToken(payable(token)).initialize(params.name, params.symbol, params.metadataURI, pool);

        // Seed the full supply single-sided over [floorTick, startTick].
        (int24 floorTick,) = DiggerV3.fullRangeTicks(POOL_TICK_SPACING);
        _seed(pool, token, floorTick, startTick);

        // Sweep any uint128-liquidity rounding dust to the pool so the launchpad holds zero.
        uint256 leftover = DiggersToken(payable(token)).balanceOf(address(this));
        if (leftover > 0) DiggersToken(payable(token)).transfer(pool, leftover);
        if (DiggersToken(payable(token)).balanceOf(address(this)) != 0) {
            revert IDiggers.SeedIncomplete(0, DiggersToken(payable(token)).balanceOf(address(this)));
        }

        tokenRecords[token] = IDiggers.TokenRecord({
            creator: msg.sender,
            pool: pool,
            tickLower: floorTick,
            tickUpper: startTick,
            poolFee: POOL_FEE,
            burnShareWad: uint128(params.burnShareWad)
        });

        IDiggersHub(hub).logCreated(
            token,
            msg.sender,
            params.name,
            params.symbol,
            params.metadataURI,
            pool,
            startSqrt,
            POOL_FEE,
            uint128(params.burnShareWad)
        );
    }

    /**
     * @dev Non-empty identity strings + both tokenomics sum rules. The LP fee is forced
     *      to 1%.
     * @param params Launch identity + tokenomics shares.
     * @param glueActive Whether Glue shares may be nonzero.
     */
    function _validate(IDiggers.TokenParams memory params, bool glueActive) private pure {
        if (bytes(params.name).length == 0) revert IDiggers.NameRequired();
        if (bytes(params.symbol).length == 0) revert IDiggers.SymbolRequired();
        if (bytes(params.metadataURI).length == 0) revert IDiggers.MetadataRequired();
        _validateTokenomics(
            glueActive,
            params.buybackShareWad,
            params.backingShareWad,
            params.stakingShareWad,
            params.burnShareWad,
            params.stakeShareWad
        );
    }

    /**
     * @dev The two tokenomics sum rules, deliberately SEPARATE (never mixed):
     *      ETH side — `buyback + backing + staking <= 1e18`; whatever is left of the
     *      fresh creator slice goes to the fee-split rows, so under-100% is fine.
     *      Token side — `burn + stake <= 1e18`; the daily airdrop pot takes the EXACT
     *      remainder, so the three always total 100% by construction.
     *      Glue gate — until the owner one-shot-activates Glue, every glue share
     *      (backing, staking, stake) must be zero, on create AND on edit.
     * @param glueActive Whether Glue integration is live.
     * @param buybackWad ETH-side buyback carve (1e18-scaled).
     * @param backingWad ETH-side Glue NAV-backing carve (1e18-scaled).
     * @param stakingWad ETH-side Glue staking carve (1e18-scaled).
     * @param burnWad Token-side burn share (1e18-scaled).
     * @param stakeWad Token-side Glue staking share (1e18-scaled).
     */
    function _validateTokenomics(
        bool glueActive,
        uint256 buybackWad,
        uint256 backingWad,
        uint256 stakingWad,
        uint256 burnWad,
        uint256 stakeWad
    ) private pure {
        if (!glueActive && (backingWad | stakingWad | stakeWad) != 0) revert IDiggers.GlueNotActive();
        if (buybackWad + backingWad + stakingWad > WAD) revert IDiggers.TokenomicsInvalid();
        if (burnWad + stakeWad > WAD) revert IDiggers.TokenomicsInvalid();
    }

    /**
     * @dev Writes the full tokenomics config (burn share on the record, buyback redirect,
     *      packed glue shares) and emits the single indexer event. Values are pre-validated.
     * @param tokenRecords Per-token pool record map (burn share written here).
     * @param creatorBuybackWad Per-token buyback carve map.
     * @param glueShares Per-token Glue share pack map.
     * @param token Token whose tokenomics are being stored.
     * @param buybackWad ETH-side buyback carve (1e18-scaled).
     * @param backingWad ETH-side Glue NAV-backing carve (1e18-scaled).
     * @param stakingWad ETH-side Glue staking carve (1e18-scaled).
     * @param burnWad Token-side burn share (1e18-scaled).
     * @param stakeWad Token-side Glue staking share (1e18-scaled).
     * @param hub DiggersHub event singleton.
     */
    function _storeTokenomics(
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        mapping(address => uint256) storage creatorBuybackWad,
        mapping(address => IDiggers.GlueShares) storage glueShares,
        address token,
        uint256 buybackWad,
        uint256 backingWad,
        uint256 stakingWad,
        uint256 burnWad,
        uint256 stakeWad,
        address hub
    ) private {
        tokenRecords[token].burnShareWad = uint128(burnWad);
        creatorBuybackWad[token] = buybackWad;
        glueShares[token] =
            IDiggers.GlueShares({backingWad: uint64(backingWad), stakingWad: uint64(stakingWad), stakeWad: uint64(stakeWad)});
        IDiggersHub(hub).logTokenomicsUpdated(token, buybackWad, backingWad, stakingWad, burnWad, stakeWad);
    }

    /**
     * @notice Replaces a token's WHOLE tokenomics config post-launch (auth checked by the
     *         caller — `Diggers.setTokenomics`, burn-owner-gated). Runs via `delegatecall`.
     * @param tokenRecords Per-token pool record map (storage pointer).
     * @param creatorBuybackWad Per-token buyback carve map (storage pointer).
     * @param glueShares Per-token Glue share pack map (storage pointer).
     * @param token Token whose tokenomics are being replaced.
     * @param glueActive Whether Glue shares may be nonzero.
     * @param buybackWad ETH-side buyback carve (1e18-scaled).
     * @param backingWad ETH-side Glue NAV-backing carve (1e18-scaled).
     * @param stakingWad ETH-side Glue staking carve (1e18-scaled).
     * @param burnWad Token-side burn share (1e18-scaled).
     * @param stakeWad Token-side Glue staking share (1e18-scaled).
     * @param hub DiggersHub event singleton.
     */
    function updateTokenomics(
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        mapping(address => uint256) storage creatorBuybackWad,
        mapping(address => IDiggers.GlueShares) storage glueShares,
        address token,
        bool glueActive,
        uint256 buybackWad,
        uint256 backingWad,
        uint256 stakingWad,
        uint256 burnWad,
        uint256 stakeWad,
        address hub
    ) external {
        _validateTokenomics(glueActive, buybackWad, backingWad, stakingWad, burnWad, stakeWad);
        _storeTokenomics(
            tokenRecords, creatorBuybackWad, glueShares, token, buybackWad, backingWad, stakingWad, burnWad, stakeWad,
            hub
        );
    }

    /**
     * @dev CREATE2-deploys an EIP-1167 minimal proxy, GRINDING the salt so the clone
     *      address is strictly greater than WETH (⇒ WETH is token0). Then registers it.
     *      The clone is armed with `initialize` later, once its pool exists.
     * @param isDiggersToken Registry-of-tokens flag map (storage pointer).
     * @param weth Quote token address used as the salt-grind lower bound.
     * @param params Launch identity (symbol enters the salt hash).
     * @param nonce CREATE2 salt nonce from Diggers.
     * @param tokenImplementation Shared DiggersToken implementation to clone.
     * @param hub DiggersHub event singleton (clone admitted via {register}).
     * @return token Deployed clone address (`> weth`).
     */
    function _deploy(
        mapping(address => bool) storage isDiggersToken,
        address weth,
        IDiggers.TokenParams memory params,
        uint256 nonce,
        address tokenImplementation,
        address hub
    ) private returns (address token) {
        bytes memory initcode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            tokenImplementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initcodeHash = keccak256(initcode);

        // Grind an extra salt word until the predicted clone address exceeds WETH. Clone
        // addresses are effectively uniform, so this converges in ~1-2 iterations.
        uint256 grind;
        bytes32 salt;
        while (true) {
            salt = keccak256(abi.encode(msg.sender, params.symbol, nonce, grind));
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initcodeHash))))
            );
            if (predicted > weth) break;
            unchecked {
                ++grind;
            }
        }

        assembly ("memory-safe") {
            token := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        if (token == address(0) || token <= weth) revert IDiggers.CloneFailed();

        isDiggersToken[token] = true;
        // Admit the clone to the hub's emitter set so its telemetry can print there.
        // Runs under delegatecall from Diggers, so the hub sees the launchpad calling.
        IDiggersHub(hub).register(token);
    }

    /**
     * @dev Validates and stores the creator fee-split table at create. Empty input
     *      defaults to the whole creator slice going to the creator.
     * @param feeSplitCount Per-token fee-split row count map.
     * @param feeSplits Per-token fee-split table map.
     * @param token Token whose fee-split table is being written.
     * @param feeSplitsIn Caller-supplied rows (empty ⇒ default whole-to-`msg.sender`).
     * @param hub DiggersHub event singleton.
     */
    function _writeFeeSplits(
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address token,
        IDiggers.FeeSplit[] memory feeSplitsIn,
        address hub
    ) private {
        uint256 n = feeSplitsIn.length;
        if (n == 0) {
            feeSplitCount[token] = 1;
            feeSplits[token][0] = IDiggers.FeeSplit({to: msg.sender, share: WAD});

            address[] memory defRecipients = new address[](1);
            uint256[] memory defShares = new uint256[](1);
            defRecipients[0] = msg.sender;
            defShares[0] = WAD;
            IDiggersHub(hub).logFeeSplitConfigured(token, defRecipients, defShares);
            return;
        }
        (address[] memory recipients, uint256[] memory shares) = _storeRows(feeSplitCount, feeSplits, token, feeSplitsIn);
        IDiggersHub(hub).logFeeSplitConfigured(token, recipients, shares);
    }

    /**
     * @notice Replaces a token's creator fee-split table post-launch (auth checked by the
     *         caller — `Diggers.setFeeSplits`). Runs via `delegatecall`.
     * @param feeSplitCount Per-token fee-split row count map (storage pointer).
     * @param feeSplits Per-token fee-split table map (storage pointer).
     * @param token Token whose fee-split table is being replaced.
     * @param rowsIn Non-empty replacement rows (shares must sum to 1e18).
     * @param hub DiggersHub event singleton.
     */
    function updateFeeSplits(
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address token,
        IDiggers.FeeSplit[] calldata rowsIn,
        address hub
    ) external {
        if (rowsIn.length == 0) revert IDiggers.FeeSplitInvalid();
        IDiggers.FeeSplit[] memory rows = rowsIn;
        (address[] memory recipients, uint256[] memory shares) = _storeRows(feeSplitCount, feeSplits, token, rows);
        IDiggersHub(hub).logFeeSplitUpdated(token, recipients, shares);
    }

    /**
     * @dev Shared validate-and-store for a non-empty fee-split table.
     * @param feeSplitCount Per-token fee-split row count map.
     * @param feeSplits Per-token fee-split table map.
     * @param token Token whose rows are being stored.
     * @param rows Non-empty fee-split rows (≤10, nonzero recipients/shares, sum == 1e18).
     * @return recipients Parallel recipient addresses for the indexer event.
     * @return shares Parallel 1e18-scaled shares for the indexer event.
     */
    function _storeRows(
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address token,
        IDiggers.FeeSplit[] memory rows
    ) private returns (address[] memory recipients, uint256[] memory shares) {
        uint256 n = rows.length;
        if (n > MAX_FEE_SPLITS) revert IDiggers.FeeSplitInvalid();

        recipients = new address[](n);
        shares = new uint256[](n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            IDiggers.FeeSplit memory row = rows[i];
            if (row.to == address(0) || row.share == 0) revert IDiggers.FeeSplitInvalid();
            sum += row.share;
            feeSplits[token][i] = row;
            recipients[i] = row.to;
            shares[i] = row.share;
        }
        if (sum != WAD) revert IDiggers.FeeSplitInvalid();

        feeSplitCount[token] = uint8(n);
    }

    /**
     * @dev Single-sided token seed over [tickLower, tickUpper] via a direct pool.mint. The
     *      range is entirely below spot, so the deposit is 100% token1 / 0 WETH. The mint
     *      callback fires on the launchpad and pays the owed token from the minted supply.
     * @param pool Freshly initialized WETH/token pool.
     * @param token DiggersToken clone whose full supply is being seeded.
     * @param tickLower Position lower tick (spacing-aligned floor).
     * @param tickUpper Position upper tick (launch start tick / spot).
     */
    function _seed(address pool, address token, int24 tickLower, int24 tickUpper) private {
        uint160 sqrtLower = DiggerV3.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = DiggerV3.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = DiggerLaunchLiquidity.maxLiquidityForAmount1(sqrtLower, sqrtUpper, TOKEN_SUPPLY);
        if (liquidity == 0) revert IDiggers.SeedIncomplete(TOKEN_SUPPLY, 0);

        bytes32 slot = _callbackPoolSlot();
        assembly {
            tstore(slot, pool)
        }
        (, uint256 tokenUsed) = IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, abi.encode(token));
        assembly {
            tstore(slot, 0)
        }

        if (tokenUsed > TOKEN_SUPPLY) revert IDiggers.SeedIncomplete(TOKEN_SUPPLY, tokenUsed);
    }

    // Lock validation + distribution live on the DiggersLocker (the ID-based lock escrow).
}
