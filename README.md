# ERC-8056 Improvement: Class-Decomposed UI Scaling & Capital/Yield Wrapping

A Foundry (Solidity 0.8.24) reference implementation of an **EIP-8056
improvement** that decomposes UI scaling into named classes and uses that
decomposition to split an RWA token into **Capital** and **Yield** ERC-20 legs
with nonce-based (event-based) expiration.

- [`ERC8056`](src/ERC8056.sol) — the base EIP-8056 reference implementation (single composite multiplier).
- [`ERC8056TokenClasses`](src/ERC8056TokenClasses.sol) — the extension: class-decomposed scaling (`Supply` / `Yield` / `Other`), scheduled pending updates, and a per-class checkpoint history that also serves as the yield-event log.
- [`ERC8056PairWrapper`](src/ERC8056PairWrapper.sol) — a standalone wrapper (WETH-for-ETH-style, i.e. a separate adapter contract rather than folded into the base token) that splits raw RWA into per-window `CapitalToken` / `YieldToken` ERC-20 pairs with frozen-delta, nonce-gated redemption. Protocols integrate against the stable [`IERC8056PairWrapper`](src/interfaces/IERC8056PairWrapper.sol) surface, discovered via the canonical [`ERC8056PairWrapperRegistry`](src/ERC8056PairWrapperRegistry.sol) — see [INTEGRATION](docs/INTEGRATION.md).

## Why this exists

EIP-8056 adjusts a single UI multiplier, so the **reason** for a change is
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

### Deploy

```shell
forge script script/DeployERC8056.s.sol --rpc-url <RPC> --broadcast
forge script script/DeployERC8056TokenClasses.s.sol --rpc-url <RPC> --broadcast
```

## Layout

```
.
├── foundry.toml                 # build/test/invariant config (solc 0.8.24)
├── src/
│   ├── ERC8056.sol              # base EIP-8056 reference implementation
│   ├── ERC8056TokenClasses.sol  # class-decomposed extension
│   ├── ERC8056PairWrapper.sol   # Capital/Yield window wrapper (standalone)
│   ├── ERC8056PairWrapperRegistry.sol # canonical per-asset wrapper discovery
│   ├── interfaces/
│   │   ├── IERC8056.sol            # core 8056 interface
│   │   ├── IERC8056Conversion.sol  # toUIAmount/fromUIAmount
│   │   ├── IERC8056Balances.sol    # balanceOfUI/totalSupplyUI
│   │   ├── IERC8056NewUIMultiplier.sol # newUIMultiplier/effectiveAt
│   │   ├── IERC8056TokenClasses.sol   # class extension interface
│   │   ├── IERC8056PairWrapper.sol   # wrapper integration surface
│   │   ├── IERC8056PairWrapperRegistry.sol # registry surface
│   │   └── UIScalingClass.sol        # enum { Supply, Yield, Other }
│   ├── libraries/
│   │   └── UIScalingMath.sol     # canonical composite math
│   └── tokens/
│       ├── CapitalToken.sol      # principal-leg ERC-20 receipt
│       └── YieldToken.sol        # yield-leg ERC-20 receipt
├── script/                       # deploy scripts
├── test/                         # unit, fuzz, and invariant suites
├── docs/
│   ├── MOTIVATION.md             # why this proposal exists
│   ├── TECHNICAL.md              # extension spec, expiry, use cases
│   ├── INTEGRATION.md            # wrapper interface + registry guide
```

## Scaling classes

```
uiMultiplier = Supply × Yield × Other   (each 1e18 fixed point)
```

- **Supply** — splits, reverse splits, ADR ratio changes, redenomination. Same economics, different count.
- **Yield** — dividends, DRIP, distributions, pro-rata buyback benefit. The backing pool grew pro-rata. **Only** this class ticks the wrapper's yield nonce / coupon.
- **Other** — fees, taxes, governance re-denominations. Composes into the total but does not drive the wrapper's pricing.

## Interface surface

### Legacy EIP-8056 (unchanged)

| Interface | Methods |
|-----------|---------|
| `IERC8056` | `uiMultiplier()`, `UIMultiplierUpdated`, `TransferWithUIAmount` |
| `IERC8056NewUIMultiplier` | `newUIMultiplier()`, `effectiveAt()` |
| `IERC8056Conversion` | `toUIAmount(uint256)`, `fromUIAmount(uint256)` |
| `IERC8056Balances` | `balanceOfUI(address)`, `totalSupplyUI()` |

### Extension (class decomposition)

| Interface | Methods |
|-----------|---------|
| `IERC8056TokenClasses` | per-class `uiScalingFactor*`, `uiMultiplierAt`, pending/history views, `yieldNonce()`, `yieldEventAt(nonce)`, `setUIScalingFactor`, `applyUIScalingDelta` |
| `ERC8056TokenClasses` | per-class `toUIAmount(raw, class)`, `toUIAmountAt`, `fromUIAmount` |
| `UIScalingMath` | `composeUiMultiplier(Supply, Yield, Other)` |

### Wrapper & registry (integration surface)

| Interface | Methods |
|-----------|---------|
| `IERC8056PairWrapper` | `wrap`, `unwrap`/`unwrapYield`/`unwrapCapital`, `pairs`/`capitalToken`/`yieldToken`, `couponOf`/`capitalShareOf`, previews, supplies, `currentNonce`, `rawLocked`/`rawLockedOf` |
| `IERC8056PairWrapperRegistry` | `deployOrGet`, `wrapperFor`, `wrapperCount`/`wrapperAt`, `underlyingOf` |

See [INTEGRATION](docs/INTEGRATION.md) for the full consumer guide.

## Redemption model

| Action | Payoff | Gate |
|--------|--------|------|
| `unwrap` (both legs) | exactly `amount` | anytime |
| `unwrapYield` | `amount * coupon` | `yieldNonce() >= target` |
| `unwrapCapital` | `amount * (1 - coupon)` | `yieldNonce() >= target` |

Where `coupon = max(1 - Y_start / Y_target, 0)` in 1e18 fixed point, frozen at
the target nonce from historical checkpoints only. Because `coupon + share = 1`,
every pair's total claim equals its deposit and the shared raw vault stays
solvent by construction.

## License

[MIT](LICENSE) — fully open source.