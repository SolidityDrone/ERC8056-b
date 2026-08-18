# Proposal: Class-Decomposed UI Scaling and Nonce-Based Capital/Yield Wrapping for EIP-8056

**Status:** Draft
**Category:** ERC — Token Standard (improvement to ERC-8056)
**Author:** SolidityDrone
**Created:** 2026-08-18
**Requires:** EIP-8056

---

## Simple Summary

An extension to EIP-8056 that decomposes the UI multiplier into named scaling
classes (`Supply`, `Yield`, `Other`) and uses the resulting yield-event history
to split a token into fungible **Capital** and **Yield** ERC-20 legs with
nonce-based (event-based) expiration.

## Abstract

EIP-8056 exposes a single `uiMultiplier`. A change to that multiplier is
indistinguishable between a supply event (split, reverse split, ADR ratio
change) and a yield event (dividend, DRIP, distribution). Protocols cannot
therefore split an RWA token into principal and yield on-chain. This proposal
adds: (1) a scaling-class decomposition with per-class cumulative factors and
checkpoint history; (2) a derived yield nonce that counts effective yield
events; and (3) a standalone wrapper that prices Capital/Yield pairs from frozen
historical checkpoints with expiry measured in yield events rather than time.
The split enables lending, options, and auction protocols to separate ownership
of an asset from ownership of its yield.

## Motivation

Real-world assets that accrue yield in discrete events — dividends, DRIP,
distributions — publish a single UI multiplier through EIP-8056. That scalar
cannot distinguish a stock split (principal re-denomination, same economics)
from a dividend (a new pro-rata yield claim). Without the distinction it is
impossible to construct a principal token (`CapitalToken`) and a yield token
(`YieldToken`) that can be lent, written against, or auctioned separately. This
is currently not doable for Robinhood-chain stock tokens, which only expose a
scalar multiplier.

Time-based expiry fails for this kind of yield: a dividend announced for a date
but landed late leaves a window "expired" and worthless before the multiplier
update that should have made it pay. The proposal therefore measures locks in
yield events (nonces), so maturity tracks the actual event rather than a wall
clock, and is compatible with delayed UI multiplier updates.

## Specification

### Interface

The extension `IERC8056TokenClasses` is inherited alongside the existing
EIP-8056 interfaces. All scaling updates MUST specify a `UIScalingClass`; there
is no generic monolithic multiplier setter.

```solidity
enum UIScalingClass { Supply, Yield, Other }

interface IERC8056TokenClasses {
    struct ScalingCheckpoint { uint256 effectiveAt; uint256 cumulativeFactor; }
    struct YieldEvent      { uint256 timestamp;   uint256 multiplier; }

    event UIScalingFactorUpdated(
        UIScalingClass indexed scalingClass,
        uint256 oldFactor, uint256 newFactor, uint256 effectiveAtTimestamp
    );

    function uiScalingFactor(UIScalingClass scalingClass) external view returns (uint256);
    function uiScalingFactorAt(UIScalingClass scalingClass, uint256 timestamp) external view returns (uint256);
    function uiMultiplierAt(uint256 timestamp) external view returns (uint256);
    function pendingUIScalingFactor(UIScalingClass scalingClass) external view returns (uint256);
    function scalingFactorEffectiveAt(UIScalingClass scalingClass) external view returns (uint256);
    function hasPendingScalingFactor(UIScalingClass scalingClass) external view returns (bool);
    function scalingHistoryLength(UIScalingClass scalingClass) external view returns (uint256);
    function scalingCheckpointAt(UIScalingClass scalingClass, uint256 index)
        external view returns (ScalingCheckpoint memory);

    function yieldNonce() external view returns (uint256);
    function yieldEventAt(uint256 nonce) external view returns (YieldEvent memory);

    function setUIScalingFactor(UIScalingClass scalingClass, uint256 newFactor, uint256 effectiveAtTimestamp) external;
    function applyUIScalingDelta(UIScalingClass scalingClass, uint256 factorDelta, uint256 effectiveAtTimestamp) external;
}
```

### Composite multiplier

`uiMultiplier()` is always the product of every class factor:

```
uiMultiplier = Supply × Yield × Other        (each 1e18 fixed point)
```

The decomposition can never drift from the displayed multiplier.

### Yield nonce (derived)

`yieldNonce()` counts Yield checkpoints with `effectiveAt <= now`, excluding the
genesis checkpoint and any pending (future) updates. `yieldEventAt(nonce)` maps
nonce `n` to checkpoint index `n` (1-based events). The nonce is derived from
history — zero new storage — and ticks only when a dividend actually lands.

### Wrapper (optional, standalone)

A standalone `ERC8056PairWrapper` consumes the extension to split raw RWA into
per-window `CapitalToken` / `YieldToken` ERC-20 pairs:

- `wrap(raw, lockNonces)` at nonce `N` creates/joins pair `(N, N + lockNonces)`,
  minting `raw` Capital + `raw` Yield (1:1 raw).
- Frozen coupon `= max(1 - Y_start / Y_target, 0)`; capital share `= 1 - coupon`.
- `unwrap` (both legs) is exact anytime; `unwrapYield` / `unwrapCapital` are
  gated by `yieldNonce() >= targetNonce`.
- Because `coupon + share = 1`, a single shared raw vault stays solvent.

## Rationale

The wrapper is kept **standalone** (WETH-to-ETH style) so any EIP-8056-compliant
token can opt in without coupling the base standard to pairing logic; the
in-ERC integration is equally valid and is a deployment choice. Nonce-based
expiry is chosen over time-based expiry because discrete RWA yield must not be
penalized by issuer calendar slip, and it remains compatible with delayed UI
multiplier updates.

## Backwards Compatibility

All EIP-8056 interfaces and functions are unchanged. `Supply = 0` and `Yield = 1`
enum values are preserved; `Other = 2` is appended. Existing EIP-8056 tokens are
unaffected.

## Reference Implementation

- `src/ERC8056.sol` — base EIP-8056 reference implementation.
- `src/ERC8056TokenClasses.sol` — class-decomposed extension.
- `src/ERC8056PairWrapper.sol` — standalone Capital/Yield wrapper.
- `src/interfaces/IERC8056TokenClasses.sol` — extension interface.
- `src/interfaces/UIScalingClass.sol` — the scaling-class enum.

## Security Considerations

The wrapper's solvency holds by construction (`coupon + share = 1`). Pricing
reads only historical checkpoints; the current multiplier is never read. The
central authority (issuer) is the trusted source for `applyUIScalingDelta`, as
it is for the UI multiplier itself in EIP-8056. See `docs/TECHNICAL.md` for the
full security and mechanics treatment.

## Copyright

Copyright and related rights waived via [CC0](LICENSE-CC0) (per
[EIP-1](https://eips.ethereum.org/EIPS/eip-1)).