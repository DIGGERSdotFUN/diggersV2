// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggersRouterV2
 * @notice Chain-agnostic universal quote<->token swap router that skims a small
 *         quote-side fee to the team treasury. One contract serves every AMM family the
 *         rescued/partner tokens live on — Uniswap V2 pairs, V3 pools, and V4 hookless
 *         pools — and one codebase deploys on every chain: ETH/L2 chains quoting in an
 *         18-dec WETH9, and USD-native chains (Stable) whose gas token is a dual-native
 *         ERC20 with non-18 decimals (USDT0, 6). The external surface is always native
 *         wei; the quote side converts to pool units internally, exactly like the
 *         Diggers launchpad does.
 *
 *         Venue addresses are a set-once registry instead of immutables: each of the
 *         Uniswap V2 factory, V3 factory, and V4 PoolManager can be pinned exactly once,
 *         either at deploy or later by the owner. A chain where V4 has not shipped yet
 *         (Stable today) deploys with V2/V3 only — the V4 code is already integrated and
 *         arms the moment the PoolManager address lands. Once set, a venue can never be
 *         changed or removed.
 *
 *         The router is deliberately standalone: it shares no state with the Diggers
 *         launchpad or its tokens, holds no positions, and can be abandoned by sweeping
 *         its last fees and pointing the UI elsewhere. Ownership is config-only — the
 *         owner may tune the fee within a hard cap, fill still-empty venue slots, rotate
 *         the fee recipient, and transfer/renounce; it has no power over user funds.
 * @author BasedDopamine
 */
import {DiggerMath} from "./libs/DiggerMath.sol";
import {DiggerV3, IUniswapV3Pool, IUniswapV3Factory, IWETH9} from "./libs/DiggerV3.sol";
import {IDiggersRouterV2} from "./interfaces/IDiggersRouterV2.sol";

/// @dev Minimal ERC20 surface the router pulls and pays through.
interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Uniswap V2 pair surface: reserves + the low-level swap.
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

/// @dev Uniswap V2 factory canonical-pair lookup.
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @dev Minimal slice of the Uniswap V4 PoolManager ABI used by the router. Struct
///      shapes are canonical Uniswap layouts — poolId = keccak256(abi.encode(PoolKey)).
interface IPoolManagerV4 {
    /// @dev Uniquely identifies a pool. The router only touches hookless native/token
    ///      pools, so currency0 is always address(0) and hooks always address(0).
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @dev Arguments to swap. Negative amountSpecified = exact input.
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    /// @dev Native value settles with value; ERC20 settles after sync + transfer.
    function settle() external payable returns (uint256);

    function sync(address currency) external;

    function take(address currency, address to, uint256 amount) external;

    /// @dev Raw storage read (EIP-2330); backbone of the post-swap state views here.
    function extsload(bytes32 slot) external view returns (bytes32);
}

contract DiggersRouterV2 is IDiggersRouterV2 {
    // -------------------------------------------------- constants / immutables

    /// @notice 1e18 == 100%. Fees are 1e18-scaled, never bps.
    uint256 public constant WAD = 1e18;

    /// @notice Hard ceiling the owner can never exceed: 10% (1e18-scaled).
    uint256 public constant MAX_FEE_WAD = 1e17;

    /// @dev V2 pool fee numerator/denominator (0.3% => keep 99.7% of input).
    uint256 private constant V2_FEE_NUM = 997;
    uint256 private constant V2_FEE_DEN = 1000;

    /// @dev V4 PoolManager storage: index of the pools mapping (StateLibrary.POOLS_SLOT)
    ///      and the liquidity offset within Pool.State.
    bytes32 private constant V4_POOLS_SLOT = bytes32(uint256(6));
    uint256 private constant V4_OFFSET_LIQUIDITY = 3;

    /// @dev EIP-1153 transient slots: a reentrancy latch and the expected V3 callback
    ///      pool. Router-V2-domained strings keep them distinct from any other lineage.
    bytes32 private constant REENTRANCY_SLOT = keccak256("diggers.router2.reentrancy");
    bytes32 private constant V3_CALLBACK_SLOT = keccak256("diggers.router2.v3callbackPool");

    /// @inheritdoc IDiggersRouterV2
    address public immutable QUOTE;

    /// @inheritdoc IDiggersRouterV2
    uint256 public immutable QUOTE_SCALE;

    /// @inheritdoc IDiggersRouterV2
    bool public immutable DUAL_NATIVE;

    // ---------------------------------------------------------------- storage

    /// @notice Set-once Uniswap V2 factory (address(0) = the V2 leg is not armed yet).
    address public v2Factory;

    /// @notice Set-once Uniswap V3 factory (address(0) = the V3 leg is not armed yet).
    address public v3Factory;

    /// @notice Set-once Uniswap V4 PoolManager (address(0) = the V4 leg is not armed yet).
    address public poolManager;

    /// @notice Current fee rate (1e18-scaled). Owner-editable up to {MAX_FEE_WAD}.
    uint256 public feeWad;

    /// @notice Owner-rotatable fee recipient; the permissionless {sweep} target.
    address public feeRecipient;

    /// @notice Config owner. Can edit the fee, fill still-empty venue slots, and
    ///         transfer/renounce ownership; nothing else. address(0) once renounced —
    ///         the fee and the venue set are then frozen forever.
    address public owner;

    // ---------------------------------------------------------------- errors

    /// @notice Reentrant entry into a guarded swap.
    error Reentrancy();

    // ------------------------------------------------------------- constructor

    /// @param quote Quote token: WETH9 on ETH-quote chains, the dual-native gas ERC20
    ///        (USDT0) on chains like Stable. Required.
    /// @param quoteDecimals Quote token decimals (<= 18; must be 18 unless dual-native).
    /// @param dualNative True when the quote ERC20 shares one balance with native gas.
    /// @param feeRecipient_ Initial fee recipient (required; owner-rotatable later).
    /// @param owner_ Initial config owner (may be the deployer).
    /// @param initialFeeWad Launch fee rate (1e18-scaled), must be <= {MAX_FEE_WAD}.
    /// @param v2Factory_ Uniswap V2 factory, or address(0) to arm the V2 leg later.
    /// @param v3Factory_ Uniswap V3 factory, or address(0) to arm the V3 leg later.
    /// @param poolManager_ Uniswap V4 PoolManager, or address(0) to arm the V4 leg later
    ///        (the standard deployment shape on chains where V4 has not shipped).
    constructor(
        address quote,
        uint8 quoteDecimals,
        bool dualNative,
        address feeRecipient_,
        address owner_,
        uint256 initialFeeWad,
        address v2Factory_,
        address v3Factory_,
        address poolManager_
    ) {
        if (quote == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (quoteDecimals > 18 || (!dualNative && quoteDecimals != 18)) revert QuoteConfigInvalid();
        if (initialFeeWad > MAX_FEE_WAD) revert FeeTooHigh();

        QUOTE = quote;
        QUOTE_SCALE = 10 ** (18 - quoteDecimals);
        DUAL_NATIVE = dualNative;
        feeRecipient = feeRecipient_;
        feeWad = initialFeeWad;
        owner = owner_;

        if (v2Factory_ != address(0)) {
            v2Factory = v2Factory_;
            emit VenueConfigured(uint8(Venue.V2), v2Factory_);
        }
        if (v3Factory_ != address(0)) {
            v3Factory = v3Factory_;
            emit VenueConfigured(uint8(Venue.V3), v3Factory_);
        }
        if (poolManager_ != address(0)) {
            poolManager = poolManager_;
            emit VenueConfigured(uint8(Venue.V4), poolManager_);
        }

        emit OwnershipTransferred(address(0), owner_);
        emit FeeUpdated(0, initialFeeWad);
        emit FeeRecipientUpdated(address(0), feeRecipient_);
    }

    // ---------------------------------------------------------- receive/fallback

    /// @dev Accept native value only from the quote token (unwrap) and the PoolManager
    ///      (V4 take). Dual-native quote payouts credit the balance at the protocol
    ///      level, so this gate never blocks a legitimate pool payment.
    receive() external payable {
        if (msg.sender != QUOTE && msg.sender != poolManager) revert DirectNativeRejected();
    }

    // ------------------------------------------------------------- modifiers

    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        uint256 locked;
        assembly {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ----------------------------------------------------------- external: trade

    /// @inheritdoc IDiggersRouterV2
    function buy(address token, Venue venue, bytes calldata pool, uint256 minOut, uint256 deadline, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokenAmount)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 fee = (msg.value * feeWad) / WAD;
        uint256 nativeIn = msg.value - fee;

        address poolAddr;
        uint160 sqrtAfter;
        int24 tickAfter;
        uint128 liqAfter;
        uint256 priceWad;
        uint256 quoteNet;

        if (venue == Venue.V4) {
            // V4 pools quote in raw native (currency0 == address(0)) — always wei,
            // regardless of the quote token's ERC20 decimals. No unit conversion.
            IPoolManagerV4.PoolKey memory key = _verifyV4Key(pool, token);
            tokenAmount = _v4Swap(key, true, nativeIn, recipient);
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v4State(key);
            poolAddr = address(0);
            quoteNet = nativeIn;
        } else {
            // V2/V3 pools quote in the quote token's own units. Floor the wei input to
            // units; the sub-unit dust cannot enter the pool and stays with the fees.
            uint256 unitsIn = nativeIn / QUOTE_SCALE;
            if (unitsIn == 0) revert ZeroAmount();
            quoteNet = unitsIn * QUOTE_SCALE;

            // Wrap the input so the swap can pay the pool in the quote ERC20. In
            // dual-native mode the ERC20 transfer spends the native balance directly.
            if (!DUAL_NATIVE) IWETH9(QUOTE).deposit{value: unitsIn}();

            if (venue == Venue.V3) {
                poolAddr = _decodeAddress(pool);
                _verifyV3Pool(poolAddr, token);
                bool zeroForOne = QUOTE < token; // the quote token is the input currency
                tokenAmount = _v3Swap(poolAddr, token, zeroForOne, unitsIn, recipient);
                (sqrtAfter, tickAfter, liqAfter, priceWad) = _v3State(poolAddr, QUOTE < token);
            } else {
                poolAddr = _decodeAddress(pool);
                _verifyV2Pair(poolAddr, token);
                (tokenAmount, priceWad) = _v2Swap(poolAddr, QUOTE, unitsIn, recipient);
            }
        }

        if (tokenAmount < minOut) revert SlippageExceeded();

        emit Swapped(
            msg.sender,
            token,
            poolAddr,
            uint8(venue),
            true,
            msg.value,
            msg.value - quoteNet,
            quoteNet,
            tokenAmount,
            priceWad,
            sqrtAfter,
            tickAfter,
            liqAfter,
            feeWad
        );
    }

    /// @inheritdoc IDiggersRouterV2
    function sell(
        address token,
        Venue venue,
        bytes calldata pool,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external nonReentrant returns (uint256 quoteOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // Pull the tokens to sell (requires prior approval to this router).
        if (!IERC20Min(token).transferFrom(msg.sender, address(this), amountIn)) revert TokenPullFailed();

        address poolAddr;
        uint160 sqrtAfter;
        int24 tickAfter;
        uint128 liqAfter;
        uint256 priceWad;
        uint256 quoteGross;

        if (venue == Venue.V4) {
            IPoolManagerV4.PoolKey memory key = _verifyV4Key(pool, token);
            quoteGross = _v4Swap(key, false, amountIn, address(this));
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v4State(key);
            poolAddr = address(0);
        } else if (venue == Venue.V3) {
            poolAddr = _decodeAddress(pool);
            _verifyV3Pool(poolAddr, token);
            bool zeroForOne = token < QUOTE; // the token is the input currency
            uint256 unitsOut = _v3Swap(poolAddr, token, zeroForOne, amountIn, address(this));
            quoteGross = _unwrapToNative(unitsOut);
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v3State(poolAddr, QUOTE < token);
        } else {
            poolAddr = _decodeAddress(pool);
            _verifyV2Pair(poolAddr, token);
            uint256 unitsOut;
            (unitsOut, priceWad) = _v2Swap(poolAddr, token, amountIn, address(this));
            quoteGross = _unwrapToNative(unitsOut);
        }

        uint256 fee = (quoteGross * feeWad) / WAD;
        quoteOut = quoteGross - fee;
        if (quoteOut < minOut) revert SlippageExceeded();

        _sendNative(recipient, quoteOut);

        emit Swapped(
            msg.sender,
            token,
            poolAddr,
            uint8(venue),
            false,
            quoteGross,
            fee,
            quoteOut,
            amountIn,
            priceWad,
            sqrtAfter,
            tickAfter,
            liqAfter,
            feeWad
        );
    }

    // ------------------------------------------------------------- swap callbacks

    /// @notice Uniswap V3 swap callback: pay the pool the input it is owed.
    /// @dev Fires only during a router-initiated V3 swap. The expected pool is stashed in
    ///      transient storage by {_v3Swap}; any other caller (or a stray direct call)
    ///      reverts. The router pays from its own balance (the wrapped/dual-native quote
    ///      on a buy, the pulled token on a sell), so a spoofed callback could never
    ///      drain it anyway.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        bytes32 slot = V3_CALLBACK_SLOT;
        address expected;
        assembly {
            expected := tload(slot)
        }
        if (expected == address(0) || msg.sender != expected) revert UnauthorizedCallback();

        // Pay whichever side is owed (positive delta), in that side's pool currency.
        if (amount0Delta > 0) {
            _payPool(msg.sender, IUniswapV3Pool(msg.sender).token0(), uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            _payPool(msg.sender, IUniswapV3Pool(msg.sender).token1(), uint256(amount1Delta));
        }
        // silence unused warning on data (the bound token is derivable from the pool)
        data;
    }

    /// @notice Uniswap V4 unlock callback: run the swap, settle input, take output.
    /// @dev Only the PoolManager may call. Native (currency0) settles with value, the
    ///      ERC20 side syncs + transfers + settles, and the output is taken straight to
    ///      the recipient encoded in the unlock payload.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // An unset poolManager (address(0)) can never equal a real msg.sender, so the
        // gate also covers the venue-not-armed case.
        if (msg.sender != poolManager) revert UnauthorizedCallback();

        (IPoolManagerV4.PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient) =
            abi.decode(data, (IPoolManagerV4.PoolKey, bool, uint256, address));

        uint160 limit = zeroForOne ? DiggerV3.MIN_SQRT_RATIO + 1 : DiggerV3.MAX_SQRT_RATIO - 1;
        IPoolManagerV4.SwapParams memory params = IPoolManagerV4.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: limit
        });

        int256 swapDelta = IPoolManagerV4(poolManager).swap(key, params, "");
        (int128 delta0, int128 delta1) = _splitDelta(swapDelta);

        if (delta0 < 0) _settleV4(key.currency0, uint256(uint128(-delta0)));
        if (delta1 < 0) _settleV4(key.currency1, uint256(uint128(-delta1)));
        if (delta0 > 0) IPoolManagerV4(poolManager).take(key.currency0, recipient, uint256(uint128(delta0)));
        if (delta1 > 0) IPoolManagerV4(poolManager).take(key.currency1, recipient, uint256(uint128(delta1)));

        return abi.encode(delta0, delta1);
    }

    // ------------------------------------------------------------- external: admin

    /// @inheritdoc IDiggersRouterV2
    function sweep() external returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) return 0;
        address to = feeRecipient;
        _sendNative(to, amount);
        emit FeeSwept(to, amount);
    }

    /// @inheritdoc IDiggersRouterV2
    function setV2Factory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (v2Factory != address(0)) revert VenueLocked();
        v2Factory = factory;
        emit VenueConfigured(uint8(Venue.V2), factory);
    }

    /// @inheritdoc IDiggersRouterV2
    function setV3Factory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (v3Factory != address(0)) revert VenueLocked();
        v3Factory = factory;
        emit VenueConfigured(uint8(Venue.V3), factory);
    }

    /// @inheritdoc IDiggersRouterV2
    function setPoolManager(address manager) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();
        if (poolManager != address(0)) revert VenueLocked();
        poolManager = manager;
        emit VenueConfigured(uint8(Venue.V4), manager);
    }

    /// @inheritdoc IDiggersRouterV2
    function setFeeWad(uint256 newFeeWad) external onlyOwner {
        if (newFeeWad > MAX_FEE_WAD) revert FeeTooHigh();
        uint256 old = feeWad;
        feeWad = newFeeWad;
        emit FeeUpdated(old, newFeeWad);
    }

    /// @inheritdoc IDiggersRouterV2
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @inheritdoc IDiggersRouterV2
    function transferOwnership(address newOwner) external onlyOwner {
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // ---------------------------------------------------------- internal: V3

    /// @dev Initiate a V3 exact-input swap; the callback pays the pool. Output measured
    ///      from the returned deltas. `recipient` receives the output currency directly.
    ///      Quote-side amounts here are pool UNITS, not wei.
    function _v3Swap(address pool, address token, bool zeroForOne, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut)
    {
        bytes32 slot = V3_CALLBACK_SLOT;
        assembly {
            tstore(slot, pool)
        }

        uint160 limit = zeroForOne ? DiggerV3.MIN_SQRT_RATIO + 1 : DiggerV3.MAX_SQRT_RATIO - 1;
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(recipient, zeroForOne, int256(amountIn), limit, abi.encode(token));

        assembly {
            tstore(slot, 0)
        }

        int256 out = zeroForOne ? amount1 : amount0;
        amountOut = out < 0 ? uint256(-out) : 0;
    }

    /// @dev Verify `pool` is the canonical V3 pool for (quote, token) at its own fee
    ///      tier. Reverts if the V3 leg is not armed.
    function _verifyV3Pool(address pool, address token) internal view {
        if (v3Factory == address(0)) revert BadVenue();
        if (pool == address(0) || pool.code.length == 0) revert NoPool();
        uint24 poolFee = IUniswapV3Pool(pool).fee();
        if (IUniswapV3Factory(v3Factory).getPool(QUOTE, token, poolFee) != pool) revert NoPool();
    }

    /// @dev Post-swap V3 state for the event: sqrtPrice, tick, liquidity, spot price wad.
    function _v3State(address pool, bool quoteIsToken0)
        internal
        view
        returns (uint160 sqrtAfter, int24 tickAfter, uint128 liqAfter, uint256 priceWad)
    {
        (sqrtAfter, tickAfter,,,,,) = IUniswapV3Pool(pool).slot0();
        liqAfter = IUniswapV3Pool(pool).liquidity();
        priceWad = _priceQuotePerTokenWad(sqrtAfter, quoteIsToken0, QUOTE_SCALE);
    }

    /// @dev Pay `amount` of `currency` from the router's balance to the calling pool.
    ///      In dual-native mode paying the quote ERC20 debits the native balance.
    function _payPool(address pool, address currency, uint256 amount) internal {
        if (!IERC20Min(currency).transfer(pool, amount)) revert Erc20TransferFailed();
    }

    // ---------------------------------------------------------- internal: V2

    /// @dev Constant-product swap on a V2 pair. `tokenIn` is the quote token or the sold
    ///      token in the order of the trade; quote-side amounts are pool UNITS. Transfers
    ///      the input to the pair, then pulls the output.
    function _v2Swap(address pair, address tokenIn, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut, uint256 priceWad)
    {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveIn, uint256 reserveOut) = tokenIn == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert NoPool();

        uint256 amountInWithFee = amountIn * V2_FEE_NUM;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * V2_FEE_DEN + amountInWithFee);
        if (amountOut == 0) revert SlippageExceeded();

        if (!IERC20Min(tokenIn).transfer(pair, amountIn)) revert Erc20TransferFailed();
        (uint256 amount0Out, uint256 amount1Out) =
            tokenIn == t0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, recipient, "");

        // Post-swap spot: quote reserve (wei-normalized) * 1e18 / token reserve.
        (uint112 a0, uint112 a1,) = IUniswapV2Pair(pair).getReserves();
        (uint256 resQuote, uint256 resToken) =
            QUOTE == t0 ? (uint256(a0), uint256(a1)) : (uint256(a1), uint256(a0));
        priceWad = resToken == 0 ? 0 : (resQuote * QUOTE_SCALE * WAD) / resToken;
    }

    /// @dev Verify `pair` is the canonical V2 pair for (quote, token). Reverts if the V2
    ///      leg is not armed.
    function _verifyV2Pair(address pair, address token) internal view {
        if (v2Factory == address(0)) revert BadVenue();
        if (pair == address(0)) revert NoPool();
        if (IUniswapV2Factory(v2Factory).getPair(QUOTE, token) != pair) revert NoPool();
    }

    // ---------------------------------------------------------- internal: V4

    /// @dev Validate + decode the user-supplied V4 pool key. The leg must be armed,
    ///      native must be currency0, `token` must be currency1 (so the Swapped event can
    ///      never carry a token that differs from the pool actually traded — indexer
    ///      poisoning), and the pool must be hookless (router scope, and a hook contract
    ///      is an arbitrary-code re-entry surface we refuse to touch).
    function _verifyV4Key(bytes calldata pool, address token)
        internal
        view
        returns (IPoolManagerV4.PoolKey memory key)
    {
        if (poolManager == address(0)) revert BadVenue();
        key = abi.decode(pool, (IPoolManagerV4.PoolKey));
        if (key.currency0 != address(0) || key.currency1 != token || key.hooks != address(0)) {
            revert NoPool();
        }
    }

    /// @dev Initiate a V4 swap through the PoolManager unlock. Output measured from the
    ///      returned deltas; settlement rides the router balance inside the callback.
    ///      V4 native amounts are already wei — no unit conversion on this leg.
    function _v4Swap(IPoolManagerV4.PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut)
    {
        bytes memory answer = IPoolManagerV4(poolManager).unlock(abi.encode(key, zeroForOne, amountIn, recipient));
        (int128 delta0, int128 delta1) = abi.decode(answer, (int128, int128));
        int128 out = zeroForOne ? delta1 : delta0;
        amountOut = out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @dev Post-swap V4 state for the event, read straight from PoolManager storage.
    function _v4State(IPoolManagerV4.PoolKey memory key)
        internal
        view
        returns (uint160 sqrtAfter, int24 tickAfter, uint128 liqAfter, uint256 priceWad)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, V4_POOLS_SLOT));
        bytes32 raw = IPoolManagerV4(poolManager).extsload(stateSlot);
        assembly {
            sqrtAfter := and(raw, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            tickAfter := signextend(2, shr(160, raw))
        }
        liqAfter = uint128(
            uint256(IPoolManagerV4(poolManager).extsload(bytes32(uint256(stateSlot) + V4_OFFSET_LIQUIDITY)))
        );
        // Native is currency0 in every router-scope V4 pool and is denominated in wei,
        // so the price needs no quote-decimals adjustment (scale 1).
        priceWad = _priceQuotePerTokenWad(sqrtAfter, true, 1);
    }

    /// @dev Pay a negative V4 delta to the PoolManager (native via value; ERC20 via
    ///      sync -> transfer -> settle).
    function _settleV4(address currency, uint256 amount) internal {
        if (currency == address(0)) {
            IPoolManagerV4(poolManager).settle{value: amount}();
        } else {
            IPoolManagerV4(poolManager).sync(currency);
            if (!IERC20Min(currency).transfer(poolManager, amount)) revert Erc20TransferFailed();
            IPoolManagerV4(poolManager).settle();
        }
    }

    /// @dev Split a packed V4 BalanceDelta: currency0 high 128 bits, currency1 low 128.
    function _splitDelta(int256 delta) internal pure returns (int128 amount0, int128 amount1) {
        assembly {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }

    // ------------------------------------------------------------- internal: misc

    /// @dev Bring a quote-side pool payout back to the native surface: unwrap when a real
    ///      wrapper exists (a dual-native payout already credited the native balance) and
    ///      normalize units to wei.
    function _unwrapToNative(uint256 units) internal returns (uint256 wei_) {
        if (units > 0 && !DUAL_NATIVE) IWETH9(QUOTE).withdraw(units);
        wei_ = units * QUOTE_SCALE;
    }

    /// @dev Spot native wei per 1e18 token base units (wad), from a sqrt price. `scale`
    ///      is the wei-per-pool-unit factor of the quote side (QUOTE_SCALE on V2/V3
    ///      pools, 1 on V4 native pools). Token side is treated as raw base units;
    ///      off-chain consumers decimal-adjust non-18-dec tokens for display.
    function _priceQuotePerTokenWad(uint160 sqrtPriceX96, bool quoteIsToken0, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        if (sqrtPriceX96 == 0) return 0;
        uint256 sp = uint256(sqrtPriceX96);
        if (quoteIsToken0) {
            // Quote is token0: quote per token = (2^96 / sqrtP)^2, scaled by 1e18 · scale.
            uint256 r = DiggerMath.md512(WAD * scale, DiggerV3.Q96, sp);
            return DiggerMath.md512(r, DiggerV3.Q96, sp);
        } else {
            // Quote is token1: quote per token = (sqrtP / 2^96)^2, scaled by 1e18 · scale.
            uint256 r = DiggerMath.md512(WAD * scale, sp, DiggerV3.Q96);
            return DiggerMath.md512(r, sp, DiggerV3.Q96);
        }
    }

    /// @dev Decode an abi-encoded single address (V2/V3 `pool` calldata).
    function _decodeAddress(bytes calldata data) internal pure returns (address) {
        return abi.decode(data, (address));
    }

    /// @dev Send raw native value, bubbling a clean error on failure.
    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IDiggersRouterV2
    function pendingFees() external view returns (uint256) {
        return address(this).balance;
    }

    /// @inheritdoc IDiggersRouterV2
    function poolFor(address token, uint24 feeTier) external view returns (address) {
        if (v3Factory == address(0)) return address(0);
        return IUniswapV3Factory(v3Factory).getPool(QUOTE, token, feeTier);
    }
}
