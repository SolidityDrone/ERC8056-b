# Add `Other` UI Scaling Class

Date: 2026-08-18
Status: Approved design

## Problem

The UI-scaling decomposition only has `Supply` and `Yield` classes, plus the
composite `uiMultiplier` (= Supply × Yield) inherited from EIP-8056. There is no
way to read or schedule a scaling factor for an "everything else" dimension
(fees, taxes, governance re-denominations, etc.) separately from supply and yield.

## Model

### Enum (backward compatible)

`UIScalingClass { Supply, Yield, Other }` — `Other` appended as value `2`.
Existing stored enum values (`Supply=0`, `Yield=1`) are preserved.

### Composite

The canonical composite is the product of **all three** classes:

```
uiMultiplier = Supply × Yield × Other
```

Replacing the old two-factor `composeSupplyYield`. The single canonical function
is named `composeUiMultiplier` and always multiplies Supply × Yield × Other.

### Scope of `Other`

- `Other` participates in: the composite `uiMultiplier` / `uiMultiplierAt`, the
  pending composite (`newUIMultiplier`), per-class reads
  (`uiScalingFactor`, `uiScalingFactorAt`), per-class scheduling
  (`setUIScalingFactor`, `applyUIScalingDelta`), checkpoint history, and the
  genesis initialization loop (iterates `SCALING_CLASS_COUNT`).
- `Other` does **NOT** participate in the wrapper's frozen-yield pricing
  (`yieldNonce`, `yieldEventAt`, coupon/share math) or the capital-UI display
  (`previewCapitalUI`, which stays Supply-only). Yield is the only class that
  ticks the nonce; Supply is the only class that drives the capital display.

## Files

- `src/interfaces/UIScalingClass.sol` — add `Other` to enum + docs.
- `src/libraries/UIScalingMath.sol` — `SCALING_CLASS_COUNT = 3`; replace
  `composeSupplyYield` with `composeUiMultiplier(Supply, Yield, Other)`.
- `src/ScaledUIClassedToken.sol` — use `composeUiMultiplier` at both composite
  sites; genesis/effectiveAt loops already iterate `SCALING_CLASS_COUNT`, so they
  pick up `Other` automatically.
- `src/ScaledPairWrapper.sol` — no change.
- `test/UIScalingMath.t.sol` — 3-factor compose tests.
- `test/ScaledUIClassedToken.t.sol` — genesis assertions across 3 classes;
  per-class + `Other` composition test.
- `test/ScaledPairWrapperHandler.sol` — add an `applyOtherDelta` invariant action.
- `test/ScaledPairWrapperInvariant.t.sol` — include `Other` delta in handler wiring
  (handler constructor takes owner; no signature change needed).
- `README.md` — legacy vs new interface tables.

## Verification

- Full `forge test` suite green (unit + fuzz + invariant).
- Invariant exercises `Other` deltas without breaking solvency.
- `forge fmt --check` clean.