# ERC-8056 Improvement: Class-Decomposed UI Scaling & Capital/Yield Wrapping

A Foundry (Solidity 0.8.24) reference implementation of an **ERC-8056
improvement** that decomposes UI scaling into named classes and uses that
decomposition to split an RWA token into **Capital** and **Yield** ERC-20 legs
with nonce-based (event-based) expiration.

- [`ERC8056`](src/ERC8056.sol) — the base ERC-8056 reference implementation (single composite multiplier).
- [`ERC8056Composite`](src/ERC8056Composite.sol) — the extension: class-decomposed scaling (`Supply` / `Yield` / `Other`), scheduled pending updates, and a per-class checkpoint history that also serves as the yield-event log.
- [`ERC8056PairWrapper`](src/wrapper/ERC8056PairWrapper.sol) — a standalone wrapper (WETH-for-ETH-style, i.e. a separate adapter contract rather than folded into the base token) that splits raw RWA into a Capital LegToken and a Yield LegToken (one shared `LegToken` contract, deployed twice per window) with frozen-delta, nonce-gated redemption. Protocols integrate against the stable [`IERC8056PairWrapper`](src/interfaces/wrapper/IERC8056PairWrapper.sol) surface, discovered via the canonical [`ERC8056PairWrapperRegistry`](src/wrapper/ERC8056PairWrapperRegistry.sol) — see [INTEGRATION](docs/INTEGRATION.md).

## Why this exists

ERC-8056 adjusts a single UI multiplier, so the **reason** for a change is
indistinguishable: a 2-for-1 split (supply change) and a dividend reinvestment
(yield accretion) both move the same number. That makes it impossible to split
a token into principal + yield on-chain, which is exactly what lending,
options, and auction protocols need for RWA like Robinhood stock tokens.

This repo adds named scaling classes and a wrapper that turns the
yield-scaling history into a Capital/Yield split with **event-based expiry**,
solving the case where real-world yield accrues in discrete events (dividends)
rather than continuously. See [MOTIVATION](docs/MOTIVATION.md) and
[TECHNICAL](docs/TECHNICAL.md).

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
git clone --recurse-submodules https://github.com/SolidityDrone/ERC8056-b.git
cd ERC8056-b
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
│   │       ├── IERC8056PairWrapper.sol
│   │       └── IERC8056PairWrapperRegistry.sol
│   ├── wrapper/
│   │   ├── ERC8056PairWrapper.sol      # Capital/Yield window wrapper
│   │   ├── ERC8056PairWrapperRegistry.sol # canonical per-asset wrapper discovery
│   │   └── LegToken.sol               # fungible ERC-20 receipt (capital or yield leg)
│   └── libraries/
│       └── UIScalingMath.sol           # canonical composite math
├── test/                              # unit, fuzz, and invariant suites
├── docs/
│   ├── MOTIVATION.md                  # why this proposal exists
│   ├── TECHNICAL.md                   # extension spec, expiry, use cases
│   ├── INTEGRATION.md                 # wrapper interface + registry guide
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

### Wrapper & registry (integration surface)

| Interface | Methods |
|-----------|---------|
| `IERC8056PairWrapper` | `wrap`, `unwrap`/`unwrapYield`/`unwrapCapital`, `pairs`/`capitalToken`/`yieldToken`, `couponOf`/`capitalShareOf`, previews, per-window supplies, `currentNonce`, `windowBackingOf`, `rawLocked()`/`rawLockedOf` (deprecated) |
| `IERC8056PairWrapperRegistry` | `deployOrGet`, `wrapperFor`, `wrapperCount`/`wrapperAt`, `underlyingOf` |

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
| 2 | Base `newUIMultiplier()` | the single pending multiplier | product over classes with a **live pending announcement**; active factors otherwise — i.e. the composite once every pending update lands |
| 3 | Base `effectiveAt()` | the single pending effective timestamp | earliest pending `effectiveAt` across classes; if none is live, the most recent effective event timestamp (`0` only if nothing was ever scheduled) |
| 4 | Base cancel (`cancelPendingUIMultiplier()`) | cancels the single pending update | cancels **every** class with a live pending announcement (vanilla behavior generalized); reverts `NothingToCancel` when none pending |
| 5 | Composite-at-nonce `uiMultiplierAtNonce(n)` | n/a (new view) | per-class clamping: each class uses `min(nonce, classNonce)`, `0 → 1e18`; saturates at `type(uint256).max` instead of reverting for extreme factors or large nonces; converges to `uiMultiplier()` |
| 6 | Reads between a proxy upgrade and the first schedule | vanilla values from its own slots | composite reads serve the inherited vanilla slots (denomination + pending preserved); history/nonce views stay empty until genesis is bootstrapped |
| 7 | Schedule notice | any future timestamp | optional issuer self-restraint: after `setMinNoticePeriod(seconds)` every schedule must be ≥ `minNoticePeriod` away (default 0 = vanilla-compatible; capped at 3650 days) |

## License

Code: [MIT](LICENSE) · Specification text: [CC0](LICENSE-CC0).