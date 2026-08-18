# ERC-8056 ScaledPairWrapper

A Foundry (Solidity 0.8.24) implementation of **EIP-8056** UI scaling with a
**frozen-delta window-coupon wrapper**.

## Overview

- `ScaledUIClassedToken` — EIP-8056 token with decomposed **Supply** / **Yield**
  scaling, scheduled (pending) updates, and an append-only checkpoint history.
- `ScaledPairWrapper` — splits raw RWA into **Capital** / **Yield** ERC-20 pairs,
  one pair per `(startNonce, targetNonce)` yield-event window. Yield claims are
  **frozen at the window's expiry nonce** from historical checkpoints only; the
  current multiplier is never read, so later dividends price nothing for an ended
  window.

### Redemption

| Action | Payoff | Gate |
|--------|--------|------|
| `unwrap` (both legs) | exactly `amount` | anytime |
| `unwrapYield` | `amount * coupon` | `yieldNonce() >= target` |
| `unwrapCapital` | `amount * (1 - coupon)` | `yieldNonce() >= target` |

Where coupon = `max(1 - Y_start / Y_target, 0)` in 1e18 fixed point. Because
`coupon + share = 1`, every pair's total claim equals its deposit and the shared
raw vault stays solvent by construction.

## Usage

```shell
forge build
forge test
forge fmt --check
```

Invariant suite (solvency, frozen claims, no-stuck-raw) runs 256 sequences of
100 handler calls (~70s).

## Layout

- `src/ScaledPairWrapper.sol` — the wrapper
- `src/ScaledUIClassedToken.sol` — the scaling extension
- `src/libraries/UIScalingMath.sol`, `src/tokens/`, `src/interfaces/`
- `test/` — unit, fuzz, and invariant suites
- `script/` — deploy scripts
