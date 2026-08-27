# MOTIVATION

Why an ERC-8056 improvement? Because ERC-8056 as written cannot support
principal/yield decomposition, and RWA protocols (lending, options, auctions)
urgently need it.

## The core limitation of ERC-8056

ERC-8056 exposes a single composite `uiMultiplier`. When the off-chain issuer
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

To an ERC-8056 token, all three are indistinguishable: `uiMultiplier` moved from
1.0x to 2.0x. The contract cannot tell a split (everyone's claim is the same
asset, re-denominated) from a dividend (a *new* yield claim has been created).

## Why that blocks Capital/Yield splitting

Lending, options, and auction protocols work by separating a token's
**principal** from its **yield**:

- A lender wants to lend the *principal* and collect the *yield*.
- An option writer sells the *yield upside*.
- An auction sells rights to future distributions.

To split a token into a Capital LegToken and a Yield LegToken (one shared
`LegToken` contract, deployed twice per window — the capital leg claims the
frozen principal share, the yield leg the frozen coupon), the contract must know **which part
of the multiplier change is yield vs supply**, across a specific window. With a
single `uiMultiplier`, that split is impossible — you cannot attribute a 2x move
between principal and yield, or freeze a window's payout, without knowing why
each change happened and when.

On Robinhood-chain stock tokens this is **currently not doable**: the token is a
black box that only reports a scalar multiplier, with no class attribution and
no history to price a window against.

This is not hypothetical infrastructure: the vanilla scalar-multiplier model is
already live in production. Chainlink's [Robinhood Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
publish a Total Return Value of `equity market price × uiMultiplier()`, reading
the multiplier (including `newUIMultiplier()` / `effectiveAt()` pending state)
directly from the token contract, and honoring the issuer's `oraclePaused()`
coordination flag through corporate actions. The oracle proves both the
issuer-driven multiplier workflow and one-way consumption of it — but the
single scalar gives oracle consumers no way to attribute changes to yield vs.
supply, which is precisely what this extension unlocks.

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

- **Lending** — lend the Capital LegToken, accrue and sell the Yield LegToken as interest.
- **Options** — write the yield coupon as the option's underlying upside.
- **Auctions** — auction the right to a window's future distributions.
- **Any** application that needs to separate "I own the asset" from "I own its
  growth" on a token that only publishes UI scaling.

## Vanilla permits only derivative valuation — the extension enables RWA valuation too

This matters beyond the wrapper, and it shows concretely in how price oracles
already consume these tokens. Chainlink's
[Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
read `uiMultiplier()` from the token contract and publish
`equity market price × multiplier` as the token's price.

The point is that today the standard only allows protocols to integrate these
tokens in a **derivative** way: the protocol does not value the token as an
RWA, but as a *stock token* — an instrument whose USD price diverges from the
real-world asset as multipliers accrue, and that is the price every oracle
hands out. Eliding the multiplier with a single scalar is all-or-nothing:
splits and dividends vanish together, with no attribution.

By upgrading to this proposal, the same Chainlink tokenized-equity feed can be
read **both ways**: a protocol elides only the **Yield** portion of the price
(`feed ÷ uiScalingFactor(Yield)`) once the feed price is read. The stock token
can then be used both as a derivative instrument and as an RWA tied to the
real-world nominal USD value of the stock — not its altered, multiplier-inflated
price. Which portion of the published price is accreted yield and which is a
pure re-denomination is finally knowable on-chain.

The full integration treatment — formulas for both valuation modes, the
corporate-action pause workflow, and an oracle-consumer checklist — lives in
[CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md](CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md).

The mechanics — how classes, checkpoint history, and nonce-based expiry produce
a deterministic, solvent split — are in [TECHNICAL.md](TECHNICAL.md). For
protocols building on the Capital/Yield split, the wrapper and registry surface
is documented in [INTEGRATION.md](INTEGRATION.md).