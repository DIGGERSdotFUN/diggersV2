// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggersToken
 * @notice Interface of the ERC20 deployed for every Diggers launch (Uniswap V3 edition).
 *         Fixed 1e9·1e18 supply, 18 decimals, burnable, non-mintable. The token natively
 *         trusts the Diggers launchpad as its swap router: transferFrom skips the allowance
 *         check when the launchpad is the caller, so sells never need an approve tx. Pool
 *         legs are classified against the token's own V3 pool address. Self-contained.
 * @dev V3 edition drops the in-token vesting locks entirely — vesting locks are ID-based
 *      positions escrowed on the launchpad — so there is no lock surface here. Protocol
 *      telemetry events (PoolTrade, points, epoch, holders) print from the hub via
 *      emitter-gated `log*` relays; only canonical ERC-20 Transfer/Approval stay local.
 * @author BasedDopamine
 */
interface IDiggersToken {
    // ----------------------------------------------------------------- events

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ----------------------------------------------------------------- errors

    error BalanceTooLow(uint256 balance, uint256 needed);
    error AllowanceTooLow(uint256 allowance, uint256 needed);
    error CapExceeded();
    error ZeroAddress();
    error NotLaunchpad();
    error AlreadyInitialized();
    error PoolRequired();
    error SweepFailed();

    // ----------------------------------------------------------- initializer

    /**
     * @notice Arms a fresh EIP-1167 clone: identity, pool binding, epoch clock, and the one
     *         and only supply mint (to the launchpad). Launchpad-only, once-only.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     * @param metadataURI_ ipfs:// metadata JSON.
     * @param pool_ The token's WETH/token V3 pool (pool-leg classification counterparty).
     */
    function initialize(string calldata name_, string calldata symbol_, string calldata metadataURI_, address pool_)
        external;

    // ------------------------------------------------------------ ERC20 core

    /// @notice ERC-20 name.
    /// @return Token name string.
    function name() external view returns (string memory);

    /// @notice ERC-20 symbol.
    /// @return Token symbol string.
    function symbol() external view returns (string memory);

    /// @notice ERC-20 decimals (always 18).
    /// @return Decimals (18).
    function decimals() external pure returns (uint8);

    /// @notice Circulating supply (decreases only via burns).
    /// @return Total supply in raw token units.
    function totalSupply() external view returns (uint256);

    /// @notice ERC-20 balance of `account`.
    /// @param account Address to query.
    /// @return Raw token balance.
    function balanceOf(address account) external view returns (uint256);

    /// @notice ERC-20 transfer. Hosts anti-whale, points, epoch settlement, and telemetry
    ///         on pool legs (see contract `_update`).
    /// @param to Recipient.
    /// @param amount Raw token units.
    /// @return True on success.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice ERC-20 allowance of `spender` over `owner`.
    /// @param owner Token owner.
    /// @param spender Approved spender.
    /// @return Remaining allowance in raw token units.
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice ERC-20 approve.
    /// @param spender Address granted allowance.
    /// @param amount Allowance in raw token units.
    /// @return True on success.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice ERC-20 transferFrom. Skips the allowance check when msg.sender is
    ///         {LAUNCHPAD} (approve-free sells / create-time distribution pulls).
    /// @param from Token sender.
    /// @param to Recipient.
    /// @param amount Raw token units.
    /// @return True on success.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Burns `amount` of the caller's tokens (supply decreases).
    /// @param amount Raw token units to burn.
    function burn(uint256 amount) external;

    // ------------------------------------------------------------- graduation

    /// @notice Drops the anti-whale shield forever. Launchpad-only, one-way.
    function markGraduated() external;

    /// @notice Whether this token has graduated (anti-whale shield dropped).
    /// @return True after {markGraduated}.
    function graduated() external view returns (bool);

    // ---------------------------------------------------------- buyback vault

    /// @notice Moves the token's whole native balance to the launchpad (buyback wrap step).
    ///         Launchpad-only. Donations arrive via the token's `receive()`.
    /// @return amount Native wei swept to the launchpad.
    function sweepDonations() external returns (uint256 amount);

    /// @notice Moves the token's whole `erc20` balance to the launchpad (buyback spend
    ///         step; `erc20` is WETH in practice). Launchpad-only.
    /// @param erc20 ERC-20 whose entire balance on this token is swept.
    /// @return amount Raw ERC-20 units swept to the launchpad.
    function sweepErc20(address erc20) external returns (uint256 amount);

    // ---------------------------------------------------------- trader points

    /// @notice Current points epoch id (monotonic; advances on lazy daily settlement).
    /// @return Current epoch number.
    function epoch() external view returns (uint256);

    /// @notice Unix timestamp when the current epoch ends (settlement trigger).
    /// @return Epoch end timestamp.
    function epochEnd() external view returns (uint64);

    /// @notice Caller's (or `trader`'s) points in the current epoch.
    /// @param trader Address to query.
    /// @return Points score for the current epoch.
    function traderPoints(address trader) external view returns (uint256);

    /// @notice Points of `trader` in a specific epoch.
    /// @param epochId Epoch to query.
    /// @param trader Address to query.
    /// @return Points score for that epoch.
    function pointsOf(uint256 epochId, address trader) external view returns (uint256);

    /// @notice Lifetime points of `trader` across all epochs (after revocations).
    /// @param trader Address to query.
    /// @return Cumulative lifetime points.
    function lifetimePoints(address trader) external view returns (uint256);

    /// @notice Current epoch top-10 board (fixed slots; min-slot replacement, unsorted).
    /// @return board Addresses of the ten leader slots (zero-padded if sparse).
    /// @return scores Matching scores for each board slot.
    function currentLeaders() external view returns (address[10] memory board, uint256[10] memory scores);

    /// @notice Top-10 board for a historical epoch.
    /// @param epochId Epoch to query.
    /// @return board Addresses of the ten leader slots for that epoch.
    /// @return scores Matching scores for each board slot.
    function leadersOf(uint256 epochId) external view returns (address[10] memory board, uint256[10] memory scores);

    // -------------------------------------------------- graduation telemetry

    /// @notice Unique holders that entered via a pool buy (sybil-resistant counter).
    /// @return Current counted holder count.
    function holderCount() external view returns (uint32);

    /// @notice Whether `account` is currently counted toward {holderCount}.
    /// @param account Address to query.
    /// @return True if `account` is a counted holder.
    function isCountedHolder(address account) external view returns (bool);

    /// @notice Lifetime cumulative ETH volume from pool legs (wei).
    /// @return Cumulative volume in wei.
    function volumeEthCum() external view returns (uint256);

    /// @notice Daily-close tick snapshot for a UTC day index (`timestamp / 1 days`).
    /// @param dayIndex Day index to query.
    /// @return tick Last tick written that day (0 if never recorded).
    /// @return recorded True if at least one pool leg wrote that day.
    function dailyTickOf(uint256 dayIndex) external view returns (int24 tick, bool recorded);

    /// @notice Packed graduation/blue-chip telemetry snapshot.
    /// @return holders Counted unique holders.
    /// @return volumeEth Lifetime pool volume in wei.
    /// @return meanTick Mean of recorded daily-close ticks (empty days skipped).
    /// @return daysTracked Number of non-empty days in the mean window.
    function graduationStats()
        external
        view
        returns (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked);

    // ------------------------------------------------------------- immutables

    /// @notice The Diggers launchpad: factory, swap router, sole LP, fee harvester.
    /// @return Launchpad address.
    function LAUNCHPAD() external view returns (address);

    /// @notice This token's WETH/token 1% Uniswap V3 pool (pool-leg counterparty).
    /// @return Pool address.
    function POOL() external view returns (address);

    /// @notice Launch timestamp; anchors the free graduation window.
    /// @return Deploy timestamp (unix seconds).
    function DEPLOYED_AT() external view returns (uint64);

    /// @notice ipfs:// URI of the launch metadata JSON.
    /// @return Metadata URI string.
    function metadataURI() external view returns (string memory);

    /// @notice ERC-7572 contract-level metadata — returns the same URI as {metadataURI}.
    /// @return Contract metadata URI string.
    function contractURI() external view returns (string memory);
}
