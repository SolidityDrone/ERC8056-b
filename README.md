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
- [`ERC8056CompositePairWrapper`](src/ERC8056CompositePairWrapper.sol) — **the wrapper, integrated in the token**: the composite is the Capital/Yield factory itself. `wrap` self-escrows (no approval), discovery is ERC-165 (`IERC8056PairWrapper`, `0x8a8c95d4`), and there is no registry — for centralized issuers that already own the multiplier. See [INTEGRATION](docs/INTEGRATION.md).
- A standalone adapter + registry variant with the same `IERC8056PairWrapper` interface — the earlier, pre-in-token implementation — is archived on the [`legacy/standalone-wrapper-registry`](../../tree/legacy/standalone-wrapper-registry) branch for trustless, multi-issuer deployments.

## Why this exists

ERC-8056 adjusts a single UI multiplier, so the **reason** for a change is
indistinguishable: a 2-for-1 split (supply change) and a dividend reinvestment
(yield accretion) both move the same number. That one ambiguity has two costs:

- You **cannot split** a token into principal + yield on-chain — the raw
  material lending, options, and auction protocols need for RWA like
  Robinhood stock tokens.
- You **cannot un-mix price**: the token is forced to behave as a *derivative*
  (a total-return stock token whose USD price drifts away from the real-world
  asset as dividends compound), even when a protocol wants to price it as the
  real-world asset itself.

This repo delivers **two benefits**, one per cost:

1. **Split into Capital and Yield LegTokens for DeFi.** The multiplier's
   yield-vs-supply attribution becomes knowable on-chain, so a token can be
   split into a fungible Capital LegToken (principal) and Yield LegToken
   (accrued yield) with deterministic, event-accurate expiry — lending
   protocols lend the principal and sell the yield; options write the coupon
   as upside; auctions sell future distributions.
2. **Choose your representation: derivative OR digital twin.** Because the
   Yield portion of the multiplier becomes separable, a protocol reading the
   same Chainlink price feed can treat the token **both ways**:
   - *derivative mode* — feed price as-is (total-return stock token);
   - *digital-twin mode* — elide the Yield factor (`feed ÷ uiScalingFactor(Yield)`)
     to recover a split-adjusted price tied to the **real-world nominal value
     of the stock**, instead of the multiplier-altered price oracles hand out.

   Lending, options, and any valuation logic can therefore be built on the
   real-world representation of the asset, not just its altered stock-token
   price — without waiting for anyone to publish a second oracle.

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
│   │   ├── extension/              # extension interfaces (both are optional extensions of 8056)
│   │   │   ├── composite/          # class-decomposed scaling extension
│   │   │   │   ├── IERC8056Composite.sol   # class extension interface
│   │   │   │   └── IERC8056MultiplierClass.sol # enum { Supply, Yield, Other }
│   │   │   └── wrapper/            # Capital/Yield split extension
│   │   │       └── IERC8056PairWrapper.sol
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

> **Note:** the composite implementation overrides some base reads with
> composite semantics — see the
> [TECHNICAL deviations appendix](docs/TECHNICAL.md#appendix--deviations-from-vanilla-erc-8056)
> and [Retrocompatibility](#retrocompatibility-with-existing-8056-integrations).

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

## Retrocompatibility with existing 8056 integrations

Protocols already integrated against vanilla ERC-8056 — reading
`uiMultiplier()`, pending state, and events from stock tokens as deployed on
Robinhood Chain — keep working unchanged when the issuer upgrades to the
composite:

- **Interface IDs byte-identical.** Every vanilla ID (`0xa60bf13d`,
  `0x4bd27648`, `0x57854fc3`, `0xd890fd71`) is preserved; cancellation lives in
  its own optional interface so the pending-multiplier ID is untouched. All
  pinned by regression tests.
- **Reads are identical.** `uiMultiplier()`, `toUIAmount`, `fromUIAmount`,
  `balanceOfUI`, `totalSupplyUI` return the same values through the upgrade,
  the first schedule, and every later state — verified by a differential suite
  that drives a vanilla token and the upgraded composite through identical
  updates.
- **The pending-state idiom is preserved — and made stricter.**
  `effectiveAt() != 0` still signals an incoming change; when nothing is
  pending, `effectiveAt()` reads `0` (vanilla keeps a stale landed timestamp,
  which can false-positive naive checks) and `newUIMultiplier()` equals
  `uiMultiplier()`, so no phantom update is ever implied.
- **Upgrades are non-disruptive.** No initialization transaction; the display
  denomination is preserved from the moment of upgrade (inherited vanilla
  slots are served until the first schedule); and an unlanded vanilla pending
  update is never silently dropped — the first classed schedule reverts until
  it lands or is cancelled via the legacy cancel, which keeps exact vanilla
  semantics during that window.
- **Events keep their signatures.** `UIMultiplierUpdated` and
  `UIMultiplierCancelled` are unchanged; payloads describe the projected
  composite once classes are pending (declared in the interface docs).

The complete itemized list of semantic deviations (8 items, with vanilla vs.
this implementation behavior) is in the
[TECHNICAL appendix](docs/TECHNICAL.md#appendix--deviations-from-vanilla-erc-8056).

## License

Code: [MIT](LICENSE) · Specification text: [CC0](LICENSE-CC0).