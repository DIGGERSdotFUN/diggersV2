# Functions, Events & On-Chain Examples

> Every transaction below is **real and live**. Diggers V2 is deployed at the
> **same addresses on Ethereum (1), Robinhood Chain (4663) and Stable (988)**.
> Explorer paths per chain:
>
> - Ethereum — `https://etherscan.io/tx/{hash}`
> - Robinhood Chain — `https://robinhoodchain.blockscout.com/tx/{hash}` (or `https://robinscan.io/tx/{hash}`)
> - Stable — `https://stablescan.xyz/tx/{hash}`

---

## Deployed contracts

Identical on every chain:

| Contract | Address (all chains) |
|---|---|
| **Diggers** (launchpad) | `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b` |
| **DiggersHub** (events + views) | `0xdEBA423Ab2D46650061555aaBEC362673c811b44` |
| **DiggersLocker** (vesting escrow) | `0xF37b72a3cB71489F2b95Cf7373681a28AFEfD1A8` |
| **DiggersToken** (implementation) | `0x74a1951f6dB8cB6cd2D2099fa0d020Fb0C52fd9B` |

Per-chain configuration (read live from the launchpad):

| Chain | Chain ID | Quote token | Uniswap V3 factory | Creation fee | NATIVE_USD |
|---|---|---|---|---|---|
| Ethereum | 1 | WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | `0x1F98431c8aD98523631AE4a59f267346ea31F984` | 0.001 ETH | no |
| Robinhood Chain | 4663 | WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | 0.001 ETH | no |
| Stable | 988 | WUSDT0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | `0x88F0a512eF09175D456bc9547f914f48C013E4aA` | 1 USDT0 | yes (dual-native) |

Every pool is a standard **Uniswap V3** pool with a forced **1% fee tier**
(tick spacing 200). The launchpad is the sole LP of every pool, holding a
single single-sided position that can never be withdrawn.

---

## Function selectors

### Diggers.sol (launchpad) — `0x5044…2e4b`

| Selector | Function |
|---|---|
| `0x5d28560a` | `create(string name, string symbol, string metadataURI)` — simple launch, payable |
| `0x6dd388b5` | `createFull(TokenParams, FeeSplit[], LockOrder[], uint256 initialBuyWei)` — full launch with fee table + vesting locks |
| `0xdb61c76e` | `buy(address token, uint256 minOut, address to)` — payable |
| `0x2dc8f867` | `sell(address token, uint256 amountIn, uint256 minOut, address to)` — approve-free |
| `0xadcb4e25` | `buyAndLock(address token, uint256 minOut, LockOrder[])` — payable |
| `0x0e5c011e` | `harvest(address token)` |
| `0x4e71d92d` | `claim()` |
| `0xa7568524` | `execBuyback(address token, uint256 userAmountOut)` |
| `0xff6d8d05` | `graduate(address token)` |
| `0xaed21f7c` | `blueChip(address token)` |
| `0xaee08981` | `blueChipLost(address token)` |
| `0x5166861a` | `setFeeSplits(address token, FeeSplit[])` |
| `0x0b949ed9` | `setTokenomics(address token, uint256 burnShareWad, uint256 buybackShareWad, uint256 backingShareWad, uint256 stakingShareWad, uint256 stakeShareWad)` |
| `0x38e3c836` | `transferFeeOwnership(address token, address to)` |
| `0xeddaffc1` | `transferBurnOwnership(address token, address to)` |
| `0x2edeedb5` | `renounceFeeOwnership(address token)` |
| `0x0866341a` | `renounceBurnOwnership(address token)` |
| `0x3d0c655c` | `setCreationOpen(bool)` — owner |
| `0x50f884ed` | `addOracleAsset(address)` — owner |
| `0xd4ba7c60` | `removeOracleAsset(address)` — owner |
| `0x9fc35b2e` | `setTeamShareWad(uint256)` — owner |
| `0xe74b981b` | `setFeeRecipient(address)` — owner |
| `0xb6704df9` | `setGlueDeposit(address)` — owner, one-shot |
| `0xf2fde38b` | `transferOwnership(address)` — owner |
| `0x715018a6` | `renounceOwnership()` — owner |

Key views on the launchpad: `creationOpen()` `0xbd1533f5`, `ethOwed(address)`
`0x680686b7`, `pendingEth(address)` `0xbeae30f5`, `feeOwner(address)`
`0x9c44d63b`, `burnOwner(address)` `0xc90b6c23`, `isDiggersToken(address)`
`0xf28ab2b9`. Quotes, pool state, registry state and graduation progress are
served by **DiggersHub** (`quoteBuy`, `quoteSell`, `poolState`, `progressOf`,
`isNameFree`, `isSymbolFree`, `blueChipBars`, `oracleAssets`, …).

### DiggersLocker.sol (vesting) — `0xF37b…D1A8`

| Selector | Function |
|---|---|
| `0x44a3b686` | `multiLock(address token, address[] recipients, uint256[] amounts, (uint32,uint64)[] schedules)` |
| `0xd9caed12` | `withdraw(address token, address wallet, uint256 index)` |
| `0x09cae2c8` | `withdrawAll(address token, address wallet)` |
| `0xb83f75d9` | `withdrawUpTo(address token, address wallet, uint256[] indices, uint256 budget)` |
| `0xb776993e` | `getLock(address token, address wallet, uint256 index)` — view |
| `0x9e18c26b` | `lockCountOf(address token, address wallet)` — view |
| `0xb9b3e06a` | `lockedOf(address token, address wallet)` — view |
| `0xddd8e032` | `lockedSupplyOf(address token)` — view |
| `0x8f62a56c` | `withdrawableOf(address token, address wallet, uint256 index)` — view |

---

## Creating tokens — integrator quickstart

Two entry points on the launchpad. Both deploy the token, create + initialize
the 1% Uniswap V3 pool, seed the full 1B supply as permanent liquidity and
start trading **in the same transaction**.

### `create` — the simple path (recommended for terminals / GMGN-style integrations)

```solidity
function create(string name, string symbol, string metadataURI)
    external payable returns (address token);        // selector 0x5d28560a
```

The one-call V1-style launch. Sane defaults are baked in — no structs, no
tables:

- `msg.value` must be **at least the creation fee** (0.001 ETH on
  Ethereum/Robinhood, 1 USDT0 on Stable — read `CREATION_FEE()` live).
  The fee runs the pool's first buy and the bought tokens are burned.
- **Any excess `msg.value` becomes the initial buy**, delivered straight to
  the caller. `minOut` is not needed: the pool is created and seeded in this
  same transaction, so the price is deterministic and cannot be sandwiched.
- Tokenomics default to 50% burn / 50% daily trader pot, no buyback, no Glue.
- Both per-token owner roles are renounced from birth; the creator fee-split
  table defaults to 100% → caller.
- `name`/`symbol` must pass the on-chain registry charset (name 1–32,
  ASCII alphanumeric + single internal spaces; symbol 1–10, alphanumeric)
  and must not be locked by a live launch lock or blue-chip reservation
  (check `isNameFree` / `isSymbolFree` on the hub first).

```bash
# launch + 0.004 ETH initial buy in one call (Ethereum / Robinhood):
cast send 0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b \
  "create(string,string,string)" "My Token" "MTK" "ipfs://<metadata.json>" \
  --value 0.005ether
```

The new token address is the return value, and the `Created` event in the
receipt carries token, creator, name, symbol, metadataURI, **pool address**,
startSqrtPriceX96, poolFee and burnShareWad.

### `createFull` — the full path

```solidity
function createFull(
    TokenParams params,        // identity + tokenomics + owner roles
    FeeSplit[]  feeSplits,     // creator quote-side fee table, shares sum to 1e18
    LockOrder[] locks,         // initial-buy distribution + vesting (optional)
    uint256     initialBuyMinOut
) external payable returns (address token);          // selector 0x6dd388b5
```

```solidity
struct TokenParams {
    string  name;
    string  symbol;
    string  metadataURI;
    uint256 burnShareWad;      // token-side fees burned            [0, 1e18]
    uint256 buybackShareWad;   // creator quote slice → buyback pot [0, 1e18]
    uint256 backingShareWad;   // creator quote slice → Glue NAV    (needs Glue active)
    uint256 stakingShareWad;   // creator quote slice → Glue staking
    uint256 stakeShareWad;     // token-side fees → Glue staking
    address owner;             // holds BOTH per-token roles; 0x0 = renounced from birth
}
struct FeeSplit  { address to; uint256 share; }                      // shares sum to 1e18, max 10 rows
struct LockOrder { address to; uint256 shareWad; uint32 tranches; uint64 duration; }
```

Rules: all percentages are **1e18-scaled** (1e18 = 100%, never bps);
`buyback + backing + staking <= 1e18` on the quote side; `burn + stake <= 1e18`
on the token side (the daily pot takes the remainder). `LockOrder` rows split
the initial buy output — `duration == 0` pays immediately, otherwise the slice
is escrowed on the DiggersLocker with `tranches` equal unlocks over
`duration`; locks without an initial buy revert.

Public creation is currently **open on all three chains** (`creationOpen()`
= true; gated by `CreationClosed()` revert otherwise).

---

## Event topic0 reference

**DiggersHub (`0xdEBA…1b44`) is the single log address for the entire
protocol.** Every protocol event prints from the hub — an indexer subscribes
to ONE address per chain for the full feed, plus each token's plain ERC-20
`Transfer`/`Approval` at the token address.

| topic0 (first 10 bytes) | Event |
|---|---|
| `0x603a69d2…` | `Created` |
| `0x7df5095d…` | `FeeSplitConfigured` |
| `0x272b205f…` | `FeeSplitUpdated` |
| `0x105caf20…` | `TokenomicsUpdated` |
| `0x136e332e…` | `FeeOwnershipTransferred` |
| `0xee24d177…` | `BurnOwnershipTransferred` |
| `0xed590b34…` | `FeeParked` |
| `0x464ef255…` | `Swapped` |
| `0x592ed185…` | `Harvested` |
| `0x9974e184…` | `BuybackBurned` |
| `0xe02b093f…` | `GlueActivated` |
| `0xd8138f8a…` | `Claimed` |
| `0x4a2dd56e…` | `Graduated` |
| `0x806ef27e…` | `TokenGraduated` |
| `0x9eca714c…` | `BlueChip` |
| `0x8b160c4b…` | `BlueChipLost` |
| `0xa972f91b…` | `OracleAssetAdded` |
| `0x0dcec408…` | `OracleAssetRemoved` |
| `0xe5ef60a9…` | `CreationOpenSet` |
| `0xe39ee6b8…` | `PoolTrade` |
| `0xc31f84b3…` | `PointsCredited` |
| `0xb06f1e4c…` | `PointsRevoked` |
| `0xb267788b…` | `LeaderboardChanged` |
| `0x38a5f924…` | `HolderCountChanged` |
| `0xc8bdf32e…` | `EpochSettled` |
| `0x95c3f77d…` | `AirdropPaid` |
| `0x7873be2b…` | `Locked` |
| `0xfabb9e7a…` | `Withdrawn` |
| `0xd7ee88b7…` | `EmitterRegistered` |
| `0x8be0079c…` | `OwnershipTransferred` |
| `0x7f30889a…` | `TeamShareUpdated` |
| `0x7a7b5a0a…` | `FeeRecipientUpdated` |
| `0xddf252ad…` | `Transfer` (ERC-20, at each token address) |
| `0x8c5be1e5…` | `Approval` (ERC-20, at each token address) |

### Full event signatures (for topic0 computation)

```
Created(address,address,string,string,string,address,uint160,uint24,uint128)
FeeSplitConfigured(address,address[],uint256[])
FeeSplitUpdated(address,address[],uint256[])
TokenomicsUpdated(address,uint256,uint256,uint256,uint256,uint256)
FeeOwnershipTransferred(address,address,address)
BurnOwnershipTransferred(address,address,address)
FeeParked(address,address,uint256)
Swapped(address,address,bool,uint256,uint256,uint160,int24,uint128,uint256,uint256)
Harvested(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)
BuybackBurned(address,uint256,uint256)
GlueActivated(address)
Claimed(address,uint256)
Graduated(address,bytes32,bytes32,uint32,uint256,uint256)
TokenGraduated(address,address)
BlueChip(address,bytes32,bytes32,uint256,uint256,uint32)
BlueChipLost(address,bytes32,bytes32,uint256,uint32,uint64)
OracleAssetAdded(address,uint96)
OracleAssetRemoved(address)
CreationOpenSet(bool)
PoolTrade(address,address,bool,uint256,uint256,int24,uint32,uint256,uint256)
PointsCredited(address,uint256,address,bool,uint256,uint256,uint256)
PointsRevoked(address,uint256,address,bool,uint256,uint256,uint256)
LeaderboardChanged(address,uint256,address,address,uint256)
HolderCountChanged(address,address,bool,uint32)
EpochSettled(address,uint256,uint256,uint256,uint64)
AirdropPaid(address,uint256,address,uint256)
Locked(address,address,uint256,address,uint256,uint64,uint64,uint32,uint256,uint256)
Withdrawn(address,address,uint256,uint256,uint256,uint256)
EmitterRegistered(address)
OwnershipTransferred(address,address)
TeamShareUpdated(uint256)
FeeRecipientUpdated(address)
Transfer(address,address,uint256)
Approval(address,address,uint256)
```

The underlying **Uniswap V3 pool** also logs its canonical events during
Diggers transactions: `PoolCreated` `0x783cca1c…` (at the factory),
`Initialize` `0x98636036…`, `Mint` `0x7a53080b…`, `Swap` `0xc42079f9…`,
`Burn` `0x0c396cd9…`, `Collect` `0x70935338…` (at the pool address).

---

## Sample transactions

### 1. Token creation (`create`)

One `create()` call deploys the token (EIP-1167 clone), mints the fixed 1B
supply, creates + initializes the V3 pool, seeds the entire supply as
single-sided liquidity, and runs the creation-fee buy-and-burn — trading is
live in the same block.

**Transaction (Stable):**
[`0xcc344e68f5de6fe42324bc38563b25ce773e60eadc00b7b1bac3e0f5efda1fa5`](https://stablescan.xyz/tx/0xcc344e68f5de6fe42324bc38563b25ce773e60eadc00b7b1bac3e0f5efda1fa5)

| Field | Value |
|---|---|
| From | `0x8aacc26a74bcd90fcbd1c1560fa4415815c07547` |
| To | `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b` (Diggers) |
| Selector | `0x5d28560a` (`create`) |
| Block | 32,922,134 |
| Gas used | 5,873,883 |
| Token deployed | `0xfa4f9ad0bc4e84f77335f2ff7851f480341eeee4` (TEST) |

**Events emitted (25 logs), in order:**

| # | Event | Emitter | Description |
|---|---|---|---|
| 0 | `Transfer` | WUSDT0 | Creation fee wrapped into the quote token |
| 1 | `EmitterRegistered` | Hub | The new token clone joins the hub's gated emitter set |
| 2 | `FeeSplitConfigured` | Hub | Creator fee table set (100% to creator on simple create) |
| 3 | `PoolCreated` | V3 factory | The token's 1% pool is created |
| 4 | `Initialize` | V3 pool | Pool initialized at the constant start price |
| 5–7 | init + `Transfer` ×2 | Token | Clone initialized; 1B supply minted and moved for seeding |
| 8 | `Mint` | V3 pool | Entire supply seeded as single-sided liquidity |
| 9 | `Transfer` | Token | Seeding dust settled |
| 10 | `Created` | Hub | Full creation record (name, symbol, URI, pool, startSqrtPriceX96, poolFee, burnShareWad) |
| 11 | `TokenomicsUpdated` | Hub | Token-side split defaults (burn / pot / buyback / Glue) |
| 12–15 | `Transfer`, `Swap`, `Swapped` | Token / pool / Hub | Creation-fee buy — bought tokens are burned (the pool's first trade) |
| 16–20 | `Transfer`, `HolderCountChanged`, `PoolTrade`, `PointsCredited`, `LeaderboardChanged` | Token / Hub | Initial-buy leg credited to the creator |
| 21–24 | `Transfer`, `Swap`, `Swapped` | Token / pool / Hub | Second swap leg settled |

**The same call on the other chains:**

- Ethereum — token `ETHKillers`:
  [`0x4d2b6067e4c76e6bf23b15b69c4d5affad2b62ed1a2b32a0c216b9f3421f72ec`](https://etherscan.io/tx/0x4d2b6067e4c76e6bf23b15b69c4d5affad2b62ed1a2b32a0c216b9f3421f72ec)
  (block 25,602,191 · gas 5,928,717 · token `0xcb6bb2b00701244aaee253391eff5e2baa698e2c`)
- Robinhood Chain — token `Vlad`:
  [`0x9a0fbc7a5163061a6ef958d4b9c9641c45f35829ec9f6d31396263704a4750e1`](https://robinhoodchain.blockscout.com/tx/0x9a0fbc7a5163061a6ef958d4b9c9641c45f35829ec9f6d31396263704a4750e1)
  (block 18,111,432 · gas 5,598,296 · token `0x0fbede2400132cf0e557398ad030d059a0ae5624`)

On ETH-quote chains the same flow shows WETH `Deposit`/`Transfer` legs where
Stable shows WUSDT0 transfers.

---

### 2. Buy swap (direct through Diggers)

A standalone `buy()` call. The buyer sends the native asset (ETH, or USDT0 on
Stable) and receives tokens. No approval needed.

**Transaction (Stable, 1 USDT0 → TARIO):**
[`0x4718e7b1f219dd46c5f51b492d3c0962220c41059067448212ebb29c3022b532`](https://stablescan.xyz/tx/0x4718e7b1f219dd46c5f51b492d3c0962220c41059067448212ebb29c3022b532)

| Field | Value |
|---|---|
| From | `0x63f908342c01009f42185eed079d0ad949745921` |
| To | `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b` (Diggers) |
| Selector | `0xdb61c76e` (`buy`) |
| Value | 1 USDT0 |
| Block | 33,033,503 |
| Gas used | 418,954 |
| Token | `0xd6ae325ac022e49b8dfb5bf861eea63605c6dab8` (TARIO) |

**Events emitted (9 logs):**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| 0 | `Transfer` | WUSDT0 | Native input wrapped for the pool |
| 1 | `HolderCountChanged` | Hub | New holder added (first buy from zero balance) |
| 2 | `PoolTrade` | Hub | Trade telemetry: tokenAmount, ethValue, tick, holdersAfter, volumeEthCumAfter, epoch |
| 3 | `PointsCredited` | Hub | Points earned: `isBuy=true` (4× rate), newScore, lifetimeScore |
| 4 | `LeaderboardChanged` | Hub | Entered the epoch's top-10 (or evicted someone) |
| 5 | `Transfer` | Token | Tokens delivered to the buyer |
| 6 | `Transfer` | WUSDT0 | Quote settled into the pool |
| 7 | `Swap` | V3 pool | Canonical Uniswap V3 swap log |
| 8 | `Swapped` | Hub | Full post-trade snapshot: sqrtPrice, tick, liquidity, reserves |

**Key indexed fields in `Swapped`:**
```
topic1: token address (indexed)
topic2: trader address (indexed)
topic3: isBuy (indexed, true = buy)
data:   ethAmount | tokenAmount | sqrtPriceAfterX96 | tickAfter | liquidityAfter | ethInPool | tokenInPool
```

**Key indexed fields in `PoolTrade`:**
```
topic1: token address (indexed)
topic2: trader address (indexed)
topic3: isBuy (indexed, true = buy)
data:   tokenAmount | ethValue | tick | holdersAfter | volumeEthCumAfter | epoch
```

---

### 3. Sell swap (approve-free)

A `sell()` call. The seller sends tokens and receives the native asset.
**No approve transaction needed** — the token's `transferFrom` skips the
allowance check when the caller is the launchpad, and the launchpad only ever
pulls from `msg.sender` of the outer call, inside the sell flow.

**Transaction (Stable, TEST → USDT0):**
[`0x3b31c2be4901e561247d5412c67a91607dff79ddb36a5dde6060ae362e743676`](https://stablescan.xyz/tx/0x3b31c2be4901e561247d5412c67a91607dff79ddb36a5dde6060ae362e743676)

| Field | Value |
|---|---|
| From | `0x63f908342c01009f42185eed079d0ad949745921` |
| To | `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b` (Diggers) |
| Selector | `0x2dc8f867` (`sell`) |
| Value | 0 (seller receives the native asset) |
| Block | 33,033,079 |
| Gas used | 300,710 |
| Token | `0xfa4f9ad0bc4e84f77335f2ff7851f480341eeee4` (TEST) |

**Events emitted (7 logs):**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| 0 | `Transfer` | WUSDT0 | Pool quote movement |
| 1 | `PoolTrade` | Hub | Trade telemetry, `isBuy=false` |
| 2 | `PointsCredited` | Hub | Points earned at the 1× sell rate |
| 3 | `Transfer` | Token | Tokens pulled seller → pool (no allowance) |
| 4 | `Swap` | V3 pool | Canonical Uniswap V3 swap log |
| 5 | `Transfer` | WUSDT0 | Output unwrapped and paid to the seller |
| 6 | `Swapped` | Hub | Full post-trade snapshot |

A `HolderCountChanged` log appears additionally when the sale zeroes the
seller's balance.

---

### 4. Harvest (fee collection + split)

A `harvest()` call collects all accrued LP fees from the V3 position and
splits them. ETH side → team + creator fee-split table (pull credits, claimed
via `claim()`), with optional buyback and Glue carve-outs. Token side →
`burnShareWad` burned, remainder → the daily contest pot.

**Transaction (Stable, SAMSUNG):**
[`0xd9438045f52b720306dd4d36853c9e545b11fbeb7fdb1ef59452c877cfcbedbe`](https://stablescan.xyz/tx/0xd9438045f52b720306dd4d36853c9e545b11fbeb7fdb1ef59452c877cfcbedbe)

| Field | Value |
|---|---|
| Selector | `0x0e5c011e` (`harvest`) |
| Block | 32,955,019 |
| Gas used | 258,546 |
| Token | `0x8148af08b65fc95c7f1269e0a224a3c6e43555a7` (SAMSUNG) |

**Events emitted (9 logs):**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| 0 | `Burn` (0-liquidity poke) | V3 pool | Updates the position's fee accounting |
| 1–2 | `Transfer` ×2 | WUSDT0 / Token | Both fee sides collected out of the pool |
| 3 | `Collect` | V3 pool | Canonical V3 fee-collection log |
| 4–5 | `Transfer` ×2 | WUSDT0 | Quote-side splits settled |
| 6 | `Transfer` → `0x0` | Token | Token-side burn share destroyed |
| 7 | `Transfer` | Token | Remainder parked on the token as the daily pot |
| 8 | `Harvested` | Hub | The full split in one log |

**Key fields in `Harvested`:**
```
topic1: token address (indexed)
topic2: caller address (indexed)
data:   ethTotal | ethToTeam | ethToCreators | ethToBuyback | ethToGlue |
        tokensBurned | tokensToGlue | tokensToPot
```

When a token has a non-zero `buybackShareWad`, the carved `ethToBuyback`
accumulates in the token's buyback pot; `execBuyback` later sweeps it, swaps
for tokens through the pool and burns them, emitting
`BuybackBurned(token, ethIn, tokensBurned)`.

---

### 5. Epoch settlement (daily contest payout)

Settlement is lazy — it piggybacks on the first transfer after the 24h epoch
deadline. The carrying transfer is never blocked; the settlement runs first,
then the transfer completes normally.

**Events emitted in a settlement:**

| Event | Emitter | What it tells you |
|---|---|---|
| `Transfer` × N | Token | Pot distributed to each winning leader |
| `AirdropPaid` × N | Hub | One per winner: token, epoch, winner, amount |
| `EpochSettled` | Hub | potPerWinner, rolledOver (unclaimed), nextDeadline |

**Key fields:**
```
EpochSettled:  topic1 token | topic2 epoch | data: potPerWinner, rolledOver, nextDeadline
AirdropPaid:   topic1 token | topic2 epoch | topic3 winner | data: amount
```

The current deployment is young — the first epochs are still accruing, so no
settlement transaction is linked here yet. Watch topic0 `0xc8bdf32e…` on the
hub address.

---

### 6. Governance: opening public creation

The protocol deploys with creation closed (owner-only). The owner opened
public creation on all three chains with `setCreationOpen(true)`
(selector `0x3d0c655c`), emitting `CreationOpenSet(bool)` from the hub:

| Chain | Transaction |
|---|---|
| Ethereum | [`0xcf8517f6f861081646709c5849f8b1858a3faaebd0042568de0f517caad175da`](https://etherscan.io/tx/0xcf8517f6f861081646709c5849f8b1858a3faaebd0042568de0f517caad175da) |
| Robinhood Chain | [`0x986e7fb70de4d6508e66faadf5f57b6d524a0f00bc5a7659fd245fef7c28c673`](https://robinhoodchain.blockscout.com/tx/0x986e7fb70de4d6508e66faadf5f57b6d524a0f00bc5a7659fd245fef7c28c673) |
| Stable | [`0x2af033fa048a24b05e2c01e3ab87344f83bb9636bb8630ff0e7700578fc9baed`](https://stablescan.xyz/tx/0x2af033fa048a24b05e2c01e3ab87344f83bb9636bb8630ff0e7700578fc9baed) |

---

### 7. Trading through Uniswap V3 directly (routers & aggregators)

Every Diggers pool is a **standard Uniswap V3 pool** — no hooks, no custom
AMM. Any V3-compatible router, aggregator adapter or terminal can trade it
with zero Diggers-specific code:

```
token0/token1: quote token (WETH / WUSDT0) and the launched ERC-20, sorted by address
fee:           10000 (1%, forced — no per-launch choice)
tickSpacing:   200
```

**Pool discovery** — either of:

- `IUniswapV3Factory(factory).getPool(quoteToken, token, 10000)` with the
  per-chain factory + quote token from the deployments table, or
- `DiggersHub.tokenRecord(token)` which returns the pool address directly
  (plus tick bounds and fee config), or the `pool` field of the `Created`
  event.

Live pools of the sample tokens above:

| Token | Chain | V3 pool |
|---|---|---|
| TEST `0xfa4f…eee4` | Stable | `0x32df0ba016c6dfcfa23aed0113419e63262941a7` |
| TARIO `0xd6ae…dab8` | Stable | `0x6f568b750fd1a779a1260f15af75e80bbf3ae40b` |
| SAMSUNG `0x8148…55a7` | Stable | `0x7140e38f5af7fd3cef24ba59281d914c169e49a3` |
| ETHKillers `0xcb6b…8e2c` | Ethereum | `0x8f6cc3e9990bb210aa887b5a74587135e89b4283` |
| Vlad `0x0fbe…5624` | Robinhood | `0xccf86f8f26c61ddfd4b12702e7759bd42a8010e3` |

**Live V3 swap examples** — the sample transactions above ARE canonical V3
swaps; the pool logs its standard `Swap` event (`0xc42079f9…`) on every one:

- V3 buy leg: [`0x4718e7b1…b532`](https://stablescan.xyz/tx/0x4718e7b1f219dd46c5f51b492d3c0962220c41059067448212ebb29c3022b532)
  — `Swap` at pool `0x6f56…e40b` (log #7): quote in, token out
- V3 sell leg: [`0x3b31c2be…3676`](https://stablescan.xyz/tx/0x3b31c2be4901e561247d5412c67a91607dff79ddb36a5dde6060ae362e743676)
  — `Swap` at pool `0x32df…41a7` (log #4): token in, quote out

**Quoting** — `DiggersHub.quoteBuy(token, ethIn)` / `quoteSell(token, tokenIn)`
return fee-inclusive quotes with no V3 quoter lens needed; standard V3
quoters work too.

**Integration notes:**

- Selling through an external router requires a normal ERC-20 `approve` to
  that router. The approve-free path only exists on the Diggers `sell()`.
- Buys through external routers must swap the **wrapped** quote (WETH /
  WUSDT0); Diggers `buy()`/`sell()` handle native wrapping/unwrapping.
- The token's `_update` hook attributes pool legs **regardless of the
  router** — external-router trades still count toward points, telemetry,
  holder tracking and graduation, and still emit `PoolTrade`/`Swapped`-class
  telemetry from the hub. The rich `Swapped` event only prints for swaps
  routed through Diggers.
- The 2% anti-whale cap applies to recipient balances until the token
  graduates — size buy legs accordingly (max recipient balance 20M tokens).
- The Diggers contract is the **only LP**, holding one single-sided position
  over the full launch range. There is no function to remove this liquidity —
  it is locked forever by code.

---

### 8. Graduation (the event integrators should watch)

Graduation is pump.fun-style **supply-sold**, checked automatically on every
trade and callable permissionlessly via `graduate(token)` (`0xff6d8d05`):
once **80% of the fixed 1B supply has been bought out of the pool** (the
pool's token balance falls to 200M), the token graduates and the 2%
anti-whale cap drops forever. Price plays no role; nothing migrates — the
liquidity was on Uniswap V3 from block one.

Two events fire from the hub in the same breath:

```
TokenGraduated(address indexed token, address indexed pool)     // topic0 0x806ef27e…
Graduated(address indexed token, bytes32 indexed nameKey, bytes32 indexed symbolKey,
          uint32 holders, uint256 volumeEthCum, uint256 supplySold)   // topic0 0x4a2dd56e…
```

`TokenGraduated` is the minimal integrator-facing signal ("open market now,
cap dropped") — third-party terminals subscribe to that ONE topic on the hub
address and read the pool straight from the log. `Graduated` carries the rich
payload for indexers.

Polling instead of subscribing: `DiggersHub.graduatedAt(token)` (0 = not
graduated) and `DiggersHub.progressOf(token)` (live `supplySold` vs
`supplySoldTarget`, holders, volume, mean mcap).

No token has graduated yet on the current deployment, so no transaction is
linked here — watch topic0 `0x806ef27e…` on
`0xdEBA423Ab2D46650061555aaBEC362673c811b44` on every chain.

After graduation a token can further earn **Blue Chip status**
(`blueChip(token)`, emits `BlueChip` / revocable via `BlueChipLost`), which
locks its name and ticker on the registry — dormant until graduation, and
irrelevant to trading integrations.

---

## Answers for integration forms

Pre-filled answers for common listing/integration questionnaires
(DexScreener, DexTools, GeckoTerminal, terminal applications, etc.).

### Can quote token be changed?

**No.** The quote token is fixed per chain: WETH on Ethereum and Robinhood
Chain, USDT0 (dual-native) on Stable. Every pool is quote/token and cannot be
changed after creation.

### How are fees charged?

Every pool is a Uniswap V3 pool with a forced **1% LP fee**. Fees accrue in
the pool's own accounting and are collected permissionlessly via
`harvest(token)`, then split:

- **Quote-side fees** → team share + creator fee-split table (pull payments
  via `claim()`), with optional per-token buyback and Glue NAV-backing carves
- **Token-side fees** → `burnShareWad` burned + remainder to the daily
  contest pot

The 1% pool fee is immutable. The split ratios are adjustable only by the
token's own fee/burn owners (or frozen forever if they renounce).

### Program IDL

N/A (EVM / Solidity, not Solana).

### Program / Contract addresses

Same on Ethereum (1), Robinhood Chain (4663) and Stable (988):

| Role | Address |
|---|---|
| **Factory + Router** | `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b` |
| **Events + views hub** | `0xdEBA423Ab2D46650061555aaBEC362673c811b44` |
| **Vesting locker** | `0xF37b72a3cB71489F2b95Cf7373681a28AFEfD1A8` |
| **Token implementation** | `0x74a1951f6dB8cB6cd2D2099fa0d020Fb0C52fd9B` |

### Sample of buy swap

[`0x4718e7b1f219dd46c5f51b492d3c0962220c41059067448212ebb29c3022b532`](https://stablescan.xyz/tx/0x4718e7b1f219dd46c5f51b492d3c0962220c41059067448212ebb29c3022b532)

### Sample of sell swap

[`0x3b31c2be4901e561247d5412c67a91607dff79ddb36a5dde6060ae362e743676`](https://stablescan.xyz/tx/0x3b31c2be4901e561247d5412c67a91607dff79ddb36a5dde6060ae362e743676)

### Sample pool / bonding curve initialization event

There is **no bonding curve**. The pool is a standard Uniswap V3 pool created
and initialized inside the `create()` transaction:

[`0xcc344e68f5de6fe42324bc38563b25ce773e60eadc00b7b1bac3e0f5efda1fa5`](https://stablescan.xyz/tx/0xcc344e68f5de6fe42324bc38563b25ce773e60eadc00b7b1bac3e0f5efda1fa5)

The `Created` event in this transaction contains: token address, creator,
name, symbol, metadataURI, pool address, startSqrtPriceX96, poolFee,
burnShareWad.

### Sample graduation event

No token has graduated yet on the current deployment — see
[§8 Graduation](#8-graduation-the-event-integrators-should-watch) for the
exact event signatures, topic0 hashes and detection guidance. The short
version: subscribe to `TokenGraduated(address,address)` (topic0
`0x806ef27e…`) on the hub address.

---

## Explorer links

| Chain | Transactions | Tokens | Addresses |
|---|---|---|---|
| Ethereum | `https://etherscan.io/tx/{hash}` | `https://etherscan.io/token/{address}` | `https://etherscan.io/address/{address}` |
| Robinhood Chain | `https://robinhoodchain.blockscout.com/tx/{hash}` | `…/token/{address}` | `…/address/{address}` |
| Stable | `https://stablescan.xyz/tx/{hash}` | `https://stablescan.xyz/token/{address}` | `https://stablescan.xyz/address/{address}` |

---

## API endpoints

| Endpoint | Description |
|---|---|
| `GET https://diggers.fun/api/token-info` | Paginated token list (DexScreener-shaped) |
| `GET https://diggers.fun/api/token-info/{address}` | Single token detail |
| `GET https://diggers.fun/tokenlist.json` | Uniswap token-list schema |
| `GET https://diggers.fun/llms.txt` | AI/LLM crawler summary |

All endpoints serve CORS `*` and `Cache-Control: public, s-maxage=60`.
