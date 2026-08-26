# Seamless Vanilla-8056 Retrocompatibility

**Status:** Approved design
**Date:** 2026-08-26
**Scope promise (level C):** Apps already integrated against vanilla ERC-8056 keep working unchanged when an issuer upgrades their token to `ERC8056Composite`. Covers read-only consumers, strict integration tooling that parses `newUIMultiplier()` / `effectiveAt()` as pending-state signals, and the migration window. Event-log byte-parity with monolithic vanilla replay is explicitly out of scope (composites project class-decomposed values into base events, as documented).

## Problem

The triage identified four seams where composite semantics diverge from vanilla intuition:

| # | Seam | Severity |
|---|------|----------|
| S1 | Legacy 2-arg setter means Supply-only, not absolute display multiplier | high (issuer ops only) |
| S2 | `effectiveAt()` never returns 0 post-bootstrap; breaks vanilla "0 ⇔ nothing pending" idiom | medium |
| S3 | Live vanilla pending update silently abandoned at lazy genesis | medium |
| S4 | Per-class factor views read neutral while `uiMultiplier()` serves inherited slots | low |

## Decisions

### S1 — Documentation only (user decision)

Every setter is `onlyOwner`; third-party protocols cannot call it. Demoted to a prominent NatSpec warning on `ERC8056Composite.setUIMultiplier(uint256,uint256)` stating it targets the Supply class exclusively, so once Yield/Other factors depart from 1e18 the composite will differ from the passed value. No code change.

### S2 — Strict sentinel restoration (user decision: option A)

Post-bootstrap (no live pending on any class):

- `effectiveAt()` returns **0** instead of the most recent effective event timestamp.
- `newUIMultiplier()` returns the **active** composite (`uiMultiplier()`) instead of the projected composite.

With any live pending: unchanged current behavior (`earliest` pending effectiveAt across classes; projected composite). Pre-bootstrap: unchanged inherited-vanilla-slot behavior (already vanilla-parity).

The former fallback ("most recent effective event") is removed. Vanilla consumers using the idiom `effectiveAt() != 0 ⇔ change incoming` observe identical results pre- and post-upgrade.

### S3 — Refuse to bootstrap while a vanilla pending is live (user decision: option C)

New custom error:

```solidity
error VanillaPendingUpdate(uint256 vanillaEffectiveAt);
```

First-class-schedule guard inside `_setMultiplier`, before any state mutation: if the contract is unbootstrapped AND the inherited base slots hold a still-future pending update (`_effectiveAt != 0 && block.timestamp < _effectiveAt`), revert. Resolution paths (documented): let the vanilla update land naturally, or call the legacy `cancelPendingUIMultiplier()`. No silent drop, ever; chronological-checkpoint invariant untouched.

Known trade-off (accepted): Robinhood's first classed schedule hard-blocks until the vanilla pending resolves.

Cancels are NOT guarded — the legacy cancel IS one of the resolution paths.

### S4 — Per-class views derive from vanilla slots during the window (user decision: option A)

While unbootstrapped:

- `uiScalingFactor[At](Supply, ts)` returns the inherited vanilla multiplier (via the existing `_inheritedMultiplierAt(ts)` coercion).
- `uiScalingFactor[At](Yield|Other, ts)` return 1e18.

Result: ∏(class factors) == `uiMultiplier()` by construction in both regimes. All per-class conversion helpers inherit coherence automatically since they delegate to these views. Class-scoped nonce/event views keep synthetic-neutral genesis semantics (wrapper compatibility verified by existing degenerate-window tests).

## Non-goals

- No changes to wrapper/LegToken, nonce math, checkpoint storage layout, or event signatures.
- No bootstrap-on-read side effects; views stay pure-read in every regime.
- No compensating-legacy-setter math (rejected options B/C from brainstorming).

## Testing plan (TDD)

Failing tests written first, then implementation, then suite green:

1. Sentinel: idle post-bootstrap `(newUIMultiplier, effectiveAt) == (uiMultiplier(), 0)`; schedule flips pair to projected values; canceling the last pending restores the sentinel pair; multi-class pendings surface earliest timestamp.
2. Guard: upgrade-with-live-pending ⇒ first classed schedule reverts `VanillaPendingUpdate`; landed pending ⇒ succeeds; cancelled pending (via legacy cancel) ⇒ succeeds.
3. Window coherence: upgraded proxy with non-neutral inherited multiplier reports `Supply == inherited`, `Yield/Other == 1e18`, product == `uiMultiplier()`, including historical timestamps via `uiMultiplierAt(ts)` == ∏ `uiScalingFactorAt(class, ts)`.
4. Rewrite `test_EffectiveAt_Composite_NeverResetsBelowLastEvent` (encoded removed behavior); update `PreBootstrap_ReadsInheritVanillaMultiplier` Supply-factor expectation (now inherited, not neutral); confirm `VanillaPendingObservable` still passes (warps past pending before scheduling).

## Docs

- IERC8056Composite: NatSpec warning on legacy setter (S1).
- EIP.md: deviations table — effectiveAt entry updated to sentinel restoration; bootstrap guard added as deviation; requirement cross-references adjusted.
- TECHNICAL.md: fix the "keeps every function untouched" overstatement (resolves doc contradiction); migration guide replaces "unlanded pending needs manual re-issue" with the hard guard and its two resolution paths.
- README.md: sync deviations table.
