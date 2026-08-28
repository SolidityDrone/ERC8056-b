# Token-Side Wrapper — embedded Capital/Yield splitting

> **Branch note:** this variant lives on `feat/token-side-wrapper`. `main` keeps
> the standalone wrapper (`ERC8056PairWrapper` + `ERC8056PairWrapperRegistry`)
> as a parallel solution. The two share the same `IERC8056PairWrapper`
> interface, the same frozen-coupon semantics, and the same LegToken contract —
> integrators write one integration and it works against either.

## What is different

The [standalone wrapper](INTEGRATION.md) is an adapter: a per-asset singleton
that pulls the raw token via `transferFrom` and is discovered through a
permissionless registry. The token-side variant instead ships the wrapping
logic **inside the ERC-8056 token itself**
([`ERC8056CompositePairWrapper`](../src/token-side/ERC8056CompositePairWrapper.sol)):

| Aspect | Standalone (`main`) | Token-side (this branch) |
|---|---|---|
| Contracts | token + wrapper + registry (3) | one token contract |
| Discovery | registry lookup + ERC-165 probe of the wrapper | `supportsInterface` on the token itself |
| `wrap` entrypoint | `approve` + `wrapper.wrap(...)` (`transferFrom`) | `token.wrap(...)` — self-escrow, **no approval** |
| Fee-on-transfer | rejected via balance-delta checks in both directions | structurally impossible (no external transfers) |
| Trust anchor | deployer of the wrapper + registry conventions | the issuer only |
| Underlying / scaledUnderlying | separate immutable addresses | both `address(this)` |

## Why the trust trade is acceptable

The token-side variant exists for issuers that are already the single
administrative authority over the multiplier — Robinhood-style stock tokens on
Robinhood Chain or Base, where a centralized entity schedules every
`uiMultiplier` update. Whoever controls the multiplier already controls the
economic value of every claim on the token; adding the wrapper to the same
contract adds no new trust root. In exchange, protocols integrate **one**
contract with **zero approval ceremony** and no registry indirection.

For permissionless or multi-issuer settings where the wrapper deployer is a
distinct, less-trusted party, use the standalone variant on `main`.

## Integration surface

Identical to [INTEGRATION.md](INTEGRATION.md) §3 — the same
`IERC8056PairWrapper` functions, events, and errors, with these differences:

1. **Discovery.** Call `supportsInterface(type(IERC8056PairWrapper).interfaceId)`
   directly on the token. True means the token splits itself; `underlying()` and
   `scaledUnderlying()` both return the token address — use that as the sanity check.
2. **Wrapping.** Call `token.wrap(rawAmount, lockNonces)`. Your token balance is
   escrowed internally — no `approve`, no separate token transfer, one
   transaction total. `rawLocked` is always exactly
   `token.balanceOf(address(token))`.
3. **Redemption, pricing, previews.** Unchanged: `unwrap` is par anytime,
   solo redemptions are nonce-gated with payouts frozen at the target nonce,
   `windowBackingOf` is the truthful per-window solvency figure, and the
   current multiplier is never read for pricing.

## What stays the same under the hood

- One shared `LegToken` contract, deployed twice per `(startNonce, targetNonce)`
  window on the first wrap into that window; the pair record stores the leg
  addresses, so a window can never mint a second pair.
- Frozen-delta coupon: `max(1 − Y_start/Y_target, 0)` from historical Yield
  checkpoints only; `coupon + share = 1` keeps every window solvent by
  construction (invariant-tested: solvency, escrow backing, ghost drift).
- Yield nonce = effective Yield-class event count; `lockNonces = 0` creates a
  degenerate principal-only window.
- `previewCapitalUI` reads the live Supply factor (display only, never a
  redemption amount).

## Quickstart (Foundry)

```solidity
ERC8056CompositePairWrapper token =
    new ERC8056CompositePairWrapper("Stock", "STK", issuer);

// issuer mints raw to alice
vm.prank(issuer); token.mint(alice, 100 ether);

// alice splits into the (0, 2) window — no approval needed
vm.prank(alice);
(uint256 s, uint256 t) = token.wrap(100 ether, 2); // s = 0, t = 2

IERC20 cap = token.capitalToken(s, t); // Capital-0-2
IERC20 yld = token.yieldToken(s, t);   // Yield-0-2

// after two effective Yield-class events, solo redemption unlocks
vm.prank(alice); token.unwrapYield(50 ether, s, t); // pays 50 * coupon
```

Tests: `test/ERC8056CompositePairWrapper*.sol` — unit, fuzz, and
handler-based invariants ported from the standalone suites (escrow backing,
solvency, ghost drift, coupon-vs-history).
