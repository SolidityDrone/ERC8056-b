# MOTIVATION

Why an EIP-8056 improvement? Because EIP-8056 as written cannot support
principal/yield decomposition, and RWA protocols (lending, options, auctions)
urgently need it.

## The core limitation of EIP-8056

EIP-8056 exposes a single composite `uiMultiplier`. When the off-chain issuer
updates it, the on-chain token only sees a new number — **not the reason** the
number changed.

Consider a Robinhood-style stock token tracked off-chain:

- A **2-for-1 stock split** halves the raw unit count and doubles the UI
  multiplier. The economic *principal* is unchanged; only the denomination
  changed. This is a **Supply** effect.
- A **dividend reinvestment** grows the backing pool pro-rata and increases the
  UI multiplier. Every holder's *principal* is unchanged, but they accrued a
  **Yield**.
- A **reverse split**, **ADR ratio change**, or **redenomination** are more
  Supply effects with identical multiplier math.

To an EIP-8056 token, all three are indistinguishable: `uiMultiplier` moved from
1.0x to 2.0x. The contract cannot tell a split (everyone's claim is the same
asset, re-denominated) from a dividend (a *new* yield claim has been created).

## Why that blocks Capital/Yield splitting

Lending, options, and auction protocols work by separating a token's
**principal** from its **yield**:

- A lender wants to lend the *principal* and collect the *yield*.
- An option writer sells the *yield upside*.
- An auction sells rights to future distributions.

To split a token into a `CapitalToken` (claims the frozen principal share) and
a `YieldToken` (claims the frozen coupon), the contract must know **which part
of the multiplier change is yield vs supply**, across a specific window. With a
single `uiMultiplier`, that split is impossible — you cannot attribute a 2x move
between principal and yield, or freeze a window's payout, without knowing why
each change happened and when.

On Robinhood-chain stock tokens this is **currently not doable**: the token is a
black box that only reports a scalar multiplier, with no class attribution and
no history to price a window against.

## The improvement in one sentence

Decompose the multiplier into **named scaling classes** (`Supply`, `Yield`,
`Other`) with a **per-class checkpoint history**, so the reason for every
change is visible, on-chain, and priced deterministically.

Once classes exist:

- A `Yield`-class event means "the backing pool grew pro-rata" — a genuine new
  yield claim.
- A `Supply`-class event means "the denomination changed" — principal-only, a
  display adjustment.
- The checkpoint history turns yield events into a **sequence of nonces**, each
  with a frozen multiplier — the raw material for a Capital/Yield split.

## What this unlocks (protocols)

With a capital/yield split that is precise and event-accurate, protocols can
build on RWA without trusting a single scalar:

- **Lending** — lend `CapitalToken`, accrue and sell `YieldToken` as interest.
- **Options** — write the yield coupon as the option's underlying upside.
- **Auctions** — auction the right to a window's future distributions.
- **Any** application that needs to separate "I own the asset" from "I own its
  growth" on a token that only publishes UI scaling.

The mechanics — how classes, checkpoint history, and nonce-based expiry produce
a deterministic, solvent split — are in [TECHNICAL.md](TECHNICAL.md). The formal
proposal draft is at [PROPOSAL.md](../PROPOSAL.md).