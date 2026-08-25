---
eip: TBD
title: Class-Decomposed UI Scaling for ERC-20 Tokens
description: Decompose the ERC-8056 UI multiplier into named scaling classes (Supply, Yield, Other) with per-class checkpoint history, enabling on-chain Capital/Yield splitting of tokenized real-world assets.
author: TBD
discussions-to: https://ethereum-magicians.org/t/erc-8056-class-decomposed-ui-scaling/XXXXX
status: Draft
type: Standards Track
category: ERC
created: 2026-08-21
requires: 20, 165, 8056
---

## Abstract

This proposal extends [ERC-8056](./eip-8056.md) (Scaled UI Amount Extension) by decomposing the single composite `uiMultiplier` into named **scaling classes**: `Supply` (splits, reverse splits, redenominations), `Yield` (dividends, distributions, pro-rata buybacks), and `Other` (fees, taxes, governance re-denominations). Each class carries its own cumulative factor and checkpoint history. The composite multiplier is always derived as the product of all class factors, guaranteeing it can never drift out of sync with the class decomposition.

The critical consequence: every on-chain event carries **the reason it happened** -- whether a multiplier move was a denomination change or a genuine yield accretion. This enables a **Capital/Yield split** for tokenized real-world assets (RWAs): the class decomposition and checkpoint history serve as the raw material for a deterministic, event-accurate separation of a token into principal and yield components.

This EIP specifies the extension interface (`IERC8056Composite`), the scaling-class enum (`MultiplierClass`), and the normative requirements for per-class factor storage, checkpoint recording, and yield-event derivation. A reference implementation is provided.

A standalone Capital/Yield wrapper contract (`ERC8056PairWrapper`) and a canonical per-asset registry (`ERC8056PairWrapperRegistry`) are included as **practical reference implementations** -- optional consumer surfaces that demonstrate how the extension enables on-chain principal/yield decomposition. They are not part of the normative standard.

## Motivation

### The core limitation of ERC-8056

ERC-8056 exposes a single composite `uiMultiplier`. When the off-chain issuer updates it, the on-chain token only sees a new number -- **not the reason** the number changed.

Consider a Robinhood-style stock token tracked off-chain:

- A **2-for-1 stock split** halves the raw unit count and doubles the UI multiplier. The economic *principal* is unchanged; only the denomination changed. This is a **Supply** effect.
- A **dividend reinvestment** grows the backing pool pro-rata and increases the UI multiplier. Every holder's *principal* is unchanged, but they accrued a **Yield**.
- A **reverse split**, **ADR ratio change**, or **redenomination** are more Supply effects with identical multiplier math.

To an ERC-8056 token, all three are indistinguishable: `uiMultiplier` moved from 1.0x to 2.0x. The contract cannot tell a split (everyone's claim is the same asset, re-denominated) from a dividend (a *new* yield claim has been created).

### Why that blocks Capital/Yield splitting

Lending, options, and auction protocols work by separating a token's **principal** from its **yield**:

- A lender wants to lend the *principal* and collect the *yield*.
- An option writer sells the *yield upside*.
- An auction sells rights to future distributions.

To split a token into a Capital LegToken and a Yield LegToken (one shared `LegToken` contract, deployed twice per window — the capital leg claims the frozen principal share, the yield leg the frozen coupon), the contract must know **which part of the multiplier change is yield vs supply**, across a specific window. With a single `uiMultiplier`, that split is impossible -- you cannot attribute a 2x move between principal and yield, or freeze a window's payout, without knowing why each change happened and when.

On-chain tokenized RWA -- such as Robinhood Chain stock tokens -- currently expose only a scalar multiplier with no class attribution and no history to price a window against. The Capital/Yield split is therefore not doable.

### The improvement in one sentence

Decompose the multiplier into **named scaling classes** (`Supply`, `Yield`, `Other`) with a **per-class checkpoint history**, so the reason for every change is visible, on-chain, and priced deterministically.

### What this enables

Once classes exist:

- A `Yield`-class event means "the backing pool grew pro-rata" -- a genuine new yield claim.
- A `Supply`-class event means "the denomination changed" -- principal-only, a display adjustment.
- The checkpoint history turns yield events into a **sequence of nonces**, each with a frozen multiplier -- the raw material for a Capital/Yield split.

Protocols can then build on RWA without trusting a single scalar:

- **Lending** -- lend `LegToken`, accrue and sell `LegToken` as interest.
- **Options** -- write the yield coupon as the option's underlying upside.
- **Auctions** -- auction the right to a window's future distributions.
- **Any** application that needs to separate "I own the asset" from "I own its growth" on a token that only publishes UI scaling.

## Specification

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in RFC 2119.

### Overview

This EIP extends ERC-8056 with a **class-decomposed scaling layer**. It adds:

- A **scaling-class enum** `MultiplierClass` with three values: `Supply`, `Yield`, `Other`.
- Per-class **cumulative factors** replacing the single `uiMultiplier` with three independent factor series.
- Per-class **checkpoint histories** recording every effective update.
- A **yield-event log** derived from the `Yield` checkpoint history, expressed as a nonce sequence.
- Scheduled (pending) updates per class, with explicit activation timestamps.

The composite `uiMultiplier()` is always the product of every class factor. There is no generic monolithic multiplier setter -- every update MUST specify a class. This guarantees the class decomposition can never drift out of sync with the displayed multiplier.

### Scaling-class enum

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum MultiplierClass {
    Supply,  // 0 -- splits, reverse splits, ADR ratio changes, redenomination
    Yield,   // 1 -- dividend reinvestment, DRIP, distributions, pro-rata buyback
    Other    // 2 -- fees, taxes, governance re-denominations
}
```

| Class | Meaning | Backing effect | Role in Capital/Yield split |
|-------|---------|----------------|----------------------------|
| `Supply` | split, reverse split, ADR, redenomination | same economics, different count | capital display only |
| `Yield` | dividend, DRIP, distribution, buyback | pool grew pro-rata | **drives nonce + coupon** |
| `Other` | fees, taxes, governance re-denominations | mixed | composes, no pricing |

Implementations SHOULD NOT add additional enum values without a formal amendment to this EIP, as it would break the `composeUiMultiplier` product semantics and the `IERC8056Composite` interface ID.

### Interface: `IERC8056Composite`

```solidity
interface IERC8056Composite {
    struct ScalingCheckpoint {
        uint256 effectiveAt;
        uint256 cumulativeMultiplier;
        uint256 multiplierRatio;
    }

    struct ClassScalingEvent {
        uint256 timestamp;
        uint256 cumulativeMultiplier;
        uint256 multiplierRatio;
    }

    struct Announcement {
        string id;
        string description;
        string uri;
    }

    event UIScalingFactorUpdated(
        MultiplierClass indexed scalingClass,
        uint256 newMultiplier,
        uint256 multiplierRatio,
        uint256 effectiveAtTimestamp,
        uint256 classNonce,
        Announcement announcement
    );

    event UIScalingFactorCancelled(
        MultiplierClass indexed scalingClass,
        uint256 previousMultiplier,
        uint256 restoredMultiplier,
        uint256 cancelledAtTimestamp
    );

    // ---- Per-class factor reads ----

    function uiScalingFactor(MultiplierClass scalingClass) external view returns (uint256);
    function uiScalingFactorAt(MultiplierClass scalingClass, uint256 timestamp) external view returns (uint256);

    // ---- Base ERC-8056 naming overloads ----

    // Composite multiplier at `timestamp` = product of all class factors at that time.
    function uiMultiplierAt(uint256 timestamp) external view returns (uint256);

    // Cumulative multiplier for a single class at `timestamp`.
    function uiMultiplierAt(MultiplierClass scalingClass, uint256 timestamp) external view returns (uint256);

    // Current cumulative multiplier for a single class (alias for uiScalingFactor).
    function uiMultiplier(MultiplierClass scalingClass) external view returns (uint256);

    // ---- Nonce-based reads ----

    // Composite multiplier as of the era opened by the n-th event of any class.
    // Per class the nonce is clamped to the class's current nonce, so classes
    // with fewer events contribute their latest factor (saturates at
    // type(uint256).max rather than reverting).
    function uiMultiplierAtNonce(uint256 nonce) external view returns (uint256);

    // Cumulative multiplier for a single class at a past nonce (1-based).
    function uiMultiplierAtNonce(MultiplierClass scalingClass, uint256 nonce) external view returns (uint256);

    // ---- Pending (scheduled) updates ----

    function newUIMultiplier(MultiplierClass scalingClass) external view returns (uint256);
    function effectiveAt(MultiplierClass scalingClass) external view returns (uint256);
    function hasPendingUIMultiplier(MultiplierClass scalingClass) external view returns (bool);

    // ---- Checkpoint history ----

    function scalingHistoryLength(MultiplierClass scalingClass) external view returns (uint256);
    function scalingCheckpointAt(MultiplierClass scalingClass, uint256 index)
        external view returns (ScalingCheckpoint memory);

    // ---- Yield events (derived from Yield checkpoint history) ----

    function getClassNonce(MultiplierClass scalingClass) external view returns (uint256);
    function classEventAtNonce(MultiplierClass scalingClass, uint256 nonce) external view returns (ClassScalingEvent memory);

    // ---- State-changing: schedule updates ----

    function setUIMultiplier(
        MultiplierClass scalingClass,
        uint256 newMultiplier,
        uint256 effectiveAtTimestamp,
        string calldata id,
        string calldata description,
        string calldata uri
    ) external;

    // ---- State-changing: cancel pending ----

    // Cancels the pending scaling update for `scalingClass`, restoring the
    // active factor. Reverts if no pending update exists for the class.
    function cancelPendingUIMultiplier(MultiplierClass scalingClass) external;
}
```

### Normative requirements

#### Composite multiplier

1. The composite `uiMultiplier()` MUST equal the product of every class factor: `Supply * Yield * Other` (each 18-decimal fixed point).
2. There MUST NOT exist a generic monolithic multiplier setter. Every state-changing function that modifies a class factor MUST accept a `MultiplierClass` parameter.
3. The composite MUST be derived at read time from the class factors -- it MUST NOT be stored as a separate state variable that could drift out of sync.

#### Per-class factors

4. Each class MUST maintain its own independent cumulative factor (18-decimal fixed point, where `1e18 = 1.0x`).
5. `uiScalingFactor(class)` MUST return the current effective cumulative factor for the given class.
6. `uiScalingFactorAt(class, timestamp)` MUST return the cumulative factor as it was at the given `timestamp` (inclusive of any update whose `effectiveAt <= timestamp`).

#### Checkpoint history

7. Each class MUST maintain an append-only checkpoint history. Each checkpoint MUST record `{effectiveAt, cumulativeMultiplier, multiplierRatio}`.
8. `scalingCheckpointAt(class, index)` MUST return checkpoint at the given 0-based index, where index 0 is the genesis checkpoint (`effectiveAt = 0`, `cumulativeMultiplier = 1e18`, `multiplierRatio = 0`).
9. `scalingHistoryLength(class)` MUST return the total number of checkpoints including genesis.
10. Once a checkpoint becomes effective (`effectiveAt <= block.timestamp`), it MUST NOT be modified or replaced.
11. A pending (not yet effective) checkpoint MAY be replaced if the same class is rescheduled before activation.

#### Scheduled (pending) updates

12. `setUIMultiplier(class, newMultiplier, effectiveAtTimestamp, id, description, uri)` MUST schedule an absolute cumulative multiplier. `effectiveAtTimestamp` MUST be in the future.
13. A pending update MUST NOT affect the current effective multiplier or the composite multiplier until `effectiveAt` is reached.
14. `UIScalingFactorUpdated` MUST be emitted when a multiplier is scheduled, with `{newMultiplier, multiplierRatio, effectiveAtTimestamp, classNonce, announcement}`.

#### Cancelling pending updates

15. `cancelPendingUIMultiplier(class)` MUST cancel a pending (not yet effective) update for `scalingClass`, restoring the active factor as both the current and pending value.
16. The cancelled checkpoint MUST be removed from the checkpoint history.
17. `UIMultiplierCancelled(previousMultiplier, restoredMultiplier, cancelledAtTimestamp)` MUST be emitted on the base interface.
18. `UIScalingFactorCancelled(scalingClass, previousMultiplier, restoredMultiplier, cancelledAtTimestamp)` MUST be emitted on the extension interface.
19. `cancelPendingUIMultiplier(class)` MUST revert with `NothingToCancel()` if no pending update exists for the class or if the pending update has already become effective.

#### Yield-event derivation

20. The yield nonce MUST be derived from the `Yield` checkpoint history: it counts checkpoints with `effectiveAt <= block.timestamp`, excluding the genesis checkpoint (index 0) and any pending (future) updates.
21. `classEventAtNonce(MultiplierClass.Yield, nonce)` MUST map nonce `n` to checkpoint index `n` (1-based events; genesis is index 0, not an event).
22. A scheduled-but-not-effective Yield update MUST NOT consume a nonce.
23. The nonce MUST tick only when a Yield-class update actually becomes effective.

#### ERC-165

24. Contracts implementing this extension MUST implement ERC-165 and return `true` for the `IERC8056Composite` interface ID.

### Interface IDs

| Interface | ID |
|-----------|----|
| `IERC8056Composite` | computed via `type(IERC8056Composite).interfaceId` |

Implementations that also implement the base ERC-8056 interfaces MUST report those interface IDs via ERC-165 as well. Note that `IERC8056NewUIMultiplier` retains its vanilla spec ID (`0x4bd27648`) -- cancel has been moved out into the separate optional `IERC8056Cancel` interface, so implementing cancel does not change the pending-multiplier interface ID.

### Deviations from vanilla ERC-8056

The composite implementation keeps every vanilla ERC-8056 interface ID intact, but several base-interface entrypoints take on composite semantics:

- **Legacy 2-arg setter routes to a class.** `setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp)` delegates to the **Supply** class (with empty announcement fields), emitting both `UIScalingFactorUpdated` and `UIMultiplierUpdated`. Vanilla ERC-8056 writes a single dead storage slot; writing it silently here would never be observed by any class-derived read.
- **Composite pending views.** Base `newUIMultiplier()` returns the product over classes of the *pending* factor where a live announcement exists and the active factor otherwise (i.e. the composite once every pending update lands). Base `effectiveAt()` returns the earliest pending `effectiveAt` across classes; if no class has a live announcement it returns the most recent effective event timestamp across classes (`0` only when nothing was ever scheduled) instead of resetting to 0.
- **Cancel requires a class.** The parameterless `cancelPendingUIMultiplier()` reverts with `"ERC8056: use class-based cancel"`. Cancelling MUST go through `cancelPendingUIMultiplier(MultiplierClass scalingClass)`, which emits both `UIScalingFactorCancelled(scalingClass, ...)` and the base `UIMultiplierCancelled(...)`.
- **Composite-at-nonce clamping.** `uiMultiplierAtNonce(uint256 nonce)` composes per-class factors at `min(nonce, getClassNonce(class))`, with `nonce 0` contributing `1e18`. The composition **saturates at `type(uint256).max` rather than reverting**, so it never reverts for extreme era-mixed factors or arbitrarily large nonces, and equals `uiMultiplier()` for any sufficiently large representable `nonce`. The per-class overload reverts for nonces beyond the class history, as in requirement 21.
- **Synthetic genesis on empty history.** If a class has no checkpoint history yet (a freshly-upgraded vanilla proxy), `classEventAtNonce(class, 0)` MUST return the synthetic genesis event `{timestamp: 0, cumulativeMultiplier: 1e18, multiplierRatio: 0}` instead of reverting — matching direct deploys, where index 0 IS genesis. Nonces > 0 still revert with `EventNotRecorded`. This keeps degenerate wrapper windows `(0, 0)` readable before the issuer's first schedule bootstraps real genesis.
- **Schedule-time overflow guard.** Scheduling a factor whose pending composite would overflow reverts with `CompositeOverflow()` instead of an arithmetic panic.


### No explicit prohibition on additional classes

This EIP defines three classes (`Supply`, `Yield`, `Other`) as the standard decomposition. Implementations MUST NOT add enum values that would alter the `IERC8056Composite` interface ID or break the `composeUiMultiplier` product semantics without a formal amendment. However, implementations MAY extend the contract with additional internal bookkeeping (e.g., sub-class tracking) as long as the normative interface is preserved.

## Rationale

### Why decompose instead of adding a separate yield oracle

An alternative approach: keep the single `uiMultiplier` and add a separate oracle contract that independently tracks yield events. This was rejected because:

- It introduces a second source of truth that must be kept in sync with the multiplier -- a synchronization hazard.
- The oracle cannot be derived from the multiplier (you cannot retroactively determine what fraction of a 2x move was yield).
- It couples two standards (ERC-8056 and the oracle) with no on-chain guarantee of consistency.

By contrast, class decomposition makes the class **intrinsic to every update**. The reason for a multiplier change is recorded at the moment it happens, not inferred after the fact. There is no synchronization gap, no oracle drift, and no retroactive attribution.

### Why three classes, not two

Two classes (`Supply`, `Yield`) would handle the primary use case. However, real-world tokens have events that are neither pure denomination changes nor pure yield accretion: fee assessments, tax withholdings, and governance re-denominations. Without an `Other` class, these would have to be shoehorned into `Supply` or `Yield`, corrupting the class attribution. `Other` composes into the total multiplier but does not drive the wrapper's yield-nonce or capital-display logic, keeping the Capital/Yield split clean.

### Why checkpoints, not a separate event log

The Yield checkpoint history already exists (it is required for `uiScalingFactorAt` to work). Deriving the yield nonce and events from this same history avoids a separate storage array for yield events -- the nonce and events are read straight from the Yield checkpoint history. This reduces gas cost, eliminates a class of synchronization bugs, and guarantees the event log is always consistent with the factor history.

### Why nonce-based expiry, not time-based

Time-based expiry (e.g., "this yield claim is worth 0 after date D") penalizes holders for calendar slip the issuer does not control. A dividend announced for 2 June but landed on 4 June would cause a time-based window to go "dead" on 3 June while the dividend merely has not landed yet. Nonce-based expiry -- "commit to the next N multiplier updates, whenever they land" -- is immune to this failure mode. The window matures when the target *event* actually happens, not when a wall clock crosses a date.

### Why the wrapper is a separate contract

The Capital/Yield split is implemented as a standalone wrapper (`ERC8056PairWrapper`) that consumes the extension, mirroring how WETH is to ETH: ETH defines the asset; a standalone wrapper adapts it for ERC-20-interoperable use. This keeps the base token minimal and lets *any* ERC-8056-compatible issuer opt in without changing their token. The wrapper is an optional consumer surface -- not part of the normative standard -- and protocols may implement their own split logic against the extension interface directly.

### Why `previewCapitalUI` reads the current multiplier (and why that is safe)

`previewCapitalUI` applies the *live* Supply factor for UI display only. It is explicitly **not** a redemption amount -- raw claims are always driven by the frozen coupon/share path. This is the one function that reads the current multiplier, and it is clearly scoped as a display helper. The frozen-delta pricing model guarantees that redemption payoffs are deterministic and independent of later events.

## Reference Implementation

The full reference implementation is available at [github.com/SolidityDrone/ERC8056-b](https://github.com/SolidityDrone/ERC8056-b). It consists of:

- `ERC8056Composite.sol` -- the class-decomposed extension contract.
- `UIScalingMath.sol` -- canonical composite math library.
- `IERC8056Composite.sol` -- the extension interface (includes the `Announcement` metadata struct and both scaling events).
- `IERC8056MultiplierClass.sol` -- the multiplier-class enum.
- `IERC8056NewUIMultiplier.sol` / `IERC8056Cancel.sol` -- base ERC-8056 interfaces. The pending-multiplier interface keeps only `newUIMultiplier()`/`effectiveAt()` (spec ID `0x4bd27648`, unchanged from vanilla ERC-8056); cancel (`cancelPendingUIMultiplier()` + `UIMultiplierCancelled`) lives in a separate optional `IERC8056Cancel` interface.
- `ERC8056PairWrapper.sol` -- the Capital/Yield wrapper (reference consumer).
- `ERC8056PairWrapperRegistry.sol` -- canonical per-asset wrapper discovery.
- `IERC8056PairWrapper.sol` -- the wrapper integration interface.

### Extension contract (summary)

```solidity
contract ERC8056Composite is IERC8056Cancel, ERC8056, IERC8056Composite {
    struct ClassScalingState {
        uint256 activeFactor;
        uint256 pendingFactor;
        uint256 effectiveAt;
    }

    error CompositeOverflow();

    mapping(MultiplierClass => ClassScalingState) private _classScaling;
    mapping(MultiplierClass => ScalingCheckpoint[]) private _checkpoints;
    mapping(MultiplierClass => uint256[]) private _checkpointTimestamps;

    function uiMultiplier() public view returns (uint256) {
        return UIScalingMath.composeUiMultiplier(
            uiScalingFactor(MultiplierClass.Supply),
            uiScalingFactor(MultiplierClass.Yield),
            uiScalingFactor(MultiplierClass.Other)
        );
    }

    // Base-naming overload: per-class cumulative multiplier.
    function uiMultiplier(MultiplierClass scalingClass) external view returns (uint256) {
        return uiScalingFactor(scalingClass);
    }

    function uiScalingFactorAt(MultiplierClass scalingClass, uint256 timestamp) public view returns (uint256) {
        uint256[] storage timestamps = _checkpointTimestamps[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
        uint256 idx = Arrays.lowerBound(timestamps, timestamp); // O(log n)
        if (idx < history.length && timestamps[idx] == timestamp) {
            return history[idx].cumulativeMultiplier;
        }
        return idx > 0 ? history[idx - 1].cumulativeMultiplier : UIScalingMath.MULTIPLIER_DECIMALS;
    }

    // Derived via binary search (upperBound) over checkpoint timestamps: O(log n).
    function getClassNonce(MultiplierClass scalingClass) public view returns (uint256) {
        uint256[] storage timestamps = _checkpointTimestamps[scalingClass];
        if (timestamps.length == 0) return 0; // lazily bootstrapped upgraded proxy
        return Arrays.upperBound(timestamps, block.timestamp) - 1;
    }

    // setUIMultiplier(scalingClass, newMultiplier, effectiveAtTimestamp, id, description, uri)
    // validates future-only scheduling, guards against composite overflow
    // (reverts CompositeOverflow instead of an arithmetic panic), replaces any
    // live pending checkpoint for the class, synthesizes the genesis entry on
    // first use (lazy genesis for upgraded proxies), pushes the new checkpoint,
    // and emits UIScalingFactorUpdated with the Announcement metadata plus the
    // base UIMultiplierUpdated with the projected pending composite.
}
```

> **Lazy genesis:** an upgraded vanilla ERC-8056 proxy starts with empty
> checkpoint histories (`scalingHistoryLength(class) == 0`). No initialization
> transaction is needed — the first `setUIMultiplier` call on each class
> bootstraps the genesis checkpoint (`effectiveAt = 0`,
> `cumulativeMultiplier = 1e18`), after which indexing matches direct deploys.
> While the history is empty, `classEventAtNonce(class, 0)` returns the
> synthetic genesis event `{0, 1e18, 0}` instead of reverting (see deviations).

### Capital/Yield wrapper (practical reference)

The wrapper locks raw RWA and mints per-window `LegToken` pairs (capital and yield legs) against the extension's yield-event history. Key operations:

- `wrap(rawAmount, lockNonces)` -- locks underlying, mints 1:1 capital+yield for the window `(currentNonce, currentNonce + lockNonces)`.
- `unwrap(amount, start, target)` -- burns both legs, returns exactly `amount` (anytime).
- `unwrapYield(amount, start, target)` -- burns yield leg, returns `amount * coupon` (gated: `getClassNonce(MultiplierClass.Yield) >= target`).
- `unwrapCapital(amount, start, target)` -- burns capital leg, returns `amount * (1 - coupon)` (gated: `getClassNonce(MultiplierClass.Yield) >= target`).

Where `coupon = max(1 - Y_start / Y_target, 0)` in 1e18 fixed point, frozen at historical checkpoints only.

### Canonical registry

`ERC8056PairWrapperRegistry` enforces singleton semantics: one wrapper per underlying asset. `deployOrGet(underlying, scaledUnderlying, name, symbol)` deploys and caches on first call; returns the existing wrapper on subsequent calls. `scaledUnderlying` MUST equal `underlying` (the RWA token IS the class-decomposed extension), validated via ERC-165. The wrapper's display metadata is **derived from the underlying's** `name()`/`symbol()`; the `name`/`symbol` parameters are fallback-only, used when the underlying lacks ERC-20 metadata (calls revert or return empty).

## Backwards Compatibility

This EIP extends ERC-8056. It does not modify the existing `IERC8056`, `IERC8056Conversion`, `IERC8056Balances`, or `IERC8056NewUIMultiplier` interfaces. Contracts that implement only the base ERC-8056 interfaces remain compliant. The only reorganization on the base side is that cancel (`cancelPendingUIMultiplier()` / `UIMultiplierCancelled`) moved from `IERC8056NewUIMultiplier` into a separate optional `IERC8056Cancel` interface, leaving the pending-multiplier interface ID (`0x4bd27648`) untouched. Base-interface reads and writes gain composite semantics as described in [Deviations from vanilla ERC-8056](#deviations-from-vanilla-erc-8056); off-chain consumers reading only `uiMultiplier()` see no difference.

The `IERC8056Composite` interface is additive. The composite `uiMultiplier()` function retains its signature and semantics -- it is simply derived from three class factors instead of a stored scalar. Off-chain consumers that read `uiMultiplier()` see no difference.

The `MultiplierClass` enum and `IERC8056Composite` interface ID are new. Contracts that adopt this extension gain new ERC-165 interface IDs alongside the existing ERC-8056 IDs.

The Capital/Yield wrapper and registry are optional consumer contracts. They do not alter the base token's behavior.

## Security Considerations

### Issuer trust model

The issuer (owner of the extension contract) is trusted to:

- Push Yield-class events accurately (dividend amounts and timing).
- Not fabricate Yield events (which would inflate coupons).
- Not withhold Yield events (which would suppress coupons).

This is identical to the trust model of ERC-8056 itself: the issuer is the source of truth for the UI multiplier. The extension adds transparency (class attribution and checkpoint history) but does not remove the issuer's role.

### Front-running `deployOrGet`

The canonical registry enforces one wrapper per underlying by binding `scaledUnderlying == underlying`. A third party cannot front-run registration with an untrusted extension, because the two addresses must match. The ERC-165 check provides a second layer of validation.

### Solvency of the shared vault

Because `coupon + share = 1` (both in 1e18 fixed point, summing to `MULTIPLIER_DECIMALS`), the total claim of both legs always equals the deposit. The shared raw vault stays solvent by construction: total claims never exceed `rawLocked`.

### Rounding

Solo redemption functions (`unwrapYield`, `unwrapCapital`) use `Math.mulDiv` which rounds down. A user never over-claims; dust is stranded in the wrapper. This is a conservative rounding direction that preserves solvency.

### `previewCapitalUI` is display-only

`previewCapitalUI` reads the *live* Supply factor. It must never be used as a redemption amount. Raw claims are always driven by the frozen coupon/share path. The interface documentation and implementation clearly scope this as a display helper.

### ERC-20 assumption

The wrapper assumes the underlying is a standard ERC-20 with no fee-on-transfer and no rebasing. The `wrap` function increments `rawLocked` before `safeTransferFrom` to satisfy check-effects-interactions ordering. If the underlying is not a standard ERC-20, the wrapper may not behave as expected.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE-CC0).
