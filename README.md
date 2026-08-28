# ERC-8056 Scaling Classes — Class-Decomposed UI Scaling & Capital/Yield Wrapping

> **⚠️ Disclaimer — reference work, not production code.**
> This repository is a *demonstration*: it exists to show ERC-8056 implementers
> what their ecosystem could unlock if the current single-multiplier behavior
> were steered toward class-decomposed scaling. It has not been audited, is not
> battle-tested on mainnet, and is **not meant to be thrown into production**.
> Treat it as a reference for design discussion and as a starting point for
> your own implementation — not as a ready-to-ship contract.

A Foundry (Solidity 0.8.24) reference implementation that extends
**ERC-8056** with class-decomposed UI scaling and uses that decomposition to
split an RWA token into **Capital** and **Yield** ERC-20 legs with
nonce-based (event-based) expiration.

- [`ERC8056`](src/ERC8056.sol) — the base ERC-8056 reference implementation (single composite multiplier).
- [`ERC8056Composite`](src/ERC8056Composite.sol) — the extension: class-decomposed scaling (`Supply` / `Yield` / `Other`), scheduled pending updates, and a per-class checkpoint history that also serves as the yield-event log.
- [`ERC8056CompositePairWrapper`](src/ERC8056CompositePairWrapper.sol) — **the wrapper, integrated in the token**: the composite is the Capital/Yield factory itself. `wrap` self-escrows (no approval), discovery is ERC-165 (`IERC8056PairWrapper`, `0xf27375cb`), and there is no registry — for centralized issuers that already own the multiplier. See [INTEGRATION](docs/INTEGRATION.md).
- A standalone adapter + registry variant with the same `IERC8056PairWrapper` interface — the earlier, pre-in-token implementation — is archived on the [`legacy/standalone-wrapper-registry`](../../tree/legacy/standalone-wrapper-registry) branch for trustless, multi-issuer deployments.

## Why this exists

ERC-8056 adjusts a single UI multiplier, so the **reason** for a change is
indistinguishable: a 2-for-1 split (supply change) and a dividend reinvestment
(yield accretion) both move the same number. That makes it impossible to split
a token into principal + yield on-chain, which is exactly what lending,
options, and auction protocols need for RWA like Robinhood stock tokens.

This repo delivers **two benefits**:

1. **Split into Capital and Yield LegTokens for DeFi.** The multiplier's
   yield-vs-supply attribution becomes knowable on-chain, so a token can be
   split into a fungible Capital LegToken (principal) and Yield LegToken
   (accrued yield) with deterministic, event-accurate expiry — the primitive
   lending, options, and auction protocols need.
2. **Build protocols on the real-world value of the asset — not the STOCK
   TOKEN price.** The yield portion of a multiplier change becomes elidable,
   so the same Chainlink price feed lets a protocol value the token as the
   real-world asset (nominal USD value of the underlying stock) instead of the
   total-return stock-token price oracles hand out.

See [MOTIVATION](docs/MOTIVATION.md) and [TECHNICAL](docs/TECHNICAL.md).

> **Production context:** this vanilla model is live today — Chainlink's
> [Robinhood Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
> read `uiMultiplier()` from the token contract to publish
> `equity price × multiplier` (Total Return Value) prices. The extension
> adds the class attribution those feeds' consumers cannot get from a scalar.
>
> Both valuation modes (derivative vs. real-world) and the formulas:
> [CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md](docs/CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md).

## Quickstart

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`) — the only toolchain dependency.
- Solidity 0.8.24 (pinned in `foundry.toml`).

### Install & build

```shell
# Install Foundry (skip if already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and build
git clone --recurse-submodules https://github.com/SolidityDrone/erc-8056-scaling-classes.git
cd erc-8056-scaling-classes
forge build
```

If you already cloned without submodules, run `git submodule update --init
--recursive` before building. Submodules are `openzeppelin-contracts` and
`forge-std` (declared in `.gitmodules`).

### Run the tests

```shell
forge test          # full suite
forge fmt --check   # formatting
forge build         # compile
```

The invariant suite (solvency, frozen claims, no-stuck-raw) runs 256 sequences
of 100 handler calls (~70 s) and is configured in `foundry.toml`.

## Layout

```
.
├── foundry.toml                    # build/test/invariant config (solc 0.8.24)
├── src/
│   ├── ERC8056.sol                 # base ERC-8056 reference implementation
│   ├── ERC8056Composite.sol        # class-decomposed extension
│   ├── interfaces/
│   │   ├── base/                   # base ERC-8056 interfaces
│   │   │   ├── IERC8056.sol        # core 8056 interface
│   │   │   ├── IERC8056Conversion.sol  # toUIAmount/fromUIAmount
│   │   │   ├── IERC8056Balances.sol    # balanceOfUI/totalSupplyUI
│   │   │   ├── IERC8056NewUIMultiplier.sol # newUIMultiplier/effectiveAt (spec ID 0x4bd27648)
│   │   │   └── IERC8056Cancel.sol      # cancelPendingUIMultiplier/UIMultiplierCancelled
│   │   ├── extension/              # extension-only interfaces
│   │   │   ├── IERC8056Composite.sol   # class extension interface
│   │   │   └── IERC8056MultiplierClass.sol # enum { Supply, Yield, Other }
│   │   └── wrapper/                # wrapper integration interfaces
│   │       └── IERC8056PairWrapper.sol
│   ├── ERC8056CompositePairWrapper.sol  # the composite IS the wrapper
│   ├── LegToken.sol                   # fungible ERC-20 receipt (capital or yield leg)
│   └── libraries/
│       └── UIScalingMath.sol           # canonical composite math
├── test/                              # unit, fuzz, and invariant suites
├── docs/
│   ├── MOTIVATION.md                  # why this proposal exists
│   ├── TECHNICAL.md                   # extension spec, expiry, use cases
│   ├── INTEGRATION.md                 # consumer guide: the in-token Capital/Yield split
│   └── CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md  # oracle/valuation duality
```

## Scaling classes

```
uiMultiplier = Supply × Yield × Other   (each 1e18 fixed point)
```

- **Supply** — splits, reverse splits, ADR ratio changes, redenomination. Same economics, different count.
- **Yield** — dividends, DRIP, distributions, pro-rata buyback benefit. The backing pool grew pro-rata. **Only** this class ticks the wrapper's yield nonce / coupon.
- **Other** — fees, taxes, governance re-denominations. Composes into the total but does not drive the wrapper's pricing.

## Interface surface

### Legacy ERC-8056

| Interface | Methods |
|-----------|---------|
| `IERC8056` | `uiMultiplier()`, `UIMultiplierUpdated`, `TransferWithUIAmount` |
| `IERC8056NewUIMultiplier` | `newUIMultiplier()`, `effectiveAt()` (spec ID `0x4bd27648`, unchanged from vanilla ERC-8056) |
| `IERC8056Cancel` | `cancelPendingUIMultiplier()`, `UIMultiplierCancelled` (addition of this EIP — vanilla ERC-8056 has no cancel entrypoint) |
| `IERC8056Conversion` | `toUIAmount(uint256)`, `fromUIAmount(uint256)` |
| `IERC8056Balances` | `balanceOfUI(address)`, `totalSupplyUI()` |

> **Note:** the composite implementation overrides the base reads with
> composite semantics — see [Deviations](#deviations-from-vanilla-erc-8056).

### Extension (class decomposition)

| Interface | Methods |
|-----------|---------|
| `IERC8056Composite` | per-class `uiScalingFactor*`, `uiMultiplierAt` overloads, `uiMultiplierAtNonce` overloads, pending/history views, `getClassNonce(MultiplierClass)`, `classEventAtNonce(MultiplierClass, uint256)`, 6-arg `setUIMultiplier(class, newMultiplier, effectiveAtTimestamp, id, description, uri)`, `cancelPendingUIMultiplier(MultiplierClass)`, optional issuer notice period (`minNoticePeriod()`/`setMinNoticePeriod(uint256)`) |
| `ERC8056Composite` | per-class `toUIAmount(raw, class)`, `toUIAmountAt`, `fromUIAmount` |
| `UIScalingMath` | `composeUiMultiplier(Supply, Yield, Other)` |

### Wrapper (integration surface)

| Interface | Methods |
|-----------|---------|
| `IERC8056PairWrapper` | `wrap` (self-escrow), `unwrap`/`unwrapYield`/`unwrapCapital` (all return raw released), `isMatured(start,target)`, `pairs`/`capitalToken`/`yieldToken`, `couponOf`/`capitalShareOf`, previews, per-window supplies, `currentNonce`, `windowBackingOf`, `rawLocked()`/`rawLockedOf` (deprecated) |

Implemented by the token itself via [`ERC8056CompositePairWrapper`](src/ERC8056CompositePairWrapper.sol)
and advertised through ERC-165 (`0x8a8c95d4`) alongside `IERC8056Composite`
(`0xf9712df3`) — a vanilla-8056 token without the split answers
`composite = true, wrapper = false`.
See [INTEGRATION](docs/INTEGRATION.md) for the full consumer guide.

## Redemption model

| Action | Payoff | Gate |
|--------|--------|------|
| `unwrap` (both legs) | exactly `amount` | anytime |
| `unwrapYield` | `amount * coupon` | `getClassNonce(MultiplierClass.Yield) >= target` |
| `unwrapCapital` | `amount * (1 - coupon)` | `getClassNonce(MultiplierClass.Yield) >= target` |

Where `coupon = max(1 - Y_start / Y_target, 0)` in 1e18 fixed point, frozen at
the target nonce from historical checkpoints only. Because `coupon + share = 1`,
every pair's total claim equals its deposit and the shared raw vault stays
solvent by construction.

## Deviations from vanilla ERC-8056

The composite implementation keeps every vanilla ERC-8056 interface ID intact,
but a few base-interface reads/writes have composite semantics:

| # | Deviation | Vanilla behavior | This implementation |
|---|-----------|------------------|---------------------|
| 1 | Legacy 2-arg `setUIMultiplier(uint256,uint256)` | writes dead single-multiplier storage | delegates to the **Supply** class; emits both `UIScalingFactorUpdated` (empty announcement fields) and `UIMultiplierUpdated` |
| 2 | Base `newUIMultiplier()` | the single pending multiplier | product over classes with a **live pending announcement**; when nothing is pending anywhere, the active composite (== `uiMultiplier()`) — no phantom update |
| 3 | Base `effectiveAt()` | the single pending effective timestamp (stays nonzero after landing until overwritten) | earliest pending `effectiveAt` across classes; `0` whenever nothing is pending on any class — stricter than vanilla, which leaves a stale landed timestamp |
| 4 | Base cancel (`cancelPendingUIMultiplier()`) | cancels the single pending update | cancels **every** class with a live pending announcement (vanilla behavior generalized); reverts `NothingToCancel` when none pending |
| 5 | Composite-at-nonce `uiMultiplierAtNonce(n)` | n/a (new view) | per-class clamping: each class uses `min(nonce, classNonce)`, `0 → 1e18`; saturates at `type(uint256).max` instead of reverting for extreme factors or large nonces; converges to `uiMultiplier()` |
| 6 | Reads between a proxy upgrade and the first schedule | vanilla values from its own slots | composite reads serve the inherited vanilla slots (denomination + pending preserved); history/nonce views stay empty until genesis is bootstrapped |
| 7 | Schedule notice | any future timestamp | optional issuer self-restraint: after `setMinNoticePeriod(seconds)` every schedule must be ≥ `minNoticePeriod` away (default 0 = vanilla-compatible; capped at 3650 days) |
| 8 | First schedule on an upgraded proxy with an unlanded vanilla pending | vanilla update stays in its slots until landing/cancel | reverts `VanillaPendingUpdate(effectiveAt)`; resolve by letting the vanilla update land or cancelling it (legacy cancel keeps exact vanilla semantics during the window) |

## License

Code: [MIT](LICENSE) · Specification text: [CC0](LICENSE-CC0).