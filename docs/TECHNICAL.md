# TECHNICAL SPEC

This document is the full technical treatment of the ERC-8056 improvement:
(1) the class-decomposed extension and what it solves, (2) the nonce-based
expiry mechanics and why they beat time-based expiry, and (3) the protocol
use cases the design enables.

---

## Part 1 — The ERC-8056 extension

### 1.1 What it adds

The extension (`IERC8056Composite`, implemented by `ERC8056Composite`)
preserves the vanilla ERC-8056 read/ABI surface — reads, conversion and
balance views behave identically in every regime, including the
post-upgrade migration window — and adds:

- **A named scaling-class enum** `MultiplierClass { Supply, Yield, Other }`.
  Backward compatible: `Supply = 0`, `Yield = 1`, `Other = 2` appended.
- **Per-class cumulative factors.** `uiScalingFactor(class)` and
  `uiScalingFactorAt(class, ts)` read a class factor; the composite
  `uiMultiplier() = Supply × Yield × Other` (canonical `composeUiMultiplier`).
- **Scheduled (pending) updates per class.**
  `setUIMultiplier(class, newMultiplier, effectiveAtTimestamp, id, description, uri)`
  schedules an absolute multiplier together with **announcement metadata**:
  an off-chain identifier (`id`), a human-readable `description`, and a
  `uri` pointing at supporting documents. Scheduling emits

  ```solidity
  event UIScalingFactorUpdated(
      MultiplierClass indexed scalingClass,
      uint256 newMultiplier,
      uint256 multiplierRatio,
      uint256 effectiveAtTimestamp,
      uint256 classNonce,
      Announcement announcement   // struct { string id; string description; string uri; }
  );
  ```

  plus the base `UIMultiplierUpdated` carrying the projected pending
  composite. Nothing activates before `effectiveAtTimestamp` — a pending
  update does not move today's multiplier.
- **Cancel pending updates per class.** `cancelPendingUIMultiplier(class)` removes a
  pending update, restoring the active factor. Emits `UIMultiplierCancelled`
  (base) and `UIScalingFactorCancelled` (extension). Reverts with
  `NothingToCancel()` if no pending update exists.
- **A checkpoint history per class.** `scalingCheckpointAt`, `scalingHistoryLength`. Each checkpoint is `{effectiveAt, cumulativeMultiplier, multiplierRatio}`. Once a checkpoint becomes effective it is permanent; a scheduled-but-not-yet-effective (pending) checkpoint is replaced if rescheduled, so only *landed* events are frozen.
- **A yield-event log and nonce.** `getClassNonce(MultiplierClass.Yield)` counts effective Yield
  updates; `classEventAtNonce(MultiplierClass.Yield, nonce)` returns `{timestamp, cumulativeMultiplier, multiplierRatio}`. This is the
  backbone of the Capital/Yield split.

### 1.2 What it solves

The single-multiplier ERC-8056 cannot tell a split from a dividend. The
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

`getClassNonce(MultiplierClass.Yield)` is *derived* from the Yield checkpoint history: it counts
checkpoints with `effectiveAt <= now`, skipping the genesis checkpoint (index 0)
and any pending (future) updates. `classEventAtNonce(MultiplierClass.Yield, nonce)` maps nonce `n` to
checkpoint index `n` (`1`-based events; genesis is not an event). This means:

- No *additional* storage for the event log — the nonce and events are read
  straight from the Yield checkpoint history (which exists for scaling anyway),
  rather than a separate event array.
- A scheduled-but-not-effective update does **not** consume a nonce.
- The nonce ticks **only** when a dividend actually lands.

### 1.5 Integration: in-ERC vs standalone (WETH-style)

The Capital/Yield split can be shipped two ways, mirroring how **WETH is
to ETH**: ETH defines the asset; a standalone wrapper adapts it for
ERC-20-interoperable use.

1. **Standalone wrapper.** A separate adapter contract holds raw RWA and
   mints a Capital LegToken and a Yield LegToken (one shared `LegToken`
   contract, deployed twice per window) against the extension's yield
   history. Clean separation, keeps the base token minimal, and lets *any*
   ERC-8056-compatible issuer opt in without changing their token.
   Archived on the `legacy/standalone-wrapper-registry` branch.
2. **In-ERC integration.** The wrapping is folded directly into the token —
   [`ERC8056CompositePairWrapper`](../src/token-side/ERC8056CompositePairWrapper.sol)
   is the composite AND the Capital/Yield factory in one contract, advertised
   via ERC-165 (`IERC8056PairWrapper`), with a self-escrow `wrap` (no approval)
   and no registry. Simpler deployment, one integration point, no approval
   ceremony; suited to centralized issuers that already own the multiplier.

This branch ships the in-ERC form (option 2) as the primary integration — see
[INTEGRATION.md](INTEGRATION.md). The standalone form (option 1) remains on
the `legacy/standalone-wrapper-registry` branch for trustless, multi-issuer
deployments. For a proposal, the
distinction matters: the extension defines the *standard* interface, and the
splitter is an *optional consumer* any compliant token can adopt — in-ERC when
the issuer is the authority, standalone when the wrapper deployer is a
separate, less-trusted party.

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
- The position matures when `getClassNonce(MultiplierClass.Yield) >= targetNonce` — i.e. when the
  target **event** actually happens, not when a clock crosses a date.

### 2.3 The core: event-based expiry

The yield claim is priced **frozen at the target nonce**, from historical
checkpoints only:

```
Y_s = classEventAtNonce(MultiplierClass.Yield, start).cumulativeMultiplier     # multiplier when the window opened
Y_t = classEventAtNonce(MultiplierClass.Yield, target).cumulativeMultiplier    # multiplier when the window matured

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
  `classEventAtNonce(MultiplierClass.Yield, target)` stays readable forever and the payout is deterministic.

### 2.4 The CA-push / nonce system

Because yield arrives as discrete events, the contract must learn *when* an
event lands. That is the **central authority (CA) push** — the issuer (or a
designated keeper) calls
`setUIMultiplier(MultiplierClass.Yield, newMultiplier, effectiveAtTimestamp, id, description, uri)`
when a dividend is distributed (the `id`/`description`/`uri` fields carry the
announcement metadata for that dividend). The nonce ticks when that pushed
update becomes **effective** (`effectiveAtTimestamp` is reached), not at the
moment of the call.
This is the trusted source of truth for "a yield event happened," just as the
issuer is the source of truth for the UI multiplier itself in ERC-8056.

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

| Path | When | Payout | Returns |
|------|------|--------|---------|
| `unwrap` (both legs) | anytime | exactly `amount` | `amount` |
| `unwrapYield` | `getClassNonce(MultiplierClass.Yield) >= target` | `amount × coupon` | `amount × coupon` |
| `unwrapCapital` | `getClassNonce(MultiplierClass.Yield) >= target` | `amount × (1 - coupon)` | `amount × (1 - coupon)` |

Every redemption function **returns the exact raw amount released** — the same
figure carried in the corresponding event (`Unwrapped`, `UnwrapYield`,
`UnwrapCapital`) and guaranteed to equal the matching `previewUnwrap*` call
immediately before. Callers therefore get on-chain, in-transaction access to
the per-leg raw amounts without reading balance deltas or parsing events; the
events remain for indexers. Adding return values to these functions is
selector-compatible: return types do not affect function selectors, so
existing callers and calldata are unaffected.

Because `coupon + share = 1`, every pair's total claim equals its deposit, so a
**single shared raw vault stays solvent by construction**: total claims never
exceed `rawLocked`.

---

## Part 3 — Use cases

With a precise, event-accurate Capital/Yield split, protocols can treat RWA like
any composable ERC-20 pair. The wrapper mints two fungible, transferable,
ERC-20 tokens per window — a **Capital LegToken** (principal share) and a
**Yield LegToken** (coupon share), both instances of one shared `LegToken`
contract deployed twice — that protocols can plug into existing rails.

### 3.1 Lending

- **Lend the principal, keep the yield.** A lender deposits the Capital
  LegToken (claims principal) and accrues/sells the Yield LegToken as the
  interest leg.
- The stable, principal-protected nature of the capital leg (`share = 1 - coupon`,
  floor at 1x when `Y_t <= Y_s`) makes it a conservative lending collateral.
- The yield leg is a clean "income asset" that can be transferred, priced, or
  sold separately.

#### 3.1.1 Oracle integration: deriving real-world prices

Chainlink's production [Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
(SVR) already embed the issuer's `uiMultiplier()` in every published price, so
a protocol can value these tokens either derivatively (feed as-is) or as a
real-world asset by eliding the multiplier — and with the composite's class
decomposition, by eliding **only** the Yield factor, keeping the split-adjusted
real-world denomination intact. Full formulas, the corporate-action pause
workflow, and an oracle-consumer checklist:
[CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md](CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md).

### 3.2 Options

- **Write the yield upside.** An option can be collateralized with the Yield
  LegToken — the payoff is literally the window's accrued yield.
- Because the yield coupon is **frozen and deterministic** once the target nonce
  is reached, options can be priced and settled against a known payoff, not a
  fluctuating current multiplier.
- Capital tokens give the option writer a principal-backed base.

### 3.3 Auctions

- **Auction future distributions.** A window's Yield LegToken (the right to
  that window's coupon) is a natural auction lot: "who pays for this window's
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

## Part 4 — Migration & Deployment guide

### 4.1 Deploying a composite token fresh

1. Deploy `ERC8056Composite(name, symbol, initialOwner)` directly. The
   constructor seeds every class with a genesis checkpoint
   (`effectiveAt = 0`, `cumulativeMultiplier = 1e18`) and emits the initial
   `UIMultiplierUpdated`.
2. Hand `initialOwner` to a timelock / multisig (see §4.3) before any
   `setUIMultiplier` call is expected.
3. Verify ERC-165: the contract reports `IERC8056Composite`,
   `IERC8056NewUIMultiplier` (`0x4bd27648`), `IERC8056Cancel`, and the other
   base ERC-8056 interface IDs.
4. Optional Capital/Yield surface: deploy the token as
   `ERC8056CompositePairWrapper` so the composite itself implements
   `IERC8056PairWrapper` (ERC-165-discoverable, self-escrow `wrap`, no
   registry — see [INTEGRATION.md](INTEGRATION.md)).

### 4.2 Upgrading a live vanilla ERC-8056 beacon proxy

An upgraded proxy needs **no initialization transaction** thanks to *lazy
genesis* plus read-time inheritance of the vanilla slots.

1. **Verify storage layout compatibility.** `ERC8056Composite` inherits
   `ERC8056` and appends all class state after the base layout; the base
   slots (`_uiMultiplier`, `_newUIMultiplier`, `_effectiveAt`) are preserved
   and — until the first schedule — actively served. Confirm with
   `forge inspect ERC8056Composite storage-layout` that the base slots are
   unchanged for your deployed vanilla version.
2. **Point the beacon at the new implementation.** Standard beacon upgrade;
   no init call is required or expected.
3. **Done — note the post-upgrade view semantics:**
   - **The vanilla display denomination is preserved from the moment of the
     upgrade**, not just after bootstrapping. `uiMultiplier()`,
     `uiMultiplierAt(ts)`, `newUIMultiplier()` and `effectiveAt()` serve the
     inherited vanilla base slots until class history exists, so the
     conversion/balance views (`toUIAmount`, `fromUIAmount`, `balanceOfUI`,
     `totalSupplyUI`) show exactly what the vanilla token showed, including a
     live pending vanilla update observed through `newUIMultiplier()` /
     `effectiveAt()`. Only a proxy that was never initialized under the
     vanilla implementation reads as neutral.
   - `scalingHistoryLength(class)` returns **0** until the first schedule on
     ANY class runs; that single call bootstraps genesis checkpoints for every
     still-empty class at once (`scalingHistoryLength(Supply)` will therefore
     be 1 afterwards even if Supply itself was never scheduled).
   - `classEventAtNonce(class, 0)` returns a **synthetic genesis event**
     `{timestamp: 0, cumulativeMultiplier: 1e18, multiplierRatio: 0}` while the
     history is empty (matching direct deploys), so degenerate wrapper windows
     `(0, 0)` stay readable. Nonces > 0 revert until the first schedule lands.
     Be aware that the first schedule backfills this genesis checkpoint
     retroactively (timestamp 0): timestamp-indexed views at pre-upgrade times
     go from reverting / neutral to returning the seeded factor.
   - A vanilla pending update that has NOT landed by the time of the first
     schedule is never silently abandoned: the first classed schedule reverts
     with `VanillaPendingUpdate(vanillaEffectiveAt)` until the pending
     resolves. Two resolution paths exist — let the vanilla update land at its
     natural effective time, or cancel it via `cancelPendingUIMultiplier()`
     (which during the window applies exact vanilla slot semantics). Per-class
     factor views compose coherently throughout the window:
     `uiScalingFactor[At](Supply, ts)` reports the inherited vanilla value
     while Yield/Other stay neutral, so the product of class factors always
     equals `uiMultiplier()`.
4. After the first schedule per class, indexing matches direct deploys
   exactly.

### 4.3 Issuer operational guidance

- **Put `setUIMultiplier` behind a timelock.** Schedules are future-effective
  by design; routing them through a timelock gives holders advance,
  on-chain-visible notice and makes the announcement window auditable. A
  delay of at least one settlement cycle is recommended for Yield-class
  pushes, since windows price against these events.
- **Consider raising `minNoticePeriod`.** The issuer can call
  `setMinNoticePeriod(seconds)` (capped at 3650 days) to enforce an on-chain
  minimum announcement window for every future schedule, bounding its own
  power to reprice open yield windows with near-zero notice. Default is 0,
  which keeps vanilla-compatible immediate scheduling; anything above 0 is a
  public, self-imposed trust signal integrators can check.
- **Announcement metadata discipline.** Always populate `id`, `description`,
  and `uri` in the 6-arg setter. `id` should be stable and unique per event
  (e.g. the dividend record date); `uri` should point to the press release or
  ledger document. Empty fields are legal (the legacy 2-arg path emits them)
  but degrade off-chain attribution and audit trails.
- **Class hygiene.** Only Yield-class updates tick the wrapper's yield nonce
  and move coupons; keep splits and re-denominations strictly in Supply so
  capital legs stay principal-flat.

---

## Appendix — glossary

- **UI multiplier** — ERC-8056's display scale (1e18 = 1.0x). Converts raw units
  to UI units.
- **Scaling class** — a named reason for scaling: `Supply`, `Yield`, `Other`.
- **Checkpoint** — `{effectiveAt, cumulativeMultiplier, multiplierRatio}`, one per class per update.
- **Yield nonce** — the count of effective Yield events; the "event clock."
- **Coupon** — the frozen yield fraction of a window: `max(1 - Y_s/Y_t, 0)`.
- **CA push** — the central authority calling the extension when a dividend lands.