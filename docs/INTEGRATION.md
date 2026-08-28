# Integration Guide: the Capital/Yield split in the ERC-8056 token

This document is the consumer-facing spec for protocols that want to build on
top of ERC-8056's Capital/Yield split — auctions, options, and lending protocols
that need a **principal leg** and a **yield leg** of the same raw RWA token.

On this branch, the split ships **inside the ERC-8056 token itself**:
[`ERC8056CompositePairWrapper`](../src/token-side/ERC8056CompositePairWrapper.sol)
is the composite token (classes, schedules, history) AND the pair factory in one
contract. The stable surface protocols code against is
[`IERC8056PairWrapper`](../src/interfaces/wrapper/IERC8056PairWrapper.sol),
implemented by the token and advertised through ERC-165 — there is no separate
wrapper contract and no registry.

> The standalone adapter + registry variant (`ERC8056PairWrapper` +
> `ERC8056PairWrapperRegistry`) exists on `main` for trustless, multi-issuer
> deployments. Same interface, same semantics — see §7.

---

## 1. Mental model

The stock token is split into **windows**. A window is keyed by
`(startNonce, targetNonce)`:

- `startNonce` = the yield nonce *at the time the user wraps*.
- `targetNonce` = `startNonce + lockNonces`, the yield nonce at which the window
  "expires" (becomes redeemable for yield).

Each window mints exactly **two fungible ERC-20 receipts** in a 1:1 ratio for
every raw unit locked:

- **Capital token** — claim on the underlying principal (redemption scaled by
  `1 - coupon`).
- **Yield token** — claim on the yield accrued over the window (redemption
  scaled by `coupon`).

`coupon + share = 1`, so the two legs always sum to exactly the deposit and the
escrow stays solvent by construction.

```
   stock token balance
      │  token.wrap(rawAmount, lockNonces)   ← self-escrow: no approval
      ▼
   window (startNonce, targetNonce)
      ├── Capital LegToken ──► unwrapCapital: raw * (1 - coupon)
      └── Yield LegToken   ──► unwrapYield:   raw * coupon
                             (both gated until getClassNonce(MultiplierClass.Yield) >= targetNonce)
```

---

## 2. Discovery: ERC-165 on the token

The token advertises both extension surfaces as independent interface IDs:

```solidity
import {IERC8056Composite} from "../src/interfaces/extension/IERC8056Composite.sol";
import {IERC8056PairWrapper} from "../src/interfaces/wrapper/IERC8056PairWrapper.sol";

bool isComposite = token.supportsInterface(type(IERC8056Composite).interfaceId);   // 0xa57626bb
bool splitsItself = token.supportsInterface(type(IERC8056PairWrapper).interfaceId); // 0xf27375cb
```

- `composite = true, wrapper = false` → an ERC-8056 token without the split.
- `wrapper = true` → the token splits itself; `underlying()` and
  `scaledUnderlying()` both return the token address — use that as the sanity
  check that you are talking to the embedded form.

No registry, no adapter probing, no wrapper address book: the token's own
address is the canonical integration point for the asset.

---

## 3. The surface, grouped by what a protocol needs

### 3.1 Splitting (auctions / issuance)

| Member | Notes |
|--------|-------|
| `underlying()` / `scaledUnderlying()` | both the token itself — the escrowed asset and the class-decomposed history source |
| `assetName()` / `assetSymbol()` | the token's own ERC-20 metadata |
| `wrap(rawAmount, lockNonces) -> (start, target)` | **self-escrow**: debits the caller's token balance directly — no approval, one transaction. Mints 1:1 capital+yield and returns the created window |
| `pairs(start, target) -> Pair{capital, yield}` | both leg addresses for a window |
| `capitalToken(start,target)` / `yieldToken(start,target)` | explicit leg getters |
| `hasPair(start,target)` | true if the window was ever created |
| `pairCount()` / `pairAt(i)` | enumerate every window ever created |

After a successful `wrap`, a protocol can read the two receipt addresses and
list them on its auction or forward them to a vault.

### 3.2 Redemption (end users / settlement)

| Member | Notes |
|--------|-------|
| `unwrap(amount, start, target)` | burn **both** legs, receive exactly `amount` — anytime |
| `unwrapYield(amount, start, target)` | burn `amount` yield leg for `amount * coupon` |
| `unwrapCapital(amount, start, target)` | burn `amount` capital leg for `amount * (1 - coupon)` |
| `isMatured(start, target)` | true once the window reached nonce maturity (`currentNonce() >= target`) — solo redemptions unlocked, coupon frozen. Reverts `PairNotFound` for a never-created window |
| `rawLocked()` | total raw escrowed across all windows — always exactly `token.balanceOf(address(token))` |
| `windowBackingOf(start, target)` | **truthful** raw backing of one window: pre-maturity (nonce < target) solo redemptions are gated so each pair holds equal capital/yield amounts and only the combined `unwrap` is exercisable at 1:1 — backing = `min(capitalSupplyOf, yieldSupplyOf)`; post-maturity it is frozen at `capitalSupplyOf * capitalShare + yieldSupplyOf * coupon`. 0 for a nonexistent window |
| `rawLockedOf(start, target)` | **DEPRECATED** — returns the window's outstanding capital supply, which diverges from raw backing after any solo `unwrapYield`. Use `windowBackingOf` instead |

Both solo redemption functions revert `Locked` while `currentNonce() < target`.
`unwrap` is unconditional — it is the safe exit for any window.

### 3.3 Pricing & previews (options, AMMs, lending)

All pricing is **frozen-delta**: computed from historical checkpoints at the
target nonce, never from the live multiplier. This means redemption payoffs are
deterministic and independent of later events.

For USD valuation of the underlying tokenized stock, Chainlink's
[Tokenized Equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
(SVR) already embed the issuer's `uiMultiplier()` in every published price —
protocols can read the feed derivatively (token USD as-is) or as a real-world
asset by eliding the multiplier, and with the composite, by eliding only the
Yield factor. Formulas per valuation mode:
[CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md](CHAINLINK_TOKENIZED_STOCK_EQUITY_INTEGRATION.md).

| Member | Meaning |
|--------|---------|
| `currentNonce()` | current yield nonce (`== getClassNonce(MultiplierClass.Yield)`) |
| `couponOf(start,target)` | frozen yield coupon `max(1 - Y_start/Y_target, 0)`, 1e18 fixed point |
| `capitalShareOf(start,target)` | `1e18 - coupon` |
| `previewUnwrap(amount,start,target)` | `(capitalRawOut, yieldLegRawOut)` — splits exactly to `amount` |
| `previewUnwrapYield(amount,start,target)` | raw for burning `amount` yield leg |
| `previewUnwrapCapital(amount,start,target)` | raw for burning `amount` capital leg |
| `previewCapitalUI(capitalAmount)` | **display only** — composite-UI figure; never a redemption amount |
| `capitalSupplyOf` / `yieldSupplyOf` | per-window supplies (0 if never created) |
| `capitalSupply()` / `yieldSupply()` | aggregate across all windows — **OFF-CHAIN ONLY**: these loop over every created window and will exceed block gas limits as window count grows; never call from on-chain protocols |

> **Note on `previewCapitalUI`:** it applies the *live* Supply factor for UI
> display only. It must never be used as a claim/redeem amount — raw claims are
> always driven by the frozen coupon/share path above.

---

## 4. Worked integration scenarios

### 4.1 Lending: borrow against a principal leg

1. Borrowers `token.wrap(rawAmount, lockNonces)` to get the Capital LegToken
   for window `(s, t)`.
2. The lending protocol takes that LegToken as collateral. It values it via
   `capitalShareOf(s,t)` — or, for a truthful solvency figure,
   `windowBackingOf(s,t)` — rather than the live
   multiplier, so collateral is a *known* function of the window.
3. On liquidation, the protocol `unwrapCapital(collateralAmount, s, t)` — but
   only after `currentNonce() >= t`. Before that it can always `unwrap(...)`
   both legs to recover the full deposit.

### 4.2 Options: exercise value is frozen

1. A call on window `(s, t)` is written against the Yield LegToken (upside) and the Capital LegToken (downside/floored principal).
2. Because `couponOf(s,t)` is frozen once `t` is reached, the option's
   settlement value is deterministic on-chain — there is no oracle race on the
   exercise payoff.
3. Settlement simply calls `unwrapYield` / `unwrapCapital`; no AMM re-pricing
   is needed for the payoff.

### 4.3 Auction: split-and-sell

1. Issuer `token.wrap(rawAmount, lockNonces)` and reads `pairs(s,t)`.
2. The Capital LegToken and Yield LegToken are listed as separate lots with
   independent order books — buyers can hold one leg without owning the other.
3. `unwrap` (both legs) guarantees any holder of the full pair can always exit
   at exactly the deposit, so arbitrageurs keep the two legs near their fair
   split.

---

## 5. Leg token address pattern

```solidity
function legsForWindow(ERC8056CompositePairWrapper token, uint256 start, uint256 target)
    external view returns (IERC20 capital, IERC20 yield)
{
    // Prefer explicit getters over destructuring.
    capital = token.capitalToken(start, target);
    yield   = token.yieldToken(start, target);
}
```

Use `hasPair(start, target)` before interacting with a window you only heard
about off-chain; zero-address legs from `pairs()` indicate a never-created
window.

---

## 6. Conventions & safety

- **The token is the integration point.** One contract is the asset, the
  history, and the splitter. Discovery is ERC-165; there is no registry to
  query and no adapter address to trust. The trust anchor is the issuer — who
  already solely controls every `uiMultiplier` update, so the embedded split
  adds no new trust root.
- **Self-escrow, no approvals.** `wrap` debits the caller internally
  (`_update(msg.sender, address(this), amount)`); payouts move escrow back the
  same way. No `approve` ceremony, and no fee-on-transfer surface: the token
  cannot fee on its own ledger, so `FeeOnTransferNotSupported` can never fire.
- **Legs are standard ERC-20.** `Pair` exposes them as `IERC20` to keep the
  interface concrete-token-free; minting/burning is internal to the token
  (the legs' `minter` is the token address). Legs inherit the token's 18
  decimals, so leg amounts line up 1:1 with raw units.
- **One EIP, one contract.** The embedded wrapper is an optional extension of
  the same ERC-8056 improvement: a compliant issuer may ship the composite
  without it (`supportsInterface` answers `wrapper = false`), and vanilla
  `ERC8056` remains the spec-compatible base layout.
- **Pair creation is permissionless.** Anyone can create a new window with a
  minimal `wrap` (even 1 wei), deploying two LegTokens and appending to the
  token's window enumeration. This is gas-costly for the caller (two contract
  deployments) and harmless for solvency, but indexers/AMMs should NOT iterate
  `pairAt(0..pairCount)` blindly — enumerate windows off-chain from
  `Wrapped` events instead, or apply your own quality filters.
- **Escrow invariant.** `rawLocked() == token.balanceOf(address(token))` holds
  at every step (invariant-tested together with per-window solvency and ghost
  drift).

## 7. References

- Interface: [`IERC8056PairWrapper.sol`](../src/interfaces/wrapper/IERC8056PairWrapper.sol)
- Implementation (this branch): [`ERC8056CompositePairWrapper.sol`](../src/token-side/ERC8056CompositePairWrapper.sol)
- Extension: [`IERC8056Composite.sol`](../src/interfaces/extension/IERC8056Composite.sol)
- Tests: [`ERC8056CompositePairWrapper.t.sol`](../test/ERC8056CompositePairWrapper.t.sol), [`ERC8056CompositePairWrapperFuzz.t.sol`](../test/ERC8056CompositePairWrapperFuzz.t.sol), [`ERC8056CompositePairWrapperInvariant.t.sol`](../test/ERC8056CompositePairWrapperInvariant.t.sol)
- Standalone variant (on `main`): [`ERC8056PairWrapper.sol`](../src/wrapper/ERC8056PairWrapper.sol) + [`ERC8056PairWrapperRegistry.sol`](../src/wrapper/ERC8056PairWrapperRegistry.sol), tests [`ERC8056PairWrapper.t.sol`](../test/ERC8056PairWrapper.t.sol), [`ERC8056PairWrapperRegistry.t.sol`](../test/ERC8056PairWrapperRegistry.t.sol)
