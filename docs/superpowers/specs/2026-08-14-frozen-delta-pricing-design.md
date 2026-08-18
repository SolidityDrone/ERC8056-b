# ScaledPairWrapper: Frozen-Delta (Window Coupon) Pricing

Date: 2026-08-14
Status: Approved design, not yet implemented

## Problem

The current pool model prices both legs at the *current* yield multiplier at unwrap
time. A yield token therefore keeps accruing value from dividends that land after its
lock expired. The user wants each pair's claims **frozen at its expiry nonce**: a yield
token pays only what its window earned, and later multipliers price nothing for it.

## Model

### Pair identity

- `wrap(raw, lockNonces)` at current nonce `N` creates/joins pair `(start, target) = (N, N + lockNonces)`.
- Tokens: `Capital-<start>-<target>` / `Yield-<start>-<target>`, symbols `Cap<start>-<target>` / `Yld<start>-<target>`.
- Pairs are fungible only within identical windows. Lazy creation; re-wrapping merges fungibly.

### Pricing (frozen delta, historical only)

- `Y_s = yieldEventAt(start).multiplier`, `Y_t = yieldEventAt(target).multiplier` (absolute
  factors from the extension's append-only checkpoint history).
- Yield coupon per token: `max(1 - Y_s/Y_t, 0)`
- Capital share per token: `1 - coupon = min(Y_s/Y_t, 1)`
- Claims are stable forever once `target` is effective; the wrapper never reads the
  current multiplier (except Supply class for `previewCapitalUI`, unchanged).

### Redemption rules

- `unwrap(amount, start, target)`: burn both legs, pay exactly `amount`, ANYTIME.
- `unwrapYield(amount, start, target)`: `amount * coupon`, gated `yieldNonce() >= target` else `Locked()`.
- `unwrapCapital(amount, start, target)`: `amount * capitalShare`, same gate.
- Floors: `Y_t <= Y_s` (incl. markdowns below 1x) -> coupon 0, capital full. Principal protected.

### Solvency

Single shared raw vault. Every pair's total claim equals its deposit (coupon + share = 1),
so total claims <= `rawLocked` at all times. `InsolventPool` error is removed.

## Interface changes

- `pairs(uint256 start, uint256 target)` view -> `Pair` struct.
- Enumeration: `pairAt(uint256 index) returns (uint256 start, uint256 target)`, `pairCount()`.
- Views: `currentNonce()`, `capitalSupply()`/`yieldSupply()` (global), `capitalSupplyOf`/
  `yieldSupplyOf(start, target)`, `couponOf(start, target)`, `previewUnwrap` (exact amount),
  `previewUnwrapYield`/`previewUnwrapCapital(start, target)`, `previewCapitalUI` (unchanged).
- Events: `Wrapped(user, raw, startNonce, targetNonce)`, `Unwrapped(user, start, target, amount,
  capOut, yldOut)`, `UnwrapYield(user, start, target, amount, rawOut)`,
  `UnwrapCapital(user, start, target, amount, rawOut)`.
- Errors: `InvalidAmount`, `PairNotFound`, `Locked`. `EventNotRecorded`/`EventNotEffective`
  bubble from the extension.

## Edge cases

- `lockNonces = 0` -> pair `(N, N)`, coupon 0, capital full; equal-leg still exact 1:1.
- Pending (scheduled) dividends never tick the nonce, so they never affect an existing pair's pricing.
- Checkpoint history is append-only: `yieldEventAt(target)` stays readable forever.

## Verification

Unit tests (rewritten) + invariant tests + fuzz tests:

- Invariant: claims <= rawLocked at all times (solvency).
- Invariant: equal-leg unwrap pays exactly the burned amount, always.
- Invariant: per-pair claims frozen - redemption value identical before/after later dividends.
- Invariant: no raw stuck - full unwrap of all pairs drains the vault to zero.
- Fuzz: coupon/share math, delta floor, pool accounting round-trip, wrap/unwrap sequences.
