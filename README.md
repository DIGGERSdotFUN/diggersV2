# Diggers V2

**The last meme-coin launcher.**  
One transaction. One billion tokens. Locked liquidity forever.  
No bonding curve. No migration. No admin keys. Just the mine.

[Website](https://diggers.fun) · [Docs](https://docs.diggers.fun) · [On-chain examples](EXAMPLES.md) · [𝕏](https://x.com/DIGGERSdotFUN) · [Telegram](https://t.me/DIGGERSdotFUN)

---

Diggers is a fair launchpad built natively on Uniswap V3, designed for multi-chain deployment. Every launch deploys a fixed 1,000,000,000 supply ERC-20, seeds its entire supply as permanent single-sided liquidity in a real Uniswap V3 pool, and starts trading in the same block — no bonding curve, no migration step, no admin keys over balances or liquidity. The core mechanics are immutable from the first block.

This repository contains the **complete Solidity sources** of the V2 protocol.

| | |
|---|---|
| **Chains** | Ethereum (1) · Robinhood Chain (4663) · Stable (988) · any EVM with Uniswap V3 |
| **Compiler** | solc ^0.8.35 · viaIR · optimizer · Cancun (EIP-1153) |
| **License** | Business Source License 1.1 → GPL-2.0-or-later |
| **ENS** | diggersdotfun.eth |
| **Deployments** | v2-deployments.diggersdotfun.eth |

## Protocol in one minute

```
Creator calls create()
  │
  ├─ 1. Deploy ──► EIP-1167 clone of DiggersToken (45 bytes)
  ├─ 2. Mint ────► 1,000,000,000 tokens → Launchpad
  ├─ 3. Seed ────► Full supply as single-sided liquidity in V3 pool
  ├─ 4. Buy ─────► Creation fee → pool buy → burn (gives the pool its first trade)
  │                Remaining ETH → initial buy → creator / lock recipients
  └─ 5. Live ───► Trading starts in the same block
```

* **No rug possible.** The Launchpad is the pool's only LP and has no withdrawal function. Supply has no mint. Sells need no approval. There is no pause, no proxy, no upgrade path.
* **Fees flow, not drain.** 1% forced pool fee → harvested → team / creator split table → pull payments. Token-side fees → part burned, part to the daily contest pot, part to optional buyback or Glue NAV-backing.
* **Trade to earn.** Every pool trade earns digging points (buys 4×, sells 1×). Top 10 of each 24h epoch split the daily pot. Settled lazily.
* **Graduate pump.fun-style.** A token graduates when 80% of the supply has been bought out of its pool — that drops the 2% anti-whale cap forever. Then holders + volume + mean mcap earn **Blue Chip status**, which locks your name and ticker forever with paid reservations. USD-denominated bars on ETH-quote chains via a V3 TWAP oracle.
* **Multi-chain native.** ETH-gas chains (Robinhood) and USD-native chains (Stable with USDT0) are both first-class. JSON presets + auto-derived start ticks + preflight guards make deploying to a new chain a single command.

---

## How Diggers V2 is different

| Traditional launchpad (pump.fun, etc.) | Diggers V2 |
|---|---|
| **Pool at launch** — Bonding curve (custom AMM). Real Uniswap pool only after graduation. Bots snipe the migration tx | Uniswap V3 pool from block one. No bonding curve, no migration, no snipe window |
| **Liquidity** — Removable by the deployer or migration contract. Rug vector | The Launchpad is the sole LP and has **no withdraw function**. Locked forever by code |
| **Supply** — Often mintable, or hidden admin functions | Fixed 1B supply, non-mintable, burnable. totalSupply only goes down |
| **Sells** — Require an approve tx (or wallet signature). Users forget to revoke | Approve-free. The token trusts the Launchpad under two hard conditions (your tokens, inside the sell flow). Nothing to revoke |
| **Fee model** — Platform takes a cut; creator gets nothing | Creator gets an immutable fee-split table (up to 10 recipients). Fees flow forever via pull payments |
| **Graduation** — "Market cap reaches X" → migrate to DEX. Bots snipe the migration tx | Already on Uniswap V3. Graduation = 80% of supply bought out of the pool: the anti-whale cap drops, nothing migrates. Blue Chip (holders + volume + mcap) then locks the name |
| **Admin keys** — Pausable, upgradeable, owner can freeze/seize | No pause, no proxy, no upgrade path. One bounded owner for config only. Can be renounced forever |
| **Architecture** — Monolithic ERC-20 with hidden logic | DiggersHub offloads events + views (EIP-170 safe). DiggersLocker handles vesting. Clean separation |

## What's new in V2 (vs V1)

### DiggersHub — events + views singleton
V1 hit the EIP-170 bytecode limit. V2 splits the launchpad into two contracts: **Diggers** (the engine — factory + router + fee splitter) and **DiggersHub** (the indexer — all protocol events + ecosystem views). The hub reads Diggers' state via `extsload` and gates log endpoints with emitter checks. An indexer subscribes to one address (the hub) for the entire protocol.

### DiggersLocker — external vesting escrow
Vesting locks moved from inside the token to a dedicated **DiggersLocker** contract. ID-based multi-lock per wallet (not one-per-address), with approve-free token pulls, three withdraw shapes (`withdraw`, `withdrawAll`, `withdrawUpTo`), and max-10 cap for bounded gas.

### Uniswap V3 native
The LP fee is forced to 1% (tick spacing 200) across all pools. No per-launch fee choice. WETH-based wrapping on ETH-quote chains; dual-native USDT0 support on Stable.

### USD-denominated blue-chip bars
On ETH-quote chains, graduation bars convert to USD via a real-time Uniswap V3 TWAP oracle over up to 4 stablecoin pools. A 30-minute window + 1-hour lazy cache blocks manipulation (proven in the test suite). On USD-native chains the bars are direct dollar values.

### Buyback + Glue NAV-backing
Creators can allocate a share of their ETH fees to an automatic buyback (sweep donations + WETH from the token vault, swap for tokens, burn) or to Glue NAV-backing deposits. Both are per-token, optional, and adjustable by the token's fee owner.

### Multi-chain deploy tooling
JSON presets per chain, auto-derived NATIVE_USD start tick ($2,600–$3,000 anchor), comprehensive constructor guards (tick alignment, fee sanity, factory probe, decimals cross-check, Cancun support), and `Smoke.s.sol` for post-deploy canary testing.

---

## Digging points & the daily traders contest

Every pool trade on a Diggers token earns **digging points**. Buys are worth 4× the same-size sell. A rolling top-10 leaderboard tracks the highest scorers of each 24-hour epoch, and when the epoch ends, the top 10 split a daily airdrop pot (funded by the token-side LP fees that aren't burned). Settlement is lazy — it piggybacks on the first transfer after the deadline.

This is the first on-chain trade-to-earn contest that runs per-token, fully in the ERC-20's own `_update` hook, with no external oracle, no off-chain leaderboard, and no admin who picks winners.

## On-chain name registry (contenders & reservations)

Name and ticker are **case-insensitive registry keys** enforced byte-by-byte on-chain (A–Z → a–z fold, only ASCII alphanumeric + single internal spaces for names, alphanumeric only for symbols). Every launch locks both keys for 1 hour. If the coin achieves Blue Chip status, the name can be secured permanently: **1 ETH = 365 days**, compounding, up to a 100-year cap. Proceeds go to the team treasury via pull payments.

## Approve-free sells

The token's `transferFrom` skips the allowance check entirely when the caller is the Launchpad — and the Launchpad only ever pulls from `msg.sender` of the outer call, inside the sell flow. No approve transaction. No infinite allowance. Nothing to revoke.

## Graduation explained

On Diggers, **the token is already on Uniswap V3 from block one** — there is nothing to migrate. Graduation is pump.fun-style **supply-sold**: once 80% of the fixed 1B supply has been bought out of the pool (the pool's token balance falls to 200M), the token graduates and the 2% anti-whale cap drops forever. It is price-path independent, permissionless to trigger, and checked automatically on every trade.

After graduation, a token can earn **Blue Chip status** — a live, revocable badge that unlocks one privilege: the ability to permanently reserve your token's name and ticker on the on-chain registry. Blue Chip is dormant until graduation; no bar is even checked before it.

### The Blue Chip criteria (all measured on-chain, pool legs only)

| Criterion | What it proves |
|---|---|
| **Holders** | Real distribution, not a few whales |
| **Volume** | Sustained trading activity |
| **Market cap** | The market values the token, not just trades it |

All criteria are pure on-chain constants — no oracle, no committee, no vote (except the TWAP oracle for USD conversion on ETH-quote chains). The token contract itself tracks holders, cumulative volume, and daily closing ticks.

---

```
contracts/
├── Diggers.sol              Singleton launchpad (factory + router + fees + registry)
├── DiggersHub.sol           Events singleton + ecosystem views (extsload reads)
├── DiggersToken.sol         Launched-coin implementation (ERC20 + all token mechanics)
├── DiggersLocker.sol        Vesting escrow (ID-based multi-lock, approve-free)
├── interfaces/
│   ├── IDiggers.sol         Full external surface + errors + structs
│   ├── IDiggersHub.sol      Hub surface + all protocol events
│   ├── IDiggersLocker.sol   Locker interface
│   ├── IDiggersToken.sol    Token interface
│   └── IGlueV2.sol          Glue NAV-backing deposit interface
└── libs/
    ├── DiggerV3.sol          Uniswap V3 pool plumbing + interfaces
    ├── DiggerMath.sol        Full-precision 512-bit math (md512)
    ├── DiggerCreateLib.sol   Token deployment + liquidity seeding
    ├── DiggerLaunchLiquidity.sol  Position minting (single-sided)
    ├── DiggerLaunchMath.sol  Start-price tick alignment
    ├── DiggerQuotes.sol      Buy/sell quoting (fee-inclusive)
    ├── DiggerSwapViews.sol   Pool-state reads for post-swap events
    ├── DiggerHarvestLib.sol  Fee collection + full split (no reinvest leg)
    ├── DiggerHarvestMath.sol Fee math (WAD splits)
    ├── DiggerHarvestViews.sol Pending-fee reads
    ├── DiggerRegistryLib.sol Name/symbol registry (contenders, reservations)
    ├── DiggerCharset.sol     On-chain charset validation + case folding
    ├── DiggerGraduationLib.sol Blue-chip checks + graduate()
    ├── DiggerGraduationMath.sol Mean-tick mcap + supply-sold evaluation
    ├── DiggerBuybackLib.sol  Buyback pot mechanics (sweep + swap + burn)
    └── DiggerTwapOracle.sol  USD bar oracle (V3 TWAP, multi-asset)
```

The tree is dependency-free: every import is relative, there are no external packages, and everything compiles with `solc ^0.8.35`.

---

## Contract reference

### Diggers.sol — The Launchpad

The singleton that does everything: factory, swap router, Uniswap V3 callback host, LP fee harvester, pull-payment ledger, name/symbol registry, graduation engine, and buyback orchestrator. Every pool trades through this contract. It is the only LP of every pool, and it has **no function to remove liquidity**. Protocol events are relayed to DiggersHub.

#### Ownership & protocol config

| Function | Access | Description |
|---|---|---|
| owner() | view | Current protocol owner (address(0) = renounced) |
| feeRecipient() | view | Team wallet that receives ETH fee credits |
| teamShareWad() | view | Global team share of ETH fees (1e18 = 100%) |
| setTeamShareWad(uint256) | owner | Set team share (≤100%) |
| setFeeRecipient(address) | owner | Rotate the team ETH wallet |
| setGlueDeposit(address) | owner | Activate Glue NAV-backing (once only) |
| creationOpen() | view | Whether public token creation is open |
| setCreationOpen(bool) | owner | Open/close public creation (owner can always create) |
| transferOwnership(address) | owner | Transfer protocol ownership |
| renounceOwnership() | owner | Renounce forever — all config functions are then dead. Reverts while creation is still closed |

#### Token creation

The protocol deploys with **creation closed**: only the owner can launch tokens until `setCreationOpen(true)`. The owner can close the gate again at any time (existing tokens keep trading; only new launches are gated).

| Function | Access | Description |
|---|---|---|
| create(name, symbol, metadataURI) | payable | Simple launch: deploy + seed + creation-fee buy. msg.value = creation fee |
| createFull(TokenParams, FeeSplit[], LockOrder[], initialBuyWei) | payable | Full launch: deploy + seed + custom fee table + initial buy + distribute with optional vesting |

#### Trading (swap router)

| Function | Access | Description |
|---|---|---|
| buy(token, minOut, to) | payable | Buy tokens with exact ETH. Approve-free |
| sell(token, amountIn, minOut, to) | external | Sell tokens for ETH. **No approve needed** |
| buyAndLock(token, minOut, LockOrder[]) | payable | Buy + split + vest in one tx |
| execBuyback(token, userAmountOut) | external | Execute a buyback on behalf of a token |

#### Fee harvesting & claims

| Function | Access | Description |
|---|---|---|
| harvest(token) | external | Collect LP fees and split: ETH → team + creator table. Tokens → burn + pot + buyback + Glue |
| claim() | external | Withdraw accumulated ETH fee credits |
| ethOwed(account) | view | Pull-payment ETH balance (wei) |
| pendingEth(token) | view | Creator ETH slices awaiting retry |

#### Per-token ownership

| Function | Access | Description |
|---|---|---|
| feeOwner(token) | view | Who can edit the fee-split table |
| burnOwner(token) | view | Who can edit the tokenomics split |
| setFeeSplits(token, FeeSplit[]) | feeOwner | Replace the creator ETH fee-split table |
| setTokenomics(token, burnShareWad, buybackShareWad, backingShareWad, stakingShareWad, stakeShareWad) | burnOwner | Update the token-side split |
| transferFeeOwnership / renounceFeeOwnership | feeOwner | Transfer or freeze fee-split control |
| transferBurnOwnership / renounceBurnOwnership | burnOwner | Transfer or freeze tokenomics control |

#### Name registry & graduation

| Function | Access | Description |
|---|---|---|
| graduate(token) | external | Graduate a token once 80% of supply is bought out of its pool. Permissionless |
| blueChip(token) | external | Promote a graduated token to Blue Chip status. Permissionless (reverts NotGraduated before graduation) |
| blueChipLost(token) | external | Demote a token that no longer qualifies |
| addOracleAsset(asset) | owner | Register a stablecoin for USD bar conversion |
| removeOracleAsset(asset) | owner | Remove a stablecoin from the oracle set |

---

### DiggersHub.sol — The Events Singleton

Every protocol event prints from the Hub (one log address for the entire protocol). The Hub also serves ecosystem views by reading Diggers' storage via `extsload` — the full registry state, graduation progress, pool snapshots, pending fees, buy/sell quotes, and the TWAP-converted blue-chip bars.

#### Views (served by the Hub)

| Function | Access | Description |
|---|---|---|
| isDiggersToken(token) | view | Whether this address was launched through the launchpad |
| tokenRecord(token) | view | Pool record: creator, pool, tick bounds, fee config |
| poolState(token) | view | Live pool snapshot: sqrtPriceX96, tick, liquidity, reserves |
| quoteBuy(token, ethIn) | view | Fee-inclusive buy quote |
| quoteSell(token, tokenIn) | view | Fee-inclusive sell quote |
| isNameFree(name) | view | Whether a name is available |
| isSymbolFree(symbol) | view | Whether a ticker is available |
| keyStateOf(name, symbol) | view | Full registry state for both objects |
| graduatedAt(token) | view | When the token graduated (0 = never) |
| blueChippedAt(token) | view | When Blue Chip was achieved (0 = never) |
| progressOf(token) | view | Full graduation + Blue Chip progress snapshot |
| blueChipBars() | view | Current blue-chip thresholds (TWAP-converted on ETH chains) |
| pendingFees(token) | view | Uncollected LP fees |
| feeSplitCount(token) / feeSplitAt(token, i) | view | Creator fee-split table |
| oracleAssets() | view | Registered TWAP oracle stablecoins |

---

### DiggersToken.sol — The Launched Coin

The ERC-20 implementation that every launch is a clone of. Fixed 1 billion supply, 18 decimals, burnable, non-mintable. Everything beyond vanilla ERC-20 lives in the `_update` pipeline:

1. **Anti-whale cap** — no wallet can hold >2% of supply until graduation (exempt: PoolManager, Launchpad, the token itself, address(0)); dropped forever once the token graduates
2. **Approve-free sells** — `transferFrom` skips the allowance when the launchpad calls
3. **Digging points** — pool buys earn 2e18·amount/supply, pool sells earn 5e17·amount/supply
4. **Top-10 leaderboard** — min-slot replacement, no sorting needed
5. **Lazy epoch settlement** — first transfer past `epochEnd` distributes the pot
6. **Graduation telemetry** — holderCount, volumeEthCum, dailyTick (pool legs only)
7. **Round-trip defense** — same-block buy+sell: the sell revokes proportional points (anti-flash-loan)

---

### DiggersLocker.sol — The Vesting Escrow

ID-based multi-lock vesting. Tokens are held on the Locker; schedules enforce N equal tranches over a duration. Approve-free: the Launchpad pulls tokens directly from the creator into the Locker during `createFull` or `buyAndLock`.

| Function | Access | Description |
|---|---|---|
| multiLock(token, recipients[], amounts[], schedules[]) | external | Batch-create vesting locks (pulls tokens from caller) |
| lockFor(token, funder, total, LockOrder[]) | launchpad only | Create-time distribution locks |
| withdraw(token, wallet, index) | external | Withdraw one fully-vested lock |
| withdrawAll(token, wallet) | external | Withdraw all vested locks for a wallet |
| withdrawUpTo(token, wallet, indices[], budget) | external | Partial withdrawal across multiple locks |
| lockCountOf(token, wallet) | view | Number of locks for a wallet |
| getLock(token, wallet, index) | view | Full lock detail |
| lockedOf(token, wallet) | view | Total still-locked balance |
| lockedSupplyOf(token) | view | Total locked supply across all wallets |
| withdrawableOf(token, wallet, index) | view | How much is withdrawable right now |

---

## Events (indexer contract)

DiggersHub is the **single log address** for the entire protocol. All events are emitter-gated — only Diggers, DiggersLocker, and DiggersToken can trigger them. An indexer subscribes to one address (the hub) plus each token's plain ERC-20 Transfer/Approval.

| Event | Description |
|---|---|
| Created(token, creator, name, symbol, metadataURI, pool, startSqrtPriceX96, poolFee, burnShareWad) | Token deployed, pool initialized, liquidity seeded |
| FeeSplitConfigured / FeeSplitUpdated | Creator ETH fee table set or replaced |
| TokenomicsUpdated | Token-side split (burn/buyback/backing/staking) changed |
| FeeOwnershipTransferred / BurnOwnershipTransferred | Per-token owner role changed/renounced |
| FeeParked | ETH delivery failed, retried on next harvest |
| Swapped(token, trader, isBuy, ethAmount, tokenAmount, sqrtPriceAfter, tickAfter, liquidityAfter, ethInPool, tokenInPool) | Router swap with full post-trade state |
| Harvested(token, caller, ethTotal, ethToTeam, ethToCreators, tokensBurned, tokensToPot, ...) | LP fees collected and split |
| BuybackBurned(token, ethIn, tokensBurned) | Buyback executed and tokens burned |
| GlueActivated(glue) | Glue NAV-backing deposit address set |
| Claimed(account, amount) | Pull-payment ETH claimed |
| Graduated(token, nameKey, symbolKey, holders, volumeEthCum, supplySold, pool) | Supply-sold graduation (80% bought out of the pool) |
| TokenGraduated(token, pool) | Simple graduation event for indexers |
| BlueChip(token, ...) | Blue Chip status achieved |
| BlueChipLost(token, ...) | Blue Chip status lost |
| OracleAssetAdded / OracleAssetRemoved | TWAP oracle stablecoin registered/removed |
| PoolTrade(token, trader, isBuy, tokenAmount, ethValue, tick, holdersAfter, volumeEthCumAfter, epoch) | Primary trade feed for graduation telemetry |
| PointsCredited / PointsRevoked | Points earned/revoked on a pool leg |
| LeaderboardChanged | Top-10 board membership changed |
| HolderCountChanged | Unique holder counter changed |
| EpochSettled | Daily pot distributed |
| AirdropPaid | One winner received their pot share |
| Locked / Withdrawn | Vesting lock created / released |
| OwnershipTransferred / TeamShareUpdated / FeeRecipientUpdated | Protocol config changes |

---

## Internal libraries

The `libs/` directory contains the protocol's internal plumbing. They are not user-facing but are documented here for auditors and contributors.

| Library | Purpose |
|---|---|
| **DiggerV3** | Uniswap V3 pool plumbing: pool creation, swap callbacks, fee collection, position management, tick/price helpers |
| **DiggerMath** | Full-precision 512-bit multiply-divide (md512, md512Up), inverse price from sqrtPriceX96 |
| **DiggerCreateLib** | Token deployment pipeline: EIP-1167 clone, supply mint, pool init, single-sided seeding, fee-split setup |
| **DiggerLaunchLiquidity** | V3 position minting: maxLiquidityForAmount1 (binary search for token-only positions) |
| **DiggerLaunchMath** | Start-price tick alignment, seed budget calculation, full-range tick derivation |
| **DiggerQuotes** | Fee-inclusive buy/sell quoting via V3 quoter math |
| **DiggerSwapViews** | Post-swap pool state reads for the Swapped event payload |
| **DiggerHarvestLib** | Fee collection: collects V3 LP fees, splits ETH (team/creator) in full, handles token-side (burn/pot/buyback/Glue) — no reinvest leg |
| **DiggerHarvestMath** | WAD-scaled fee split math |
| **DiggerHarvestViews** | Pending-fee reads from V3 positions without collecting |
| **DiggerRegistryLib** | Name registry: case-folded key creation, forever reservation, launch-lock enforcement |
| **DiggerCharset** | On-chain charset validation (names 1–32 chars, symbols 1–10 chars) + A–Z case folding |
| **DiggerGraduationLib** | Graduation engine: supply-sold check, graduate/blueChip/blueChipLost state transitions, 48h name grace |
| **DiggerGraduationMath** | Mean-tick mcap, supply-sold evaluation, Blue Chip bar comparison |
| **DiggerBuybackLib** | Buyback pot: sweep native + WETH donations, quote-scale alignment, sandwich cap, swap + burn |
| **DiggerTwapOracle** | USD bar conversion: multi-asset V3 TWAP (30-min window), deepest-pool anchoring, 1h cache, bar bounds |

---

## Deployments

The protocol is deployed at the **same addresses on every chain**:

| Contract | Address (all chains) |
|---|---|
| **Diggers** (launchpad) | `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b` |
| **DiggersHub** (events + views) | `0xdEBA423Ab2D46650061555aaBEC362673c811b44` |
| **DiggersLocker** (vesting) | `0xF37b72a3cB71489F2b95Cf7373681a28AFEfD1A8` |
| **DiggersToken** (implementation) | `0x74a1951f6dB8cB6cd2D2099fa0d020Fb0C52fd9B` |

Per-chain configuration:

| Chain | Chain ID | Quote | Uniswap V3 factory | Creation fee |
|---|---|---|---|---|
| Ethereum | 1 | ETH (WETH) | `0x1F98431c8aD98523631AE4a59f267346ea31F984` | 0.001 ETH |
| Robinhood Chain | 4663 | ETH (WETH) | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | 0.001 ETH |
| Stable | 988 | USDT0 (dual-native) | `0x88F0a512eF09175D456bc9547f914f48C013E4aA` | 1 USDT0 |

See `v2-deployments.diggersdotfun.eth` for the canonical registry, and [EXAMPLES.md](EXAMPLES.md) for live transactions, function selectors, and the full event topic reference.

## Building

The sources have no framework coupling. To compile them, drop this directory into any Foundry or Hardhat project (or use `solc` directly) with `solc ^0.8.35`, `viaIR`, the optimizer enabled, and `evm_version = cancun` (EIP-1153 transient storage is required).

## License

Business Source License 1.1 — see [LICENSE](LICENSE).

The Licensed Work is (c) 2026 `diggersdotfun.eth` and is owned exclusively by the holder of that ENS name. You may build on, integrate with, and earn from the official Diggers deployment; you may not fork, redeploy, or counterfeit the protocol. On the Change Date the code converts to GPL-2.0 or later. The authoritative parameters live as ENS text records under `diggersdotfun.eth`.
