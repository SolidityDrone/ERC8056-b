# Chainlink Tokenized Stock / Equity Integration

How [Chainlink's Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds)
interact with the `uiMultiplier`, why vanilla ERC-8056 forces protocols into a
single valuation mode, and how the composite extension unlocks both modes.

## 1. What Chainlink publishes today

Chainlink operates [Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds)
with [Smart Value Recapture (SVR)](https://docs.chain.link/data-feeds/svr/overview)
live for [Robinhood tokenized stocks](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
on Robinhood Chain and [Base](https://docs.chain.link/data-feeds/tokenized-equity-feeds).
Each feed reports the token's **Total Return Value** through the standard
`AggregatorV3Interface.latestRoundData()`:

```
Token Price = Underlying Equity Market Price × Multiplier
```

where the **Multiplier** is read directly from the token contract's
`uiMultiplier()` — the same vanilla ERC-8056 scalar this repo extends. Per the
[Robinhood Chain oracle docs](https://docs.robinhood.com/chain/oracles-and-price-feeds/):

- `uiMultiplier()` is the shares-per-token ratio, scaled by 1e18.
- Pending state (`newUIMultiplier()`, `effectiveAt()`) and the
  `UIMultiplierUpdated` event are consumed exactly as vanilla ERC-8056 defines them.
- Dividend reinvestments apply small immediate drifts (`1.000 → 1.008`); splits
  and reverse splits apply large scheduled ones (`1.0 → 10.0`).
- During large corporate actions the issuer pauses the feed via an
  `oraclePaused()` flag until the new multiplier and the underlying price are
  aligned, keeping the token price continuous.

The feed therefore **embeds the full multiplier** — splits *and* dividend
reinvestment — into every published price.

## 2. The valuation duality

Because the feed embeds the full multiplier, there are two different things an
application can mean by "the price of this stock token", and vanilla ERC-8056
lets a protocol support only one of them comfortably:

| Mode | What is valued | Price source |
|------|----------------|--------------|
| **Derivative / stock-token mode** | The token as a total-return instrument: `token USD = feed price` | `latestRoundData()` as-is |
| **RWA / real-world mode (digital twin)** | The token's real-world nominal exposure, tied to the listed per-share USD price of the stock | `feed price × 1e18 / uiMultiplier()` |

### Vanilla limitation

Vanilla ERC-8056 exposes one scalar. A protocol that reads the Chainlink feed
prices the token **derivatively** — as a self-referential "stock token" whose
value drifts away from the real-world asset as multipliers accrue. Eliding the
multiplier is an all-or-nothing operation: dividing the feed by the scalar
removes splits and dividends at once, with no way to attribute the difference.
The protocol cannot simultaneously hold a derivative-denominated position and
an RWA-denominated one, price capital vs. accrued-yield portions separately, or
reconcile the token against the real-world nominal value without losing one of
the two views.

### What the composite unlocks

With the class decomposition (`Supply` = splits/re-denomination, `Yield` =
dividend reinvestment, `Other` = fees/taxes), the elision becomes surgical.
Given a feed price `F`:

```
full multiplier M   = uiMultiplier()
yield component Y   = uiScalingFactor(MultiplierClass.Yield)   (1e18-scaled)

Derivative price           = F                          (unchanged, feed as-is)
Real-world per-share price = F × 1e18 / M               (strip everything)
Split-adjusted RWA price   = F × 1e18 / Y               (strip yield only)
Accrued-yield USD value    = F × (Y − 1e18) / Y         (the yield portion alone)
```

So the same token, priced from the same feed, can be treated:

- **derivatively** — an instrument whose price includes all reinvested history
  (margin trading, DEX pricing, perp marks);
- **as an RWA** — a claim tied to the real-world nominal USD value of the
  underlying stock, with the accrued yield partitioned out as its own
  priceable object (collateral valuation, redemption/settlement accounting,
  real-world reconciliation).

The Supply class keeps split/re-denomination effects visible while the Yield
portion — the only part that represents *accreted value* rather than a change
of denomination — is elided or isolated. That attribution is exactly what the
scalar cannot provide and what
[TECHNICAL §3.1.1](TECHNICAL.md) uses for per-leg pricing of the Capital/Yield
wrapper.

## 3. Integration checklist for oracle consumers

1. Read the feed via `latestRoundData()`; check `updatedAt` staleness and
   `decimals()` as with any Chainlink feed.
2. Read the multiplier state from the token: `uiMultiplier()`, and — for
   corporate-action awareness — `newUIMultiplier()`, `effectiveAt()`.
3. Honor `oraclePaused()` where the issuer exposes it: treat `true` as
   "do not trust the price" and keep the staleness check as the primary guard.
4. Choose the valuation mode per use case (see §2), and convert with
   `Math.mulDiv` — the feed price, multiplier, and class factors are all
   integers scaled by 1e18.
5. On composite tokens, prefer class-scoped reads
   (`uiScalingFactor(class)`) over string-diffing multiplier deltas to
   attribute price changes to yield vs. supply.

## 4. References

- [Tokenized Equity Feeds — Chainlink documentation](https://docs.chain.link/data-feeds/tokenized-equity-feeds)
- [Robinhood Tokenized Equities — Chainlink documentation](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
- [Oracles & Price Feeds — Robinhood Chain documentation](https://docs.robinhood.com/chain/oracles-and-price-feeds/)
- [Stock Tokens & the multiplier — Robinhood Chain documentation](https://docs.robinhood.com/chain/stock-tokens/)
- [ERC-8056 — Scaled UI Amount Extension](https://eips.ethereum.org/EIPS/eip-8056)
