# "Unsafe Contract"? Reading the Diggers flags like an auditor

Every Diggers token trips the same three warnings on automated security
scanners — GoPlus (the panel DexScreener embeds), GMGN's audit box, and
friends:

| Scanner claim | Severity shown | What it actually is |
|---|---|---|
| "UnauthorizedTransfer — the launchpad and locker can transfer tokens from any holder without approval" | HIGH | The approve-free sell. The pull is hard-bound to `msg.sender` of the call the holder made, inside that same transaction |
| "LiquidityDrain — the launchpad can sweep all native ETH and ERC-20 held by this contract" | MEDIUM | The buyback donation box. Swept funds have exactly one exit: swapped for the token and **burned**. Pool liquidity is untouchable |
| "External call / Owner can change balance" | warning | Transfer-hook telemetry (points, holders, epochs) and the same allowance-skip, seen through a pattern matcher |

These scanners do one thing: bytecode pattern-matching. They ask *"does a
code path exist where a privileged address moves someone else's tokens?"* —
and in Diggers, one does, **on purpose, with constraints the scanner cannot
see**. This document walks through every flag against the actual source.
Every line quoted below is in this repository and verified on-chain on all
three deployments.

---

## Claim 1 — "UnauthorizedTransfer" (the approve-free sell)

### What the scanner sees

`DiggersToken.transferFrom` skips the allowance check for two callers:

```solidity
// DiggersToken.sol
function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    if (to == address(0)) revert ZeroAddress();
    if (msg.sender != LAUNCHPAD && msg.sender != LOCKER) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert AllowanceTooLow(allowed, amount);
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
    }
    _update(from, to, amount);
    return true;
}
```

A pattern matcher reads this as *"LAUNCHPAD can move anyone's balance"* and
files it under the classic rug primitive. Mechanically true. Practically —
look at the only code that ever exercises that branch.

### What the launchpad actually does with it

`LAUNCHPAD` and `LOCKER` are **immutable contract addresses**, baked in at
deployment. Not EOAs, not multisigs, not proxies — bytecode you can read.
The launchpad calls `transferFrom` in exactly one flow: **your own sell**.

When you call `sell()`, the launchpad stashes *your* address in EIP-1153
transient storage — storage that only lives for the duration of the
transaction:

```solidity
// Diggers.sol
function sell(address token, uint256 amountIn, uint256 minOut, address to) external {
    if (amountIn == 0) revert ZeroSwapAmount();
    _trade(token, false, amountIn, minOut, to == address(0) ? msg.sender : to, true);
}

function _trade(...) private {
    _requireToken(token);
    _maybeHarvest(token);
    if (sellMode) _stashSellPayer(msg.sender);   // ← the ONLY address ever stashed
    DiggerV3.SwapOutcome memory out = _swapV3(...);
    if (sellMode) _dropSellPayer();              // ← cleared before the tx ends
    ...
}
```

And the pull can only target that stashed address:

```solidity
// Diggers.sol — the ONE call site of the allowance-skip
function _transferToken(address token, address to, uint256 amount) internal override {
    address payer = _loadSellPayer();
    if (payer != address(0)) {
        DiggersToken(payable(token)).transferFrom(payer, to, amount);  // payer == the seller
    } else {
        DiggersToken(payable(token)).transfer(to, amount);
    }
}
```

The chain is airtight: the *only* `from` the launchpad can ever pass is the
`msg.sender` of a `sell()` call — i.e. **you, selling your own tokens, in
the transaction you signed**. There is no function, owner-gated or
otherwise, that stashes any other address. Outside an active sell the
transient slot is zero and the branch is dead. The locker is the same
story — its batch-vesting pull is hardcoded to the outer caller:

```solidity
// DiggersLocker.sol — multiLock
DiggersToken(payable(token)).transferFrom(msg.sender, address(this), sum);
```

### Why we built it this way

Because we want trading on the EVM to feel the way it always should have:
**one tap, one transaction** — no "approve first", no second signature, no
gas spent on permission before you can sell. To get there, the token carves
out a single, surgical exception and nothing more:

- **Only one address can do this.** The Diggers launchpad (plus the vesting
  locker) — immutable contracts, deployed once, no admin, no upgrade path.
  The exemption is hardcoded to them.
- **Only in one situation.** A sell (or lock escrow) you initiated
  yourself: the pull is bound to `msg.sender` of your own call, inside your
  own transaction, and the binding evaporates when the transaction ends.
- **Every other contract follows normal rules.** Routers, aggregators, any
  dApp — they all need a standard ERC-20 `approve` from you, exactly like
  any other token. The ERC-20 standard is not weakened for anyone else.

It is secure *because* of how narrow it is: the launchpad physically cannot
name anyone but the outer caller as `from` — no function exists that writes
any other address into that transient slot. The exemption is not a
permission someone holds; it is a reflex triggered by your own signature.
A welcome side effect: since you never approve anything, no standing
allowance is ever left on-chain afterward — nothing to clean up, nothing
to revoke.

---

## Claim 2 — "LiquidityDrain" (the buyback donation box)

### What the scanner sees

```solidity
// DiggersToken.sol
function sweepDonations() external returns (uint256 amount) {
    if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
    amount = address(this).balance;
    if (amount == 0) return 0;
    (bool ok,) = LAUNCHPAD.call{value: amount}("");
    if (!ok) revert SweepFailed();
}

function sweepErc20(address erc20) external returns (uint256 amount) {
    if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
    amount = IWETH9(erc20).balanceOf(address(this));
    if (amount == 0) return 0;
    if (!IWETH9(erc20).transfer(LAUNCHPAD, amount)) revert SweepFailed();
}
```

*"The launchpad can sweep all native and ERC-20 value held by the token
contract."* True — and deliberately so. But note what's being swept:
**the token contract's own balance**, not the pool, and not any holder.

### What that balance is, and where it can go

The token address doubles as a **public buyback donation box**: anyone can
send ETH (or WETH, or USDT0 on Stable) straight to the token contract, and
creators can route a share of their fee stream there automatically. The
sweep exists so the launchpad can spend that pot — and it has exactly one
spender and one destination:

```solidity
// Diggers.sol — the ONLY consumer of the sweeps
function execBuyback(address token, uint256 userAmountOut) external {
    if (msg.sender != address(this)) revert NotSelf();   // self-call only

    TokenRecord memory rec = _tokenRecords[token];
    (uint256 spend, uint256 minOut) = DiggerBuybackLib.prepare(
        token, WETH, rec.pool, rec.poolFee, userAmountOut, ...   // sweeps the pot
    );
    if (spend == 0) return;

    DiggerV3.SwapOutcome memory out = _swapV3(rec.pool, token, true, spend, address(this), minOut);
    DiggersToken(payable(token)).burn(out.amountOut);    // ← the only exit: a burn
    IDiggersHub(HUB).logBuybackBurned(token, spend, out.amountOut);
}
```

`execBuyback` can only be invoked by the launchpad itself (triggered
automatically after buys), the swept value is immediately market-bought
into the token, and the bought tokens are **burned** — publicly logged via
`BuybackBurned`. There is no code path from the sweep to any wallet, team
or otherwise. Calling this "LiquidityDrain" gets it exactly backwards: the
mechanism *removes tokens from supply* and puts buy pressure on the pool.

The timing is deliberate too: the buyback piggybacks on a buy that has
**already settled** — it runs at the tail of the user's transaction, after
their tokens are delivered at their price:

```solidity
// Diggers.sol — inside _trade(): the user's swap settles FIRST...
DiggerV3.SwapOutcome memory out = _swapV3(_pool(token), token, isBuy, amountIn, recipient, minOut);

// ...and the buyback rides at the very END of the same transaction,
// on BUYS only — a sell can never unlock a pot spend.
if (isBuy) _maybeBuyback(token, out.amountOut);  // user's output = the buyback's size cap

function _maybeBuyback(address token, uint256 userAmountOut) private {
    ...
    try this.execBuyback(token, userAmountOut) {} catch {}  // can never revert the trade
}
```

Three guarantees in four lines. The buyer's fill is locked in before the
pot spends anything, so it cannot front-run or sandwich them. The spend is
sized in `DiggerBuybackLib.prepare` so the buyback's token output can
never exceed the carrying buy's own output — when the full pot would, the
spend is scaled down to `pot · userOut / fullOut` and then given a further
20% safety haircut. A dust buy can only ever unlock a dust buyback; the
pot can never move the price by more than the buy it rides on. And the whole flow is
a try/caught self-call: a buyback failure can never revert the user's
trade. The buyback only ever pushes the price *after* the buyer is
already in.

### Why we built it this way

We wanted buyback-and-burn to be a *mechanism*, not a promise. The usual
setup — fees flow to a team wallet, and the team pinky-swears to buy back —
is exactly the thing users shouldn't have to trust. So we removed the
wallet: the pot lives **on the token contract itself**, anyone can top it
up with a plain transfer (no special function, no approval — just send),
creators can route a slice of their fees into it automatically, and the
only thing the code can do with that balance is buy the token and burn it.
No treasury, no discretion, no "next week." The sweep functions the
scanner flags are the plumbing that makes the promise unnecessary.

### The liquidity itself cannot be drained — by anyone

The actual pool liquidity, which the flag's name implies is at risk:

- The launchpad is the **sole LP** of every pool, holding one single-sided
  position seeded at launch with the full 1B supply.
- The launchpad has **no function to decrease or withdraw that position**.
  Grep this repo for it — it does not exist. Fees are collectable
  (`harvest`); principal is not.
- No proxy, no upgrade path, no `selfdestruct`. What's deployed is final.

A "liquidity drain" requires a withdrawal function. There isn't one.

---

## Claim 3 — "External call: Yes" / transfer hooks

The mildest flag, and simply a description of the architecture. Every
Diggers token's `_update` (the internal transfer pipeline) does real work
on pool trades:

- credits **digging points** (buys 4×, sells 1×) for the daily trader contest,
- maintains the **holder counter** and top-10 leaderboard,
- records **graduation telemetry** (cumulative volume, daily ticks),
- lazily settles the **24h epoch** and pays the pot to the day's winners,
- relays each of these to the DiggersHub event singleton.

Those are external calls during a transfer — that's what an on-chain
trade-to-earn engine looks like:

```solidity
// DiggersToken.sol — inside _update(): these ARE the "external calls"
if (buyLeg || sellLeg) {
    DiggerV3.Slot0 memory slot0 = DiggerV3.getSlot0(pool);   // read the pool's spot price
    uint256 ethValue = DiggerMath.md512(amount, ..., 1e18);
    volumeEthCum += ethValue;                                // graduation telemetry
    _dailyTick[block.timestamp / 1 days] = DayTick({tick: slot0.tick, recorded: true});

    IDiggersHub(HUB).logPoolTrade(                           // the public trade feed
        buyLeg ? to : from, buyLeg, amount, ethValue, slot0.tick, holderCount, volumeEthCum, epoch
    );

    _applyGuardedRewards(buyLeg ? to : from, amount, buyLeg); // digging points
}
```

Read what those calls actually are: a **static read** of the pool's price,
an **event relay** to the DiggersHub (an immutable contract whose only job
is printing logs), and the points engine. No value moves, no called address
is user-controlled, and the points path runs through a same-block
round-trip guard — a flash-loan buy-then-sell earns exactly zero.

### Why we built it this way

Because we wanted the entire game to live on-chain. Digging points, the
top-10 leaderboard, the daily pot, graduation — on most platforms those
run on a company server: an off-chain indexer counts trades, an admin
script picks the winners, and users trust the website. We put all of it in
the token's own transfer pipeline, where it cannot be paused, edited, or
run selectively — and relayed everything to one hub address so any indexer
can verify every point ever credited. The "external calls" are the cost of
making the leaderboard as trustless as the balances.

The same flag fires for every token with any transfer hook (reflections,
taxes, rebase, hooks of any kind). Meanwhile the checks that measure actual
trading risk are green on every scanner: **0% buy tax, 0% sell tax, not
modifiable, no honeypot, no hidden owner, no blacklist, no pause**.

---

## What a rug would actually require — and what exists

| Rug vector | In Diggers |
|---|---|
| Mint more supply | No mint function. Supply is fixed at 1e9 and **only decreases** (burns) |
| Pull the liquidity | No withdrawal function on the sole LP position |
| Seize / freeze balances | No owner on the token, no blacklist, no pause, no forced transfer path — the allowance-skip is bound to the holder's own `msg.sender` |
| Raise taxes | No tax variables. 0% is not a setting, it's the absence of the code |
| Upgrade the rules | No proxies anywhere. Tokens are EIP-1167 clones of one immutable implementation; launchpad, hub and locker are plain immutable contracts |
| Owner overreach | The launchpad's single bounded owner can adjust protocol fee routing and open/close creation — it has **no power over balances, supply, liquidity or past accruals**, and can renounce |

## Verify everything yourself

- **Sources:** this repository — `DiggersToken.sol`, `Diggers.sol`,
  `DiggersLocker.sol`, `DiggersHub.sol`. Every claim above is a grep away.
- **Deployments (same addresses on Ethereum, Robinhood Chain, Stable):**
  launchpad `0x5044E79669Fee78A7bC2007A8e7AE4f820252e4b`, hub
  `0xdEBA423Ab2D46650061555aaBEC362673c811b44`, locker
  `0xF37b72a3cB71489F2b95Cf7373681a28AFEfD1A8`, token implementation
  `0x74a1951f6dB8cB6cd2D2099fa0d020Fb0C52fd9B`.
- **Live transactions, selectors and event topics:** [FUNCTIONS.md](FUNCTIONS.md).
- **Behavioral guarantees** (the allowance exemption can only move the
  outer caller's own tokens inside a sell; pot/fee solvency; supply only
  decreases) are held as invariants in the protocol's fuzz/invariant test
  suite.

Automated scanners are useful — they catch lazy rugs. But they grade
patterns, not intent, and they cannot follow a transient-storage constraint
across two contracts. Diggers chose an approve-free, hook-driven design
precisely because it removes the failure modes (standing allowances,
migration snipes, removable liquidity) that actually hurt people. The
flags are the fingerprint of that choice.

*Found something real? Open an issue — or better, tell us privately first:
[@DIGGERSdotFUN](https://x.com/DIGGERSdotFUN).*
