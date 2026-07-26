// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggersRouterV2
 * @notice Interface of the chain-agnostic Diggers swap router V2: a thin quote<->token
 *         trade wrapper over external AMMs (Uniswap V2, V3 and V4 hookless pools) that
 *         skims a small quote-side fee to the team treasury. One codebase deploys on
 *         every chain — ETH/L2 chains with an 18-dec WETH9 as well as USD-native chains
 *         whose gas token is a dual-native ERC20 with non-18 decimals (USDT0 on Stable).
 *         Venue addresses are a set-once registry: a chain without a V4 PoolManager
 *         today deploys with V2/V3 only and arms the V4 leg later, exactly once.
 * @dev Self-contained (no implementation imports) so indexers/frontends can consume it
 *      standalone. Percentages are ALWAYS 1e18-scaled (1e18 == 100%), never bps. All
 *      quote amounts on the external surface are native WEI (18-dec normalized); the
 *      implementation converts to pool units internally on sub-18-dec quote chains.
 * @author BasedDopamine
 */
interface IDiggersRouterV2 {
    // ------------------------------------------------------------------- types

    /// @notice The AMM family a trade routes through. `pool` calldata is an abi-encoded
    ///         pair/pool address for {V2}/{V3}, or an abi-encoded V4 PoolKey for {V4}.
    enum Venue {
        V2,
        V3,
        V4
    }

    // ------------------------------------------------------------------ events

    /// @notice Emitted on every buy and sell, carrying enough post-trade pool state that
    ///         an indexer never needs an RPC follow-up. `sqrtPriceX96After`/`tickAfter`/
    ///         `liquidityAfter` are zero on the V2 leg (V2 has no such state).
    /// @param trader The address that initiated the trade.
    /// @param token The non-quote side of the pair.
    /// @param pool The V2 pair / V3 pool address, or address(0) for V4 (see PoolKey).
    /// @param venue The AMM family used.
    /// @param isBuy True for quote->token, false for token->quote.
    /// @param quoteGross Total native in (buy) or gross native out before fee (sell), wei.
    /// @param quoteFee Router fee retained (wei; on a buy includes any sub-unit dust the
    ///        pool could not accept on sub-18-dec quote chains).
    /// @param quoteNet Native that entered the pool (buy) or was paid to `recipient`
    ///        (sell), wei.
    /// @param tokenAmount Tokens out (buy) or tokens in (sell), raw token units.
    /// @param priceQuotePerTokenWadAfter Post-trade spot native wei per 1e18 token base
    ///        units, 1e18-scaled (decimal-normalized via the quote scale).
    /// @param sqrtPriceX96After Post-trade sqrt price (V3/V4; 0 on V2).
    /// @param tickAfter Post-trade tick (V3/V4; 0 on V2).
    /// @param liquidityAfter Post-trade in-range liquidity (V3/V4; 0 on V2).
    /// @param feeWadUsed The router fee rate applied to this trade (1e18-scaled).
    event Swapped(
        address indexed trader,
        address indexed token,
        address indexed pool,
        uint8 venue,
        bool isBuy,
        uint256 quoteGross,
        uint256 quoteFee,
        uint256 quoteNet,
        uint256 tokenAmount,
        uint256 priceQuotePerTokenWadAfter,
        uint160 sqrtPriceX96After,
        int24 tickAfter,
        uint128 liquidityAfter,
        uint256 feeWadUsed
    );

    /// @notice Emitted when a venue address is configured (constructor or the one-shot
    ///         owner setter). Each venue can only ever fire this once.
    /// @param venue The {Venue} slot that was configured.
    /// @param venueAddress The factory (V2/V3) or PoolManager (V4) address pinned.
    event VenueConfigured(uint8 indexed venue, address indexed venueAddress);

    /// @notice Emitted when accrued native fees are swept to the fee recipient.
    event FeeSwept(address indexed to, uint256 amount);

    /// @notice Emitted when the owner changes the fee rate.
    event FeeUpdated(uint256 oldFeeWad, uint256 newFeeWad);

    /// @notice Emitted when the owner rotates the fee recipient.
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted on ownership transfer/renounce (newOwner == 0 freezes config).
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ------------------------------------------------------------------ errors

    /// @notice `deadline` is in the past.
    error Expired();
    /// @notice Realized output fell below the caller's minimum.
    error SlippageExceeded();
    /// @notice The supplied pool/pair is not a canonical factory pool for this token.
    error NoPool();
    /// @notice `venue` is not configured on this deployment (its address is still zero).
    error BadVenue();
    /// @notice A venue address is already set — venue config is one-shot and immutable.
    error VenueLocked();
    /// @notice `newFeeWad` exceeds the immutable {MAX_FEE_WAD} cap.
    error FeeTooHigh();
    /// @notice Caller is not the current owner.
    error NotOwner();
    /// @notice Quote/token amount of zero supplied where a positive amount is required
    ///         (including a buy too small to reach one pool unit of the quote token).
    error ZeroAmount();
    /// @notice Pulling the sell input from the caller failed (missing approval/balance).
    error TokenPullFailed();
    /// @notice A swap callback fired outside of an in-progress router swap, or from an
    ///         address that is not the expected pool / PoolManager.
    error UnauthorizedCallback();
    /// @notice A raw native transfer failed.
    error NativeTransferFailed();
    /// @notice An ERC20 transfer paying a pool / the PoolManager returned false.
    error Erc20TransferFailed();
    /// @notice `receive()` was hit by an address other than the quote token or the
    ///         PoolManager.
    error DirectNativeRejected();
    /// @notice A constructor/setter address argument was zero where non-zero is required.
    error ZeroAddress();
    /// @notice Quote decimals above 18, or a sub-18-dec quote without dual-native mode
    ///         (a non-1:1 wrapper has no defined deposit semantics — unsupported).
    error QuoteConfigInvalid();

    // --------------------------------------------------------------- functions

    /// @notice Buy `token` with native value, skimming the router fee off `msg.value`.
    /// @dev `msg.sender` pays the native value and is recorded as the `trader`; the
    ///      purchased tokens are delivered to `recipient`.
    /// @param token The token to receive.
    /// @param venue AMM family to route through.
    /// @param pool abi-encoded pool/pair address (V2/V3) or PoolKey (V4).
    /// @param minOut Minimum tokens out (slippage floor); reverts below it.
    /// @param deadline Unix seconds after which the trade reverts.
    /// @param recipient Address that receives the purchased tokens (must be non-zero).
    /// @return tokenAmount Tokens delivered to `recipient`.
    function buy(address token, Venue venue, bytes calldata pool, uint256 minOut, uint256 deadline, address recipient)
        external
        payable
        returns (uint256 tokenAmount);

    /// @notice Sell `token` for native value, skimming the router fee off the output.
    /// @dev Requires a prior ERC20 approval of `amountIn` to this router. `msg.sender`
    ///      supplies the tokens and is recorded as the `trader`; the net native value is
    ///      paid to `recipient`.
    /// @param token The token to sell.
    /// @param venue AMM family to route through.
    /// @param pool abi-encoded pool/pair address (V2/V3) or PoolKey (V4).
    /// @param amountIn Exact token amount to sell.
    /// @param minOut Minimum native wei out after fee (slippage floor).
    /// @param deadline Unix seconds after which the trade reverts.
    /// @param recipient Address that receives the net native value (must be non-zero).
    /// @return quoteOut Native wei paid to `recipient` (net of the router fee).
    function sell(
        address token,
        Venue venue,
        bytes calldata pool,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 quoteOut);

    /// @notice Sweep all accrued native fees to the current {feeRecipient}. Permissionless.
    function sweep() external returns (uint256 amount);

    /// @notice Owner-only, one-shot: pin the Uniswap V2 factory (enables the V2 leg).
    ///         Reverts {VenueLocked} if it was already set at deploy or by a prior call.
    function setV2Factory(address factory) external;

    /// @notice Owner-only, one-shot: pin the Uniswap V3 factory (enables the V3 leg).
    ///         Reverts {VenueLocked} if it was already set at deploy or by a prior call.
    function setV3Factory(address factory) external;

    /// @notice Owner-only, one-shot: pin the Uniswap V4 PoolManager (enables the V4 leg).
    ///         Deploy without it on chains where V4 has not shipped yet, arm it later.
    ///         Reverts {VenueLocked} if it was already set at deploy or by a prior call.
    function setPoolManager(address manager) external;

    /// @notice Owner-only: set the fee rate (1e18-scaled), capped at {MAX_FEE_WAD}.
    function setFeeWad(uint256 newFeeWad) external;

    /// @notice Owner-only: rotate the fee recipient (must be non-zero).
    function setFeeRecipient(address newRecipient) external;

    /// @notice Owner-only: hand ownership to `newOwner` (or address(0) to renounce —
    ///         the fee and any still-unset venues are then frozen forever).
    function transferOwnership(address newOwner) external;

    // ---------------------------------------------------------------- views

    /// @notice Current fee rate (1e18-scaled).
    function feeWad() external view returns (uint256);

    /// @notice Immutable maximum fee the owner can ever set (1e18-scaled).
    function MAX_FEE_WAD() external view returns (uint256);

    /// @notice Current owner (address(0) once renounced).
    function owner() external view returns (address);

    /// @notice Accrued, unswept native fees (wei) = the router's balance at rest.
    function pendingFees() external view returns (uint256);

    /// @notice The V3 pool for (quote, token, feeTier) per the pinned V3 factory, or
    ///         address(0) when the V3 leg is not configured.
    function poolFor(address token, uint24 feeTier) external view returns (address);

    /// @notice Pinned Uniswap V2 factory (address(0) until configured).
    function v2Factory() external view returns (address);

    /// @notice Pinned Uniswap V3 factory (address(0) until configured).
    function v3Factory() external view returns (address);

    /// @notice Pinned Uniswap V4 PoolManager (address(0) until configured).
    function poolManager() external view returns (address);

    /// @notice The quote token: a classic wrapped-native (WETH9) or a dual-native ERC20
    ///         (USDT0 on Stable) whose balance IS the native gas balance.
    function QUOTE() external view returns (address);

    /// @notice Wei per quote pool unit: 10^(18 − quoteDecimals). 1 on 18-dec chains,
    ///         1e12 on Stable (6-dec USDT0).
    function QUOTE_SCALE() external view returns (uint256);

    /// @notice True when the quote ERC20 shares one balance with native gas (no
    ///         deposit/withdraw wrap cycle exists or is needed).
    function DUAL_NATIVE() external view returns (bool);

    /// @notice Current fee recipient (owner-rotatable target of {sweep}).
    function feeRecipient() external view returns (address);
}
