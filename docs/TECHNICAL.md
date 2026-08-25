# TECHNICAL SPEC

This document is the full technical treatment of the EIP-8056 improvement:
(1) the class-decomposed extension and what it solves, (2) the nonce-based
expiry mechanics and why they beat time-based expiry, and (3) the protocol
use cases the design enables.

---

## Part 1 — The ERC-8056 extension

### 1.1 What it adds

The extension (`IERC8056Composite`, implemented by `ERC8056Composite`)
keeps every EIP-8056 function untouched and adds:

- **A named scaling-class enum** `UIScalingClass { Supply, Yield, Other }`.
  Backward compatible: `Supply = 0`, `Yield = 1`, `Other = 2` appended.
- **Per-class cumulative factors.** `uiScalingFactor(class)` and
  `uiScalingFactorAt(class, ts)` read a class factor; the composite
  `uiMultiplier() = Supply × Yield × Other` (canonical `composeUiMultiplier`).
- **Scheduled (pending) updates per class.** `setUIScalingFactor(class, factor,
  ts)` schedules an absolute factor; `applyUIScalingDelta(class, delta, ts)`
  applies a relative `new = current × delta / 1e18`. Nothing activates before
  `effectiveAt` — a pending update does not move today's multiplier.
- **A checkpoint history per class.** `scalingCheckpointAt`, `scalingHistoryLength`. Each checkpoint is `{effectiveAt, cumulativeFactor}`. Once a checkpoint becomes effective it is permanent; a scheduled-but-not-yet-effective (pending) checkpoint is replaced if rescheduled, so only *landed* events are frozen.
- **A yield-event log and nonce.** `yieldNonce()` counts effective Yield
  updates; `yieldEventAt(nonce)` returns `{timestamp, multiplier}`. This is the
  backbone of the Capital/Yield split.

### 1.2 What it solves

The single-multiplier EIP-8056 cannot tell a split from a dividend. The
extension makes the **cause** explicit and **priced**:

| Class | Meaning | Backing effect | Wrapper role |
|-------|---------|----------------|--------------|
| `Supply` | split, reverse split, ADR, redenomination | same economics, different count | capital display only |
| `Yield` | dividend, DRIP, distribution, buyback | pool grew pro-rata | **drives nonce + coupon** |
| `Other` | fees, taxes, governance re-denominations | mixed | composes, no pricing |

Because each update carries its class, the protocol knows *which* events created
new yield claims (`Yield`) vs merely re-denominated principal (`Supply`). The
checkpoint history makes every past event readable, which is what allows a
window to be priced *after the fact*.

### 1.3 The composite is always derived

There is **no** generic monolithic multiplier setter. `uiMultiplier()` is always
the product of every class factor. This guarantees the class decomposition can
never drift out of sync with the displayed multiplier — consistency is by
construction.

### 1.4 The nonce is derived, not stored

`yieldNonce()` is *derived* from the Yield checkpoint history: it counts
checkpoints with `effectiveAt <= now`, skipping the genesis checkpoint (index 0)
and any pending (future) updates. `yieldEventAt(nonce)` maps nonce `n` to
checkpoint index `n` (`1`-based events; genesis is not an event). This means:

- No *additional* storage for the event log — the nonce and events are read
  straight from the Yield checkpoint history (which exists for scaling anyway),
  rather than a separate event array.
- A scheduled-but-not-effective update does **not** consume a nonce.
- The nonce ticks **only** when a dividend actually lands.

### 1.5 Integration: in-ERC vs standalone (WETH-style)

The Capital/Yield split is implemented as a **separate contract**
(`ERC8056PairWrapper`) that consumes the extension. This mirrors how **WETH is
to ETH**: ETH defines the asset; a standalone wrapper adapts it for
ERC-20-interoperable use.

Two equally valid integration paths:

1. **Standalone wrapper (this repo).** `ERC8056PairWrapper` holds raw RWA and
   mints `CapitalToken` / `YieldToken` pairs against the extension's yield
   history. Clean separation, keeps the base token minimal, and lets *any*
   EIP-8056-compatible issuer opt in without changing their token.
2. **In-ERC integration.** The wrapping could be folded directly into the
   token (mint Capital/Yield on the same contract). Simpler deployment, but
   couples the base token to the wrapper's pairing and expiry logic.

This repo ships the standalone form (option 1). The distinction matters for a
proposal: the extension defines the *standard* interface, and the splitter is
an *optional consumer* that any compliant token can plug into — exactly like
WETH sits alongside ETH rather than inside it.

---

## Part 2 — Expiry and nonce-based locks

### 2.1 The problem with time-based expiry (and why Pendle's model doesn't fit)

Time-based expiry is the natural first instinct: "this yield claim is worth 0
after date D." Pendle works this way at a high level — fixed **epochs** in
**calendar time**, with **continuous** yield accrual. That model is coherent for
protocols that accrue yield continuously (an index, a staking yield) because
"expiry at time D" is well-defined.

RWA yield is **not** continuous. Consider a Robinhood-style stock token:

- The issuer updates the UI multiplier **only when a dividend is actually
  distributed** — a discrete event, not a smooth flow.
- A dividend *announced* for 2 June but *landed* on 4 June is simply delayed by
  the issuer's operational schedule.

With a timestamp expiry set to 2 June, a holder's window goes "dead" (worth 0)
on 3 June while the dividend merely hasn't landed yet. **Time-based expiry
penalizes holders for calendar slip the issuer does not control.** The expiry
can fire *before* the multiplier update that was supposed to make the claim
pay — the worst failure mode.

### 2.2 The fix: measure locks in yield events (nonces), not time

Instead of "expire at timestamp D," the lock is expressed as: *"commit to the
next N multiplier updates, whenever they land."*

- `wrap(raw, lockNonces)` at current nonce `N` creates/joins pair
  `(start, target) = (N, N + lockNonces)`.
- The position matures when `yieldNonce() >= targetNonce` — i.e. when the
  target **event** actually happens, not when a clock crosses a date.

### 2.3 The core: event-based expiry

The yield claim is priced **frozen at the target nonce**, from historical
checkpoints only:

```
Y_s = yieldEventAt(start).multiplier     # multiplier when the window opened
Y_t = yieldEventAt(target).multiplier    # multiplier when the window matured

coupon = max(1 - Y_s / Y_t, 0)           # yield leg pays this fraction
share  = 1 - coupon                      # capital leg pays the rest
```

Key properties:

- **The current multiplier is never read for pricing.** Later dividends price
  nothing for a window whose target has passed. (The one exception is
  `previewCapitalUI`, a display-only helper that reads the *current* Supply
  factor; redemption payouts never read the current multiplier.) Unwrapping
  months later pays the same split.
- **Date-slippage immunity.** A dividend delayed by two weeks just makes the
  target event land two weeks later — the holder is *not* penalized.
- **Compatibility with delayed UI updates.** Because expiry is a nonce, not a
  timestamp, a late push by the issuer delays maturity instead of destroying the
  claim. This is exactly the "expiry fires before the multiplier updates"
  failure mode, resolved.
- **Frozen and final.** Effective checkpoints are permanent, so
  `yieldEventAt(target)` stays readable forever and the payout is deterministic.

### 2.4 The CA-push / nonce system

Because yield arrives as discrete events, the contract must learn *when* an
event lands. That is the **central authority (CA) push** — the issuer (or a
designated keeper) calls `applyUIScalingDelta(UIScalingClass.Yield, delta, ts)`
when a dividend is distributed. The nonce ticks when that pushed update becomes
**effective** (its `effectiveAt` is reached), not at the moment of the call.
This is the trusted source of truth for "a yield event happened," just as the
issuer is the source of truth for the UI multiplier itself in EIP-8056.

The nonce gives the wrapper a **nonce-to-nonce window reference** — an asset is
wrapped against `(startNonce, targetNonce)`, so the window is defined by real
economic events rather than by a wall clock.

### 2.5 Estimating duration

Nonce-based locks trade calendar precision for economic accuracy, but you can
still estimate. If dividends are known to distribute **once per year**, then:

- a lock of **2 nonces ≈ 2 years** of commitment,
- a lock of **4 nonces ≈ 4 years**,
- with zero risk that an early calendar expiry destroys a legitimate claim.

The estimate is as good as the issuer's dividend cadence — and it can never
"expire early," only (rarely) mature late.

### 2.6 Redemption summary

| Path | When | Payout |
|------|------|--------|
| `unwrap` (both legs) | anytime | exactly `amount` |
| `unwrapYield` | `yieldNonce() >= target` | `amount × coupon` |
| `unwrapCapital` | `yieldNonce() >= target` | `amount × (1 - coupon)` |

Because `coupon + share = 1`, every pair's total claim equals its deposit, so a
**single shared raw vault stays solvent by construction**: total claims never
exceed `rawLocked`.

---

## Part 3 — Use cases

With a precise, event-accurate Capital/Yield split, protocols can treat RWA like
any composable ERC-20 pair. The wrapper mints two fungible, transferable,
ERC-20 tokens per window — `CapitalToken` and `YieldToken` — that protocols can
plug into existing rails.

### 3.1 Lending

- **Lend the principal, keep the yield.** A lender deposits `CapitalToken`
  (claims principal) and accrues/sells `YieldToken` as the interest leg.
- The stable, principal-protected nature of the capital leg (`share = 1 - coupon`,
  floor at 1x when `Y_t <= Y_s`) makes it a conservative lending collateral.
- The yield leg is a clean "income asset" that can be transferred, priced, or
  sold separately.

### 3.2 Options

- **Write the yield upside.** An option can be collateralized with the
  `YieldToken` — the payoff is literally the window's accrued yield.
- Because the yield coupon is **frozen and deterministic** once the target nonce
  is reached, options can be priced and settled against a known payoff, not a
  fluctuating current multiplier.
- Capital tokens give the option writer a principal-backed base.

### 3.3 Auctions

- **Auction future distributions.** A window's `YieldToken` (the right to that
  window's coupon) is a natural auction lot: "who pays for this window's
  yield?"
- Windows are fungible within the same `(start, target)` nonce pair, so lots can
  be aggregated and cleared cleanly.
- The nonce-based expiry means the auctioned right matures on a real economic
  event, never on a possibly-wrong calendar date.

### 3.4 Anything that needs "I own it" ≠ "I own its growth"

The general primitive is: **separate ownership of the asset from ownership of
its yield**, on a token that only publishes UI scaling. Lending, options,
auctions, perpetuals, and structured products all reduce to this split once it
is sound and composable.

---

## Appendix — glossary

- **UI multiplier** — EIP-8056's display scale (1e18 = 1.0x). Converts raw units
  to UI units.
- **Scaling class** — a named reason for scaling: `Supply`, `Yield`, `Other`.
- **Checkpoint** — `{effectiveAt, cumulativeFactor}`, one per class per update.
- **Yield nonce** — the count of effective Yield events; the "event clock."
- **Coupon** — the frozen yield fraction of a window: `max(1 - Y_s/Y_t, 0)`.
- **CA push** — the central authority calling the extension when a dividend lands.