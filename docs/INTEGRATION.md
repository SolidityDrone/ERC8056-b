# Integration Guide: `IERC8056PairWrapper` & the Wrapper Registry

This document is the consumer-facing spec for protocols that want to build on
top of ERC-8056's Capital/Yield split — auctions, options, and lending protocols
that need a **principal leg** and a **yield leg** of the same raw RWA token.

It defines two stable, optional surfaces (they are reference components of the
EIP, not separate standards):

1. [`IERC8056PairWrapper`](../src/wrapper/interfaces/IERC8056PairWrapper.sol) — the
   per-asset singleton wrapper: split, redemption, and pricing.
2. [`ERC8056PairWrapperRegistry`](../src/wrapper/ERC8056PairWrapperRegistry.sol) — the
   canonical per-asset discovery: one wrapper per raw token, so every protocol
   integrates against the *same* address for a given asset.

---

## 1. Mental model

A raw RWA token (e.g. a Robinhood stock token) is split into **windows**.
A window is keyed by `(startNonce, targetNonce)`:

- `startNonce` = the yield nonce *at the time the user wraps*.
- `targetNonce` = `startNonce + lockNonces`, the yield nonce at which the window
  "expires" (becomes redeemable for yield).

Each window mints exactly **two fungible ERC-20 receipts** in a 1:1 ratio for
every raw unit locked:

- **Capital token** — claim on the underlying principal (redemption scaled by
  `1 - coupon`).
- **Yield token** — claim on the yield accrued over the window (redemption
  scaled by `coupon`).

`coupon + share = 1`, so the two legs always sum to exactly the deposit and the
shared raw vault stays solvent by construction.

```
   raw RWA
     │  wrap(rawAmount, lockNonces)
     ▼
  window (startNonce, targetNonce)
     ├── LegToken  ──► unwrapCapital: raw * (1 - coupon)
     └── LegToken    ──► unwrapYield:   raw * coupon
                           (both gated until getClassNonce(MultiplierClass.Yield) >= targetNonce)
```

---

## 2. Discovery: the registry

Protocols should **never** hardcode or guess wrapper addresses. Ask the
registry instead.

```solidity
import {IERC8056PairWrapperRegistry} from "../src/wrapper/interfaces/IERC8056PairWrapperRegistry.sol";
import {IERC8056PairWrapper} from "../src/wrapper/interfaces/IERC8056PairWrapper.sol";

IERC8056PairWrapperRegistry registry = /* canonical registry address */;

// Read-only: does a wrapper exist for this underlying?
IERC8056PairWrapper w = registry.wrapperFor(rawToken);
if (address(w) != address(0)) {
    // use it
}
```

To bootstrap a new asset, call `deployOrGet`. It is **idempotent**: the first
call for an underlying deploys and caches its singleton wrapper; every later
call returns the same address. Identity is keyed by `underlying` only — later
calls with different display `name`/`symbol` are ignored.

```solidity
IERC8056PairWrapper w = registry.deployOrGet(
    rawToken,          // IERC20 underlying
    rawToken,          // scaledUnderlying: MUST be the same contract (extension == token)
    "Tesla",           // display name
    "Tesla"            // display symbol
);
```

`deployOrGet` reverts `ExtensionMismatch` if `scaledUnderlying` is not the same
contract as `underlying`, and `UnsupportedExtension` if that contract does not
report `IERC8056Composite` via ERC-165. Binding the two prevents a third
party from front-running registration and pricing the canonical wrapper's
redemptions off an untrusted extension.

Enumeration and reverse lookup are available:

| Member | Purpose |
|--------|---------|
| `wrapperFor(underlying)` | canonical wrapper, zero if unregistered |
| `wrapperCount()` / `wrapperAt(i)` | enumerate all registered assets |
| `underlyingOf(wrapper)` | reverse: raw token behind a wrapper |

---

## 3. The wrapper surface, grouped by what a protocol needs

### 3.1 Splitting (auctions / issuance)

| Member | Notes |
|--------|-------|
| `underlying()` | the raw RWA token that gets locked |
| `wrap(rawAmount, lockNonces) -> (start, target)` | approve first; mints 1:1 capital+yield; returns the created window |
| `pairs(start, target) -> Pair{capital, yield}` | both leg addresses for a window |
| `capitalToken(start,target)` / `yieldToken(start,target)` | explicit leg getters |
| `hasPair(start,target)` | true if the window was ever created |
| `pairCount()` / `pairAt(i)` | enumerate every window ever created |

After a successful `wrap`, a protocol can read the two receipt addresses and
list them on its auction or forward them to a vault.

### 3.2 Redemption (end users / settlement)

| Member | Notes |
|--------|-------|
| `unwrap(amount, start, target)` | burn **both** legs, receive exactly `amount` underlying — anytime |
| `unwrapYield(amount, start, target)` | burn `amount` yield leg for `amount * coupon` |
| `unwrapCapital(amount, start, target)` | burn `amount` capital leg for `amount * (1 - coupon)` |
| `rawLocked()` | total raw underlying locked across all windows |
| `rawLockedOf(start, target)` | outstanding capital supply of a window (== raw backing before any solo yield redemption) |

Both solo redemption functions revert `Locked` while `currentNonce() < target`.
`unwrap` is unconditional — it is the safe exit for any window.

### 3.3 Pricing & previews (options, AMMs, lending)

All pricing is **frozen-delta**: computed from historical checkpoints at the
target nonce, never from the live multiplier. This means redemption payoffs are
deterministic and independent of later events.

| Member | Meaning |
|--------|---------|
| `currentNonce()` | current yield nonce (`== scaledUnderlying.getClassNonce(MultiplierClass.Yield)`) |
| `couponOf(start,target)` | frozen yield coupon `max(1 - Y_start/Y_target, 0)`, 1e18 fixed point |
| `capitalShareOf(start,target)` | `1e18 - coupon` |
| `previewUnwrap(amount,start,target)` | `(capitalRawOut, yieldLegRawOut)` — splits exactly to `amount` |
| `previewUnwrapYield(amount,start,target)` | underlying for burning `amount` yield leg |
| `previewUnwrapCapital(amount,start,target)` | underlying for burning `amount` capital leg |
| `previewCapitalUI(capitalAmount)` | **display only** — composite-UI figure; never a redemption amount |
| `capitalSupplyOf` / `yieldSupplyOf` | per-window supplies |
| `capitalSupply()` / `yieldSupply()` | aggregate across all windows |

> **Note on `previewCapitalUI`:** it applies the *live* Supply factor for UI
> display only. It must never be used as a claim/redeem amount — raw claims are
> always driven by the frozen coupon/share path above.

---

## 4. Worked integration scenarios

### 4.1 Lending: borrow against a principal leg

1. Borrowers `wrap(rawAmount, lockNonces)` to get a `LegToken` for
   window `(s, t)`.
2. The lending protocol takes the `LegToken` as collateral. It values it
   via `capitalShareOf(s,t)` (or `previewUnwrapCapital`) rather than the live
   multiplier, so collateral is a *known* function of the window.
3. On liquidation, the protocol `unwrapCapital(collateralAmount, s, t)` — but
   only after `currentNonce() >= t`. Before that it can always `unwrap(...)`
   both legs to recover the full deposit.

### 4.2 Options: exercise value is frozen

1. A call on window `(s, t)` is written against the `LegToken` (upside) and
   the `LegToken` (downside/floored principal).
2. Because `couponOf(s,t)` is frozen once `t` is reached, the option's
   settlement value is deterministic on-chain — there is no oracle race on the
   exercise payoff.
3. Settlement simply calls `unwrapYield` / `unwrapCapital`; no AMM re-pricing
   is needed for the payoff.

### 4.3 Auction: split-and-sell

1. Issuer `wrap(rawAmount, lockNonces)` and reads `pairs(s,t)`.
2. The `LegToken` and `LegToken` are listed as separate lots with
   independent order books — buyers can hold one leg without owning the other.
3. `unwrap` (both legs) guarantees any holder of the full pair can always exit
   at exactly the deposit, so arbitrageurs keep the two legs near their fair
   split.

---

## 5. Token address discovery pattern

```solidity
function wrapperForWindow(IERC8056PairWrapper w, uint256 start, uint256 target)
    external view returns (IERC20 capital, IERC20 yield)
{
    // Prefer explicit getters over destructuring.
    capital = w.capitalToken(start, target);
    yield   = w.yieldToken(start, target);
}
```

Use `hasPair(start, target)` before interacting with a window you only heard
about off-chain; zero-address legs from `pairs()` indicate a never-created
window.

---

## 6. Conventions & safety

- **Singleton per underlying.** There is exactly one canonical wrapper per raw
  token (enforced by the registry). Integrate via the registry, not by
  constructing `ERC8056PairWrapper` yourself.
- **Legs are standard ERC-20.** `Pair` exposes them as `IERC20` to keep the
  interface concrete-token-free; minting/burning is internal to the wrapper.
- **Approvals.** `wrap` pulls `underlying` via `transferFrom` — approve the
  wrapper (or registry-deployed wrapper) before calling.
- **One EIP, multiple contracts.** The registry + wrapper are optional consumer
  surfaces of the same EIP-8056 improvement; the base extension (`ERC8056`)
  remains the core.

## 7. References

- Interface: [`IERC8056PairWrapper.sol`](../src/wrapper/interfaces/IERC8056PairWrapper.sol)
- Registry: [`IERC8056PairWrapperRegistry.sol`](../src/wrapper/interfaces/IERC8056PairWrapperRegistry.sol), [`ERC8056PairWrapperRegistry.sol`](../src/wrapper/ERC8056PairWrapperRegistry.sol)
- Implementation: [`ERC8056PairWrapper.sol`](../src/wrapper/ERC8056PairWrapper.sol)
- Extension: [`IERC8056Composite.sol`](../src/interfaces/extension/IERC8056Composite.sol)
- Tests: [`ERC8056PairWrapper.t.sol`](../test/ERC8056PairWrapper.t.sol), [`ERC8056PairWrapperRegistry.t.sol`](../test/ERC8056PairWrapperRegistry.t.sol)