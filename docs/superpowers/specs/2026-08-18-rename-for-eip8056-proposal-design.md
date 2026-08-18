# Rename Contracts/Interfaces for EIP-8056 Proposal Clarity

Date: 2026-08-18
Status: Approved design

## Problem

The base EIP-8056 token (`ScaledUIToken`) and the class-decomposition extension
(`ScaledUIClassedToken`) differ only by the word "Classed", making the
base-vs-extension split unclear. For a repo attached to an Ethereum Magicians
proposal, names should follow the established EIP convention: prefix with the
EIP number, use `I` for interfaces, and name the extension after the feature it
adds.

## Naming scheme

| Current | New |
|---------|-----|
| `src/ScaledUIToken.sol` / `ScaledUIToken` | `src/ERC8056.sol` / `ERC8056` |
| `src/ScaledUIClassedToken.sol` / `ScaledUIClassedToken` | `src/ERC8056TokenClasses.sol` / `ERC8056TokenClasses` |
| `src/ScaledPairWrapper.sol` / `ScaledPairWrapper` | `src/ERC8056PairWrapper.sol` / `ERC8056PairWrapper` |
| `src/interfaces/IScaledUIAmount.sol` / `IScaledUIAmount` | `src/interfaces/IERC8056.sol` / `IERC8056` |
| `src/interfaces/IScaledUIAmountClasses.sol` / `IScaledUIAmountClasses` | `src/interfaces/IERC8056TokenClasses.sol` / `IERC8056TokenClasses` |
| `IScaledUIAmountConversion` | `IERC8056Conversion` |
| `IScaledUIAmountBalances` | `IERC8056Balances` |
| `IScaledUIAmountNewUIMultiplier` | `IERC8056NewUIMultiplier` |

Unchanged (EIP-agnostic pure library / enum / receipts):
- `src/libraries/UIScalingMath.sol`
- `src/interfaces/UIScalingClass.sol`
- `src/tokens/CapitalToken.sol`
- `src/tokens/YieldToken.sol`

## Method

- Rename files with `git mv` to preserve history.
- Rename declared contract/interface names.
- Update every import and reference in: tests, scripts, README, docs.
- Update script contract names (`DeployScaledUIToken` -> `DeployERC8056`, etc.).

## Verification

- `forge test` full suite green (unit + fuzz + invariant).
- `forge build` clean, `forge fmt --check` clean.
- README tables and docs reflect the new names (no stale references).