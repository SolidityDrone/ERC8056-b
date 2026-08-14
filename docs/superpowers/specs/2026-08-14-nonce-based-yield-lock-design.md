# Nonce-Based Yield Lock (Event-Based Expiry)

Date: 2026-08-14

## Problem

The earlier wrapper draft had a time-based expiry. That breaks down for RWA
yield: Robinhood updates the UI multiplier only when a dividend is actually
distributed, so yield accrues in discrete events, not continuously. A dividend
expected on 2 June but landed on 4 June leaves a dead window where the yield is
"expired" (worth 0) while the dividend was merely delayed. Time-based expiry
penalizes holders for calendar slip the issuer does not control.

## Solution

Measure locks in **yield events (nonces)**, not time. A lock of `N` commits a
position to the next `N` multiplier updates, whenever they land. Tesla paying
every ~4 months: locking 2 nonces ≈ 8 months of commitment, with zero
date-slippage risk.

## Decisions (confirmed with user)

1. **Lock semantics**: Capital tokens stay liquid (transferable, usable freely).
   Solo unwraps of *either* leg are blocked until the pair's unlock nonce.
   Equal-leg (1:1 Capital + Yield) unwrap is allowed **anytime** — the base
   guarantee. Raw RWA stays in the pool while locks are outstanding, so the pool
   always has liquidity to honor pair unwraps with no slippage.
2. **Granularity**: the lock is chosen **per wrap** (`lockNonces`). Each target
   nonce gets its own Capital/Yield ERC-20 pair (e.g. `Capital-10` / `Yield-10`),
   fungible only within the same expiration.
3. **Pool**: one **shared raw pool** across all expiries.
4. **Nonce timing**: the nonce increments when a yield update becomes
   **effective** (the dividend lands), never at scheduling/announcement. A
   pending update does not consume a nonce; it is the first event a lock
   captures when it lands.
5. **Event recording**: the nonce and event history are **derived from the
   existing Yield checkpoints** (`{effectiveAt, cumulativeFactor}`) — zero new
   storage in the extension.

## Architecture

### Extension (`ScaledUIClassedToken` / `IScaledUIAmountClasses`) — read-only additions

The Yield-class checkpoint history already is the event log: each effective
update is `{timestamp, multiplier}`. New views:

- `yieldNonce()` — count of Yield checkpoints with `effectiveAt <= now`, minus
  the genesis checkpoint. `0` before any dividend.
- `yieldEventAt(nonce)` — returns `{timestamp, multiplier}` of the event with
  that nonce (checkpoint index `nonce + 1`).
- Supply/split updates never touch the nonce ("just yield").

Pending updates are automatically excluded (`effectiveAt` in the future), and
rescheduling a pending update pops and re-pushes it, so effective events are
contiguous from checkpoint index 1.

### Wrapper (`ScaledPairWrapper`) — pair registry + lock

- `mapping(uint256 unlockNonce => Pair)` with
  `Pair { CapitalToken capital; YieldToken yield; }`, created lazily on first
  wrap. Token names: `Capital-<nonce>` / `Yield-<nonce>`, symbols
  `CAP<nonce>` / `YLD<nonce>`.
- `wrap(rawAmount, lockNonces)` — `unlockNonce = yieldNonce() + lockNonces`;
  mints 1:1 Capital/Yield of that pair; `rawLocked += rawAmount` (one shared
  pool).
  - `lockNonces = 0` → pair for the current nonce; solo unwrap allowed
    immediately.
  - `lockNonces = 2` → solo redemption unlocked only after the 2nd future
    dividend lands, regardless of calendar slip.

## Pool math

All claims use the floored yield factor `Y = max(yieldFactor, 1e18)`.

### Global invariant (preserved by every operation)

```
rawLocked = capitalSupplyTotal / Y + yieldSupplyTotal × (1 − 1/Y)
```

Consequences:

- **Uniform per-token yield value across all expiries**:
  `yieldPerTokenRaw = pool / yieldSupplyTotal = 1 − 1/Y`. The same for
  `Yield-2` and `Yield-10`; expiry only gates *when* solo redemption is allowed,
  never *how much*.
- **Equal-leg unwrap is exact for any pair, anytime**:
  `amount/Y + amount×(1 − 1/Y) = amount`.
- **Solvency always holds**: capital claim `capitalSupplyTotal / Y <= rawLocked`,
  so pair unwraps never run short ("always liquidity, no slippage").
- Solo unwraps preserve the invariant: per-token values stay uniform and
  remaining holders are unaffected.
- The floor (Y < 1) keeps the pool at zero, capital claims at 1:1 — no lock-in,
  no insolvency, same behavior as today.

## Redemption paths

| Path | When | Payout |
|---|---|---|
| `unwrap(amount, unlockNonce)` — equal-leg (both legs of the *same* pair) | anytime | `amount/Y` capital + `amount×(1−1/Y)` yield = `amount` |
| `unwrapYield(amount, unlockNonce)` | `yieldNonce() >= unlockNonce` | `amount × pool/YS` |
| `unwrapCapital(amount, unlockNonce)` | `yieldNonce() >= unlockNonce` | `amount/Y` |

Unwraps reduce `rawLocked` in step with the payout, keeping the pool exactly
backed per leg.

## Views, events, errors

**Views** (uniform across pairs unless noted): `yieldNonce()` (delegates to the
extension), `unlockNonceOf(n)`, `capitalSupplyOf(n)`, `yieldSupplyOf(n)`,
`pairCount()`, `capitalRawValue(a)`, `poolYieldRaw()`, `yieldPerTokenRaw()`,
`previewUnwrap(amount, n)`, `previewUnwrapYield(amount, n)`,
`previewUnwrapCapital(amount, n)`.

**Events**: `Wrapped(user, rawAmount, unlockNonce)`,
`Unwrapped(user, unlockNonce, amount, capitalRawOut, yieldLegRawOut)`,
`UnwrapYield(user, unlockNonce, amount, rawOut)`,
`UnwrapCapital(user, unlockNonce, amount, rawOut)`.

**Errors**: existing `InvalidAmount`, `InsolventPool`; new `Locked()` (solo path
before its nonce), `PairNotFound()` (unwrap on a never-created pair).

## Edge cases

- `lockNonces = 0` → immediate solo redemption, pair = current nonce.
- Wrap after some dividends already landed → the lock counts *future* events
  only (`currentNonce + N`).
- Pending/announced update does not consume a nonce at wrap time, but is the
  first event the lock captures when it lands (short-lock case: wrap at nonce 1
  with nonce 2 pending, lock 1 → expires at nonce 2).
- Tokens from expired pairs stay redeemable forever (solo + pair); expiry
  unlocks, never destroys.
- Any number of pairs can coexist; each pair is fungible only within itself.

## Testing plan

Extend `test/ScaledPairWrapper.t.sol` (existing 43 ERC-8056 tests keep passing;
existing 24 wrapper tests are updated for the new `wrap`/`unwrap` signatures):

1. Extension nonce views: ticks only at `effectiveAt`, pending excluded, genesis
   not counted.
2. Wrap with `lockNonces` → correct `unlockNonce`, pair created, 1:1 mint.
3. Equal-leg unwrap before/after expiry → exact `amount` (existing invariants,
   now per-pair).
4. Solo unwraps blocked pre-nonce (`Locked`), allowed post-nonce, correct
   payouts.
5. Uniform `yieldPerTokenRaw` across pairs at all times; invariant
   `rawLocked = C/Y + YS(1−1/Y)` asserted after every operation.
6. Delayed-dividend scenario end-to-end: dividend announced/effective late,
   locks still capture it.
7. Multi-pair mix: solo unwraps in one pair don't affect another pair's
   per-token values.
8. Solvency/markdown floor: Y < 1, pool zero, capital 1:1 — same as today.