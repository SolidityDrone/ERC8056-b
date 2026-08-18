# ERC-8056 ScaledPairWrapper

A Foundry (Solidity 0.8.24) implementation of **EIP-8056** UI scaling with a
**frozen-delta window-coupon wrapper**.

## Overview

- `ScaledUIClassedToken` — EIP-8056 token with decomposed **Supply** / **Yield** /
  **Other** scaling, scheduled (pending) updates, and an append-only checkpoint
  history.
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

## Scaling classes

`UIScalingClass { Supply, Yield, Other }`. The composite UI multiplier is the
product of all three:

```
uiMultiplier = Supply × Yield × Other
```

- `Supply` — off-chain supply / denomination events (splits, reverse splits,
  ADR ratio changes, unit redenomination).
- `Yield` — off-chain accretion (dividend reinvestment, DRIP, distributions,
  pro-rata buyback benefit). Drives the wrapper's yield nonce / coupon.
- `Other` — any additional display-scaling dimension (fees, taxes, governance
  re-denominations). Composes into the total but does **not** tick the yield
  nonce or affect wrapper pricing.

## Interface surface

### Legacy — EIP-8056 core & optional extensions (unchanged)

| Interface | Methods | Status |
|-----------|---------|--------|
| `IScaledUIAmount` | `uiMultiplier()`, event `UIMultiplierUpdated`, event `TransferWithUIAmount` | required |
| `IScaledUIAmountNewUIMultiplier` | `newUIMultiplier()`, `effectiveAt()` | required |
| `IScaledUIAmountConversion` | `toUIAmount(uint256)`, `fromUIAmount(uint256)` | optional |
| `IScaledUIAmountBalances` | `balanceOfUI(address)`, `totalSupplyUI()` | optional |

### New — class decomposition (this repo's extension)

| Interface | Methods | Notes |
|-----------|---------|-------|
| `IScaledUIAmountClasses` | `uiScalingFactor(UIScalingClass)` | per-class cumulative factor |
| | `uiScalingFactorAt(UIScalingClass, uint256)` | per-class factor at a timestamp |
| | `uiMultiplierAt(uint256)` | composite at a timestamp |
| | `pendingUIScalingFactor(UIScalingClass)` | pending factor |
| | `scalingFactorEffectiveAt(UIScalingClass)` | when pending becomes active |
| | `hasPendingScalingFactor(UIScalingClass)` | pending check |
| | `scalingHistoryLength(UIScalingClass)` | checkpoint count |
| | `scalingCheckpointAt(UIScalingClass, uint256)` | checkpoint read |
| | `yieldNonce()` | effective yield-event count |
| | `yieldEventAt(uint256)` | yield event (timestamp, multiplier) |
| | `setUIScalingFactor(UIScalingClass, uint256, uint256)` | schedule absolute factor |
| | `applyUIScalingDelta(UIScalingClass, uint256, uint256)` | schedule relative delta |
| `ScaledUIClassedToken` | `toUIAmount(uint256, UIScalingClass)` | per-class conversion overload |
| | `toUIAmountAt(uint256, UIScalingClass, uint256)` | per-class, at timestamp |
| | `fromUIAmount(uint256, UIScalingClass)` | per-class inverse |
| `UIScalingMath` | `composeUiMultiplier(Supply, Yield, Other)` | canonical composite |

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
