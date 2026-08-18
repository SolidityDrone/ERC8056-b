# Nonce-Based Yield Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the wrapper's single fungible pair with per-expiry token pairs gated by yield-event nonces, and expose the yield nonce from the ERC-8056 extension.

**Architecture:** The extension (`ScaledUIClassedToken`) derives a yield nonce from its existing Yield-class checkpoints (no new storage). The wrapper (`ScaledPairWrapper`) keeps one shared raw pool but creates one `CapitalToken`/`YieldToken` pair per unlock nonce, chosen at wrap time (`wrap(raw, lockNonces)`); equal-leg unwrap stays exact and ungated, solo leg unwraps are gated by `yieldNonce() >= unlockNonce`.

**Tech Stack:** Solidity ^0.8.24, OpenZeppelin (ERC20, Math, SafeERC20, Strings), forge-std.

## Global Constraints

- `solc ^0.8.24`; remappings `@openzeppelin/contracts/` and `forge-std/` (per `foundry.toml`).
- All claims use the floored yield factor `Y = max(yieldFactor, 1e18)` via `_yieldFactorFloored()`.
- Global invariant preserved by every operation: `rawLocked = capitalSupply/Y + yieldSupply × (1 − 1/Y)` (totals across all pairs; 1–2 wei rounding drift allowed in assertions).
- Per-token yield value `yieldPerTokenRaw() = pool/YS = 1 − 1/Y` is uniform across ALL expiry pairs.
- Equal-leg unwrap (`unwrap(amount, unlockNonce)`) is allowed anytime; solo unwraps (`unwrapYield`/`unwrapCapital`) revert `Locked()` while `yieldNonce() < unlockNonce`.
- The yield nonce counts effective Yield checkpoints only (genesis and pending excluded; Supply updates never tick it).
- All 43 pre-existing ERC-8056 tests must keep passing; the wrapper test suite is rewritten for the new API.
- Follow existing code style: natspec docstrings, `// ─── Section ───` dividers, `error` declarations, no unused imports.

---

### Task 1: Extension yield-event views (nonce)

**Files:**
- Modify: `src/interfaces/IScaledUIAmountClasses.sol`
- Modify: `src/ScaledUIClassedToken.sol`
- Test: `test/ScaledUIClassedToken.t.sol`

**Interfaces:**
- Consumes: existing `_checkpoints[UIScalingClass.Yield]` array of `ScalingCheckpoint { effectiveAt, cumulativeFactor }` (genesis at index 0; at most one pending checkpoint at the end, popped on reschedule).
- Produces: `yieldNonce() returns (uint256)` and `yieldEventAt(uint256 nonce) returns (IScaledUIAmountClasses.YieldEvent memory)` — consumed by Task 2's wrapper.

- [ ] **Step 1: Write the failing tests**

Append this block to `test/ScaledUIClassedToken.t.sol` (before the final closing brace, after the existing tests):

```solidity
    // ─── Yield nonce (event-based expiry) ─────────────────────────────────────

    function test_yieldNonce_zeroInitially() public view {
        assertEq(token.yieldNonce(), 0);
    }

    function test_yieldNonce_ticksOnlyWhenEffective() public {
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 days);
        assertEq(token.yieldNonce(), 0); // pending: not counted
        vm.warp(block.timestamp + 1 days);
        assertEq(token.yieldNonce(), 1);
    }

    function test_yieldNonce_supplyUpdatesDoNotTick() public {
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Supply, DOUBLE, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        assertEq(token.yieldNonce(), 0);
    }

    function test_yieldNonce_countsEffectiveEvents() public {
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, 11e17, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days); // nonce 1
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, 12e17, block.timestamp + 2 days);
        vm.warp(block.timestamp + 1 days); // second update still pending
        assertEq(token.yieldNonce(), 1);
        vm.warp(block.timestamp + 1 days);
        assertEq(token.yieldNonce(), 2);
    }

    function test_yieldNonce_reschedule_keepsSingleEvent() public {
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, 15e17, block.timestamp + 2 days);
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, 15e17, block.timestamp + 4 days); // delayed: pending popped + re-pushed
        vm.warp(block.timestamp + 2 days); // old date passes
        assertEq(token.yieldNonce(), 0);
        vm.warp(block.timestamp + 2 days); // new date
        assertEq(token.yieldNonce(), 1);
    }

    function test_yieldEventAt_returnsTimestampAndMultiplier() public {
        uint256 t1 = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, 15e17, t1);
        vm.warp(t1);

        IScaledUIAmountClasses.YieldEvent memory ev = token.yieldEventAt(1);
        assertEq(ev.timestamp, t1);
        assertEq(ev.multiplier, 15e17);
    }

    function test_yieldEventAt_notRecorded_reverts() public {
        vm.expectRevert(ScaledUIClassedToken.EventNotRecorded.selector);
        token.yieldEventAt(1);
    }

    function test_yieldEventAt_pendingNotVisible_reverts() public {
        vm.prank(owner);
        token.setUIScalingFactor(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 days);
        vm.expectRevert(ScaledUIClassedToken.EventNotEffective.selector);
        token.yieldEventAt(1);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-contract ScaledUIClassedTokenTest`
Expected: FAIL — compile errors: `yieldNonce`/`yieldEventAt` not found on `ScaledUIClassedToken`, `EventNotRecorded`/`EventNotEffective` not found, `YieldEvent` not a member of `IScaledUIAmountClasses`.

- [ ] **Step 3: Add the interface members**

In `src/interfaces/IScaledUIAmountClasses.sol`, after the `ScalingCheckpoint` struct declaration:

```solidity
    struct YieldEvent {
        uint256 timestamp;
        uint256 multiplier;
    }
```

and after `scalingCheckpointAt` (still inside the interface):

```solidity
    /// @dev Yield events that have become effective so far (the "nonce"). 0 before the first dividend.
    function yieldNonce() external view returns (uint256);

    /// @dev Yield event with 1-based `nonce` (genesis is not an event).
    ///      Reverts if the event is not recorded or not yet effective.
    function yieldEventAt(uint256 nonce) external view returns (YieldEvent memory);
```

- [ ] **Step 4: Implement the views in the contract**

In `src/ScaledUIClassedToken.sol`:

Add the errors after `struct ClassScalingState`:

```solidity
    error EventNotRecorded();
    error EventNotEffective();
```

Add the implementations after `scalingCheckpointAt` (still inside the contract):

```solidity
    /// @dev Number of effective Yield events. Derived from the Yield checkpoint
    ///      history: genesis (index 0) is not an event and pending updates
    ///      (effectiveAt in the future) are excluded, so the nonce only ticks
    ///      when a dividend actually lands.
    function yieldNonce() public view override returns (uint256) {
        ScalingCheckpoint[] storage history = _checkpoints[UIScalingClass.Yield];
        uint256 nonce;
        for (uint256 i = 1; i < history.length; i++) {
            if (history[i].effectiveAt <= block.timestamp) {
                nonce++;
            } else {
                break;
            }
        }
        return nonce;
    }

    /// @dev Yield event with 1-based `nonce`: `{timestamp, multiplier}` of the
    ///      nonce-th effective Yield update. Pending updates are not visible.
    function yieldEventAt(uint256 nonce) external view override returns (YieldEvent memory) {
        ScalingCheckpoint[] storage history = _checkpoints[UIScalingClass.Yield];
        uint256 index = nonce + 1; // genesis checkpoint occupies index 0
        if (index >= history.length) revert EventNotRecorded();
        if (history[index].effectiveAt > block.timestamp) revert EventNotEffective();
        return YieldEvent(history[index].effectiveAt, history[index].cumulativeFactor);
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `forge test --match-contract ScaledUIClassedTokenTest`
Expected: PASS — all existing tests plus the 9 new nonce tests (43 total in the suite).

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/IScaledUIAmountClasses.sol src/ScaledUIClassedToken.sol test/ScaledUIClassedToken.t.sol
git commit -m "feat: yield nonce views on classed extension"
```

---

### Task 2: ScaledPairWrapper — per-expiry pairs with nonce-gated locks

**Files:**
- Modify: `src/ScaledPairWrapper.sol` (full rewrite)
- Modify: `test/ScaledPairWrapper.t.sol` (full rewrite)
- Test: `test/ScaledPairWrapper.t.sol`

**Interfaces:**
- Consumes: `yieldNonce()` and `YieldEvent` from Task 1; `uiScalingFactor(UIScalingClass)` from the extension; `CapitalToken`/`YieldToken` as-is (constructor `(name, symbol, minter)`).
- Produces: `wrap(rawAmount, lockNonces) returns (unlockNonce)`, `unwrap(amount, unlockNonce)`, `unwrapYield(amount, unlockNonce)`, `unwrapCapital(amount, unlockNonce)`, `pairs(uint256) returns (Pair memory)`, `pairCount()`, `pairNonceAt(index)`, `currentNonce()`, `capitalSupplyOf(n)`, `yieldSupplyOf(n)`, `previewUnwrap(amount, n)`, `previewUnwrapYield(amount, n)`, `previewUnwrapCapital(amount, n)`, plus unchanged `capitalRawValue`, `poolYieldRaw`, `yieldPerTokenRaw`, `previewCapitalUI`, `rawLocked`, `underlying`, `scaledUnderlying`.

- [ ] **Step 1: Write the failing test suite (full replacement)**

Replace the entire contents of `test/ScaledPairWrapper.t.sol` with:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ScaledPairWrapper} from "../src/ScaledPairWrapper.sol";
import {CapitalToken} from "../src/tokens/CapitalToken.sol";
import {YieldToken} from "../src/tokens/YieldToken.sol";
import {ScaledUIClassedToken} from "../src/ScaledUIClassedToken.sol";
import {UIScalingClass} from "../src/interfaces/UIScalingClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ScaledPairWrapperTest is ScalingTestBase {
    ScaledUIClassedToken internal underlying;
    ScaledPairWrapper internal wrapper;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        underlying = new ScaledUIClassedToken("Stock", "STK", owner);

        wrapper = new ScaledPairWrapper(
            IERC20(address(underlying)),
            underlying,
            "Tesla",
            "Tesla"
        );

        vm.prank(owner);
        underlying.mint(alice, 10_000 ether);
        vm.prank(owner);
        underlying.mint(bob, 10_000 ether);
        vm.prank(owner);
        underlying.mint(carol, 10_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        underlying.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(carol);
        underlying.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _applyYieldDelta(uint256 delta, uint256 delay) internal {
        vm.prank(owner);
        underlying.applyUIScalingDelta(UIScalingClass.Yield, delta, block.timestamp + delay);
        vm.warp(block.timestamp + delay);
    }

    function _applySupplyDelta(uint256 delta, uint256 delay) internal {
        vm.prank(owner);
        underlying.applyUIScalingDelta(UIScalingClass.Supply, delta, block.timestamp + delay);
        vm.warp(block.timestamp + delay);
    }

    function _setYieldFactor(uint256 factor, uint256 delay) internal {
        vm.prank(owner);
        underlying.setUIScalingFactor(UIScalingClass.Yield, factor, block.timestamp + delay);
        vm.warp(block.timestamp + delay);
    }

    function _wrap(address user, uint256 amount) internal {
        _wrapLocked(user, amount, 0);
    }

    function _wrapLocked(address user, uint256 amount, uint256 lockNonces) internal {
        vm.prank(user);
        wrapper.wrap(amount, lockNonces);
    }

    function _capital(uint256 unlockNonce) internal view returns (CapitalToken) {
        return CapitalToken(address(wrapper.pairs(unlockNonce).capital));
    }

    function _yield(uint256 unlockNonce) internal view returns (YieldToken) {
        return YieldToken(address(wrapper.pairs(unlockNonce).yield));
    }

    function _assertPairExact(address user, uint256 unlockNonce, uint256 expected, uint256 tolerance)
        internal
        view
    {
        uint256 capBal = _capital(unlockNonce).balanceOf(user);
        uint256 yldBal = _yield(unlockNonce).balanceOf(user);
        assertEq(capBal, yldBal); // full pairs only — equal-leg invariant
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(capBal, unlockNonce);
        assertApproxEqAbs(capOut + yldOut, expected, tolerance);
    }

    // ─── Pair tokens ──────────────────────────────────────────────────────────

    function test_pairTokens_createdLazilyOnFirstWrap() public {
        assertEq(wrapper.pairCount(), 0);
        _wrap(alice, RAW_STAKE);

        assertEq(wrapper.pairCount(), 1);
        assertEq(wrapper.pairNonceAt(0), 0);
        assertEq(_capital(0).name(), "Capital-0");
        assertEq(_capital(0).symbol(), "Cap0");
        assertEq(_yield(0).name(), "Yield-0");
        assertEq(_yield(0).symbol(), "Yld0");
        assertEq(_capital(0).decimals(), 18);
        assertEq(_yield(0).decimals(), 18);
        assertEq(wrapper.capitalSupply(), RAW_STAKE);
        assertEq(wrapper.yieldSupply(), RAW_STAKE);
        assertEq(wrapper.rawLocked(), RAW_STAKE);
    }

    function test_tokens_areTransferableErc20() public {
        _wrap(alice, RAW_STAKE);

        vm.startPrank(alice);
        _capital(0).transfer(bob, 25 ether);
        _yield(0).transfer(bob, 25 ether);
        vm.stopPrank();

        assertEq(_capital(0).balanceOf(bob), 25 ether);
        assertEq(_yield(0).balanceOf(bob), 25 ether);
        assertEq(wrapper.capitalSupply(), RAW_STAKE);
        assertEq(wrapper.yieldSupply(), RAW_STAKE);
    }

    // ─── Wrap ─────────────────────────────────────────────────────────────────

    function test_wrap_mintsOneToOne() public {
        uint256 aliceBefore = underlying.balanceOf(alice);
        _wrap(alice, RAW_STAKE);

        assertEq(_capital(0).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(0).balanceOf(alice), RAW_STAKE);
        assertEq(wrapper.capitalSupply(), RAW_STAKE);
        assertEq(wrapper.yieldSupply(), RAW_STAKE);
        assertEq(wrapper.rawLocked(), RAW_STAKE);
        assertEq(underlying.balanceOf(alice), aliceBefore - RAW_STAKE);
        assertEq(underlying.balanceOf(address(wrapper)), RAW_STAKE);
    }

    function test_wrap_mintsOneToOneRegardlessOfFactor() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2.0, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=2.0

        assertEq(_capital(0).balanceOf(bob), RAW_STAKE);
        assertEq(_yield(0).balanceOf(bob), RAW_STAKE);
        assertEq(_capital(1).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(1).balanceOf(alice), RAW_STAKE);
        assertEq(wrapper.capitalSupply(), 2 * RAW_STAKE);
        assertEq(wrapper.yieldSupply(), 2 * RAW_STAKE);
        assertEq(wrapper.pairCount(), 2);
        assertEq(wrapper.currentNonce(), 1);
    }

    function test_wrap_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        wrapper.wrap(0, 0);
    }

    function test_wrap_unwrap_anyTime_noTimelock() public {
        _wrap(alice, RAW_STAKE);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
        assertEq(wrapper.rawLocked(), 0);
        assertEq(wrapper.capitalSupply(), 0);
        assertEq(wrapper.yieldSupply(), 0);
    }

    // ─── Capital leg ──────────────────────────────────────────────────────────

    function test_capitalToken_isOneConstantYieldUIUnit() public {
        _wrap(alice, RAW_STAKE);

        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE); // Y=1: 1 raw per token
        assertEq(wrapper.capitalRawValue(1 ether), NEUTRAL); // raw × Y = 1 Yield-UI unit

        _applyYieldDelta(DOUBLE, 1 hours);
        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE / 2); // Y=2: 0.5 raw per token
        assertEq(wrapper.capitalRawValue(1 ether) * DOUBLE / 1e18, NEUTRAL); // still 1 UI unit
    }

    function test_capitalTokens_fungibleAcrossWrapTimes() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1

        // Capital tokens minted in different pairs share one uniform raw value (1/Y).
        assertEq(wrapper.capitalRawValue(RAW_STAKE), Math.mulDiv(RAW_STAKE, 1e18, 11e17));
        assertEq(
            wrapper.capitalRawValue(_capital(0).balanceOf(bob)),
            wrapper.capitalRawValue(_capital(1).balanceOf(alice))
        );
    }

    // ─── Pair-exactness (pool model) ──────────────────────────────────────────

    function test_pairExact_singlePair_yieldDouble() public {
        _wrap(alice, RAW_STAKE); // pair 0
        _applyYieldDelta(DOUBLE, 1 hours);

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 0);
        assertEq(capOut, RAW_STAKE / 2);
        assertEq(yldOut, RAW_STAKE / 2);

        uint256 aliceBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);

        assertEq(underlying.balanceOf(alice), aliceBefore + RAW_STAKE);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
        assertEq(wrapper.rawLocked(), 0);
        assertEq(wrapper.capitalSupply(), 0);
        assertEq(wrapper.yieldSupply(), 0);
    }

    function test_pairExact_singlePair_intermediateFactor() public {
        _wrap(alice, RAW_STAKE); // pair 0
        _applyYieldDelta(15e17, 1 hours); // Y=1.5

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 0);
        assertEq(capOut, 66666666666666666666);
        assertEq(yldOut, 33333333333333333334);
        assertEq(capOut + yldOut, RAW_STAKE);
    }

    function test_pairExact_singlePair_neutralYield() public {
        _wrap(alice, RAW_STAKE); // pair 0

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 0);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);

        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
    }

    function test_pairExact_bobAndAlice_differentWrapFactors() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1

        // Immediately after Alice's wrap, both pairs are exact (1 wei rounding).
        _assertPairExact(bob, 0, RAW_STAKE, 1);
        _assertPairExact(alice, 1, RAW_STAKE, 1);

        _applyYieldDelta(DOUBLE, 1 hours); // Y=2.0, nonce → 2
        _assertPairExact(bob, 0, RAW_STAKE, 0);
        _assertPairExact(alice, 1, RAW_STAKE, 0);

        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, 0);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1);

        assertEq(underlying.balanceOf(address(wrapper)), 0);
        assertEq(underlying.balanceOf(bob), 10_000 ether);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
    }

    function test_pairExact_threeWraps_differentFactors() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1
        _applyYieldDelta(13e17, 1 hours); // Y=1.3, nonce → 2
        _wrap(carol, HALF); // pair 2, 50 @ Y=1.3

        _assertPairExact(bob, 0, RAW_STAKE, 1);
        _assertPairExact(alice, 1, RAW_STAKE, 1);
        _assertPairExact(carol, 2, HALF, 1);

        _setYieldFactor(DOUBLE, 1 hours); // absolute: Y=2.0 exactly, nonce → 3

        _assertPairExact(bob, 0, RAW_STAKE, 0);
        _assertPairExact(alice, 1, RAW_STAKE, 0);
        _assertPairExact(carol, 2, HALF, 0);

        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, 0);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1);
        vm.prank(carol);
        wrapper.unwrap(HALF, 2);

        assertEq(underlying.balanceOf(address(wrapper)), 0);
        assertEq(underlying.balanceOf(bob), 10_000 ether);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(underlying.balanceOf(carol), 10_000 ether);
    }

    function test_pairExact_throughCorporateActions() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0, S=1.0

        _applySupplyDelta(DOUBLE, 1 hours); // split 2-for-1 (nonce unchanged)
        _applyYieldDelta(15e17, 1 hours); // dividend ×1.5, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1, mid-stream wrap
        _applyYieldDelta(DOUBLE, 1 hours); // dividend ×2, nonce → 2
        _applySupplyDelta(HALF, 1 hours); // reverse split ×0.5 (nonce unchanged)
        _setYieldFactor(DOUBLE, 1 hours); // absolute: Y=2.0 exactly, nonce → 3

        _assertPairExact(bob, 0, RAW_STAKE, 1);
        _assertPairExact(alice, 1, RAW_STAKE, 1);

        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, 0);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1);

        assertEq(underlying.balanceOf(address(wrapper)), 0);
        assertEq(underlying.balanceOf(bob), 10_000 ether);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
    }

    // ─── Yield leg fungibility ────────────────────────────────────────────────

    function test_yieldTokens_fungibleUniformValue() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1

        uint256 perToken = wrapper.yieldPerTokenRaw();
        assertGt(perToken, 0);

        // Yield tokens minted in different pairs share one uniform per-token value.
        assertEq(
            Math.mulDiv(_yield(0).balanceOf(bob), perToken, 1e18),
            Math.mulDiv(_yield(1).balanceOf(alice), perToken, 1e18)
        );
        // And preview matches the exact pool formula (single-rounding).
        (, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 0);
        assertEq(yldOut, Math.mulDiv(RAW_STAKE, wrapper.poolYieldRaw(), wrapper.yieldSupply()));
    }

    // ─── Unwrap rules (equal-leg) ─────────────────────────────────────────────

    function test_unwrap_zeroAmount_reverts() public {
        _wrap(alice, RAW_STAKE);
        _applyYieldDelta(DOUBLE, 1 hours);

        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        wrapper.unwrap(0, 0);
    }

    function test_unwrap_revertsForHolderOfSingleLeg() public {
        _wrap(alice, RAW_STAKE);
        _applyYieldDelta(DOUBLE, 1 hours);

        vm.startPrank(alice);
        _yield(0).transfer(bob, 40 ether);
        vm.stopPrank();

        // Alice can unwrap only her paired 60 + 60.
        vm.prank(alice);
        wrapper.unwrap(60 ether, 0);

        // Bob holds only the yield leg: burning the capital leg reverts.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 40 ether)
        );
        wrapper.unwrap(40 ether, 0);

        // And a zero amount is rejected up front.
        vm.prank(bob);
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        wrapper.unwrap(0, 0);
    }

    function test_unwrap_partial_preservesPerTokenValues() public {
        _wrap(alice, RAW_STAKE);
        _applyYieldDelta(DOUBLE, 1 hours);

        vm.prank(alice);
        wrapper.unwrap(40 ether, 0);

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(60 ether, 0);
        assertEq(capOut, 30 ether);
        assertEq(yldOut, 30 ether);

        // Remaining holders keep per-token values: capital 0.5 raw, yield 0.5 raw.
        assertEq(wrapper.capitalRawValue(1 ether), HALF);
        assertEq(wrapper.yieldPerTokenRaw(), HALF);
        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE + 40 ether);

        // Equal-leg burn preserves rawLocked == capitalSupply == yieldSupply.
        assertEq(wrapper.rawLocked(), 60 ether);
        assertEq(wrapper.capitalSupply(), 60 ether);
        assertEq(wrapper.yieldSupply(), 60 ether);
        assertEq(_capital(0).balanceOf(alice), 60 ether);
        assertEq(_yield(0).balanceOf(alice), 60 ether);
    }

    // ─── Lock rules (solo unwraps, nonce-gated) ───────────────────────────────

    function test_wrap_lockZero_pairAtCurrentNonce() public {
        _wrapLocked(alice, RAW_STAKE, 0); // nonce 0 → pair 0
        assertEq(wrapper.pairCount(), 1);
        assertEq(wrapper.pairNonceAt(0), 0);
        assertEq(_capital(0).balanceOf(alice), RAW_STAKE);
    }

    function test_wrap_lockCount_setsUnlockNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // nonce 0 → pair 2
        assertEq(wrapper.pairCount(), 1);
        assertEq(wrapper.pairNonceAt(0), 2);
        assertEq(_capital(2).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(2).balanceOf(alice), RAW_STAKE);
    }

    function test_wrap_lockCount_afterDividends_countsFutureOnly() public {
        _wrapLocked(alice, RAW_STAKE, 1); // nonce 0 → pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // nonce → 1: alice's lock is satisfied
        _wrapLocked(bob, RAW_STAKE, 1); // nonce 1 → pair 2

        assertEq(wrapper.pairNonceAt(0), 1);
        assertEq(wrapper.pairNonceAt(1), 2);
        assertEq(_yield(1).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(2).balanceOf(bob), RAW_STAKE);
    }

    function test_unwrapYield_blockedBeforeNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce → 1 < 2

        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapYield(RAW_STAKE, 2);
    }

    function test_unwrapYield_allowedAtNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2, nonce 0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce → 1
        _setYieldFactor(DOUBLE, 1 hours); // Y=2 (absolute), nonce → 2 → unlocked

        uint256 aliceBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 2);

        // Y=2: yield per token = 0.5 raw → 50 raw out; capital untouched.
        assertEq(underlying.balanceOf(alice), aliceBefore + 50 ether);
        assertEq(wrapper.rawLocked(), 50 ether);
        assertEq(wrapper.capitalSupply(), RAW_STAKE);
        assertEq(wrapper.yieldSupply(), 0);
    }

    function test_unwrapCapital_blockedBeforeNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2
        _applyYieldDelta(DOUBLE, 1 hours); // nonce → 1 < 2

        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapCapital(RAW_STAKE, 2);
    }

    function test_unwrapCapital_allowedAtNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2, nonce 0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce → 1
        _setYieldFactor(DOUBLE, 1 hours); // Y=2 (absolute), nonce → 2 → unlocked

        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 2);

        // Y=2: capital per token = 0.5 raw → 50 raw out; yield untouched.
        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE + 50 ether);
        assertEq(wrapper.rawLocked(), 50 ether);
        assertEq(wrapper.capitalSupply(), 0);
        assertEq(wrapper.yieldSupply(), RAW_STAKE);
    }

    function test_equalLeg_unwrap_anytime_evenWhileLocked() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2
        _applyYieldDelta(DOUBLE, 1 hours); // nonce → 1, still locked

        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 2); // equal-leg: exact regardless of lock

        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(wrapper.rawLocked(), 0);
        assertEq(wrapper.capitalSupply(), 0);
        assertEq(wrapper.yieldSupply(), 0);
    }

    function test_pendingDividend_doesNotConsumeLock() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1, nonce 0

        // Dividend announced for +1 day (pending: nonce still 0).
        vm.prank(owner);
        underlying.setUIScalingFactor(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapYield(RAW_STAKE, 1);

        // Short lock: expires as soon as the pending dividend lands.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1);
        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE + 50 ether);
    }

    function test_delayedDividend_lockCapturesLateDividend() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1: locked until the 1st dividend lands

        // Dividend announced for +2 days...
        vm.prank(owner);
        underlying.setUIScalingFactor(UIScalingClass.Yield, 15e17, block.timestamp + 2 days);
        // ...and delayed to +4 days (pending popped and re-pushed).
        vm.prank(owner);
        underlying.setUIScalingFactor(UIScalingClass.Yield, 15e17, block.timestamp + 4 days);

        vm.warp(block.timestamp + 2 days); // old "expiry" date passes — still locked, still entitled
        assertEq(wrapper.currentNonce(), 0);
        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapYield(RAW_STAKE, 1);

        vm.warp(block.timestamp + 2 days); // dividend finally lands
        assertEq(wrapper.currentNonce(), 1);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1);

        // Y=1.5: yield per token = 1/3 raw → 33.333...e18 raw out.
        assertEq(underlying.balanceOf(alice), 9900 ether + 33333333333333333334);
    }

    function test_yieldPerToken_uniformAcrossPairs() public {
        _wrap(bob, RAW_STAKE); // pair 0
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce → 1

        (uint256 c0, uint256 y0) = wrapper.previewUnwrap(RAW_STAKE, 0);
        (uint256 c1, uint256 y1) = wrapper.previewUnwrap(RAW_STAKE, 1);
        assertEq(c0, c1); // capital uniform (1/Y)
        assertEq(y0, y1); // yield uniform across expiries
        assertEq(y0, RAW_STAKE / 2);
    }

    function test_invariant_afterSoloUnwraps() public {
        _wrap(bob, RAW_STAKE); // pair 0
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce → 1
        _applyYieldDelta(15e17, 1 hours); // Y=3, nonce → 2

        vm.prank(bob);
        wrapper.unwrapYield(50 ether, 0); // solo yield (nonce 2 >= 0)
        vm.prank(alice);
        wrapper.unwrapCapital(40 ether, 1); // solo capital (nonce 2 >= 1)

        // Invariant: rawLocked == C/Y + YS×(1−1/Y) at Y=3 (1-2 wei rounding drift).
        uint256 Y = 3e18;
        uint256 rhs = Math.mulDiv(wrapper.capitalSupply(), 1e18, Y)
            + Math.mulDiv(wrapper.yieldSupply(), Y - 1e18, Y);
        assertApproxEqAbs(wrapper.rawLocked(), rhs, 2);

        // Per-token yield remains uniform = 1 − 1/Y.
        assertApproxEqAbs(wrapper.yieldPerTokenRaw(), Math.mulDiv(Y - 1e18, 1e18, Y), 2);
    }

    function test_unwrapYield_revertsForUnknownPair() public {
        _wrap(alice, RAW_STAKE); // pair 0
        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.unwrapYield(RAW_STAKE, 1); // never-created pair
    }

    function test_preview_revertsForUnknownPair() public {
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.previewUnwrap(RAW_STAKE, 5);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.previewUnwrapYield(RAW_STAKE, 5);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.previewUnwrapCapital(RAW_STAKE, 5);
    }

    // ─── Supply class is display-only ─────────────────────────────────────────

    function test_unwrap_supplySplit_doesNotChangeSplit() public {
        _wrap(alice, RAW_STAKE);
        _applySupplyDelta(DOUBLE, 1 hours); // 2-for-1 split

        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE);
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 0);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);

        // Display: capital UI doubles with the split.
        assertEq(wrapper.previewCapitalUI(RAW_STAKE), 2 * RAW_STAKE);
    }

    function test_unwrap_supplyThenYield_orderIndependent() public {
        _wrap(alice, RAW_STAKE);
        _applySupplyDelta(DOUBLE, 1 hours);
        _applyYieldDelta(DOUBLE, 1 hours);

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 0);
        assertEq(capOut, RAW_STAKE / 2);
        assertEq(yldOut, RAW_STAKE / 2);
    }

    // ─── Factor markdowns ─────────────────────────────────────────────────────

    function test_factorDrop_neverLocksOrPenalizes() public {
        _wrap(alice, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(8e17, 1 hours); // maintainer marks Yield down to 0.8x, nonce → 1

        // Supply display is untouched (Yield-class event); redemption is floored at 1:1 raw.
        assertEq(wrapper.previewCapitalUI(RAW_STAKE), RAW_STAKE);
        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE);
        assertEq(wrapper.poolYieldRaw(), 0);
        assertEq(wrapper.yieldPerTokenRaw(), 0);

        // Full pair still redeems exactly the stake — no lock, no penalty.
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(underlying.balanceOf(address(wrapper)), 0);

        // Wrapping remains open after the markdown (pair 1: nonce is 1).
        _wrap(bob, HALF);
        assertEq(_capital(1).balanceOf(bob), HALF);
        assertEq(_yield(1).balanceOf(bob), HALF);
    }

    function test_factorDrop_afterGrowth_absorbsIntoYield() public {
        _wrap(alice, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(DOUBLE, 1 hours); // dividend to ×2, nonce → 1
        _applyYieldDelta(4e17, 1 hours); // markdown ×0.4 → Y = 0.8 < 1, nonce → 2

        // Capital floor keeps redemption at 1:1; the ×2 dividend is unwound.
        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE);
        assertEq(wrapper.poolYieldRaw(), 0);

        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
    }

    function test_markdown_soloYieldPaysZero() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // nonce → 1 → unlocked
        _applyYieldDelta(4e17, 1 hours); // markdown → Y = 0.8, nonce → 2

        assertEq(wrapper.poolYieldRaw(), 0);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1); // pays 0: the markdown was absorbed

        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE);
        assertEq(wrapper.rawLocked(), RAW_STAKE);
    }

    // ─── Conservation ─────────────────────────────────────────────────────────

    function test_conservation_afterMixedUnwraps() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2.0, nonce → 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=2.0

        vm.prank(bob);
        wrapper.unwrap(60 ether, 0);

        assertEq(wrapper.rawLocked(), 140 ether);
        assertEq(wrapper.capitalSupply(), 140 ether);
        assertEq(wrapper.yieldSupply(), 140 ether);

        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1);

        assertEq(wrapper.rawLocked(), 40 ether);
        assertEq(underlying.balanceOf(address(wrapper)), 40 ether);
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    function test_events_emitted() public {
        vm.expectEmit(true, true, false, false, address(wrapper));
        emit ScaledPairWrapper.Wrapped(alice, RAW_STAKE, 0);
        vm.prank(alice);
        wrapper.wrap(RAW_STAKE, 0);

        _applyYieldDelta(DOUBLE, 1 hours);

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit ScaledPairWrapper.Unwrapped(alice, 0, RAW_STAKE, RAW_STAKE / 2, RAW_STAKE / 2);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);
    }

    function test_events_soloUnwraps() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce → 1 → unlocked

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit ScaledPairWrapper.UnwrapYield(alice, 1, RAW_STAKE, 50 ether);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1);

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit ScaledPairWrapper.UnwrapCapital(alice, 1, RAW_STAKE, 50 ether);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 1);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-contract ScaledPairWrapperTest`
Expected: FAIL — compile errors: `wrap`/`unwrap` argument count mismatch, `capital`/`yield` members no longer exist on the wrapper, `pairs` not found.

- [ ] **Step 3: Implement the wrapper (full replacement)**

Replace the entire contents of `src/ScaledPairWrapper.sol` with:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IScaledUIAmountClasses} from "./interfaces/IScaledUIAmountClasses.sol";
import {UIScalingClass} from "./interfaces/UIScalingClass.sol";
import {UIScalingMath} from "./libraries/UIScalingMath.sol";
import {CapitalToken} from "./tokens/CapitalToken.sol";
import {YieldToken} from "./tokens/YieldToken.sol";

/**
 * @title ScaledPairWrapper
 * @notice Event-based expiry wrapper: splits raw RWA into Capital / Yield ERC-20
 *         pairs, one pair per unlock nonce (yield event). Locks are measured in
 *         dividends, not time, so delayed dividends never expire.
 *
 *   wrap(raw, lockNonces) → unlockNonce = yieldNonce() + lockNonces; mints `raw`
 *   Capital + `raw` Yield of the pair unlocking at unlockNonce (1:1 raw).
 *
 *   capital claim (raw) = capitalSupply / max(yieldFactor, 1.0)   → 1 Capital token = 1 Yield-UI unit
 *   yield pool  (raw)   = rawLocked − capital claim               → 1 Yield token = pool / yieldSupply
 *
 *   Global invariant preserved by every operation:
 *     rawLocked = capitalSupply / Y + yieldSupply × (1 − 1/Y),  Y = max(yieldFactor, 1.0)
 *   ⇒ per-token yield value = 1 − 1/Y is uniform across ALL expiry pairs, and
 *     equal-leg unwrap of any pair redeems exactly `amount` raw at any time.
 *
 *   Redemption rules:
 *     - unwrap(amount, n)          — burn both legs of pair n, ANYTIME, exact raw.
 *     - unwrapYield(amount, n)     — solo yield leg, only when yieldNonce() >= n.
 *     - unwrapCapital(amount, n)   — solo capital leg, only when yieldNonce() >= n.
 *   Raw stays pooled while locks are outstanding, so pair unwraps always have liquidity.
 *
 *   The nonce lives in the ERC-8056 extension (effective Yield checkpoints);
 *   this contract only reads it via `yieldNonce()`.
 */
contract ScaledPairWrapper {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error InsolventPool();
    error Locked();
    error PairNotFound();

    struct Pair {
        CapitalToken capital;
        YieldToken yield;
    }

    IERC20 public immutable underlying;
    IScaledUIAmountClasses public immutable scaledUnderlying;
    string public assetName;
    string public assetSymbol;

    uint256 public rawLocked;

    /// @dev One Capital/Yield pair per unlock nonce; created lazily on first wrap.
    mapping(uint256 => Pair) public pairs;
    uint256[] internal _pairNonces;

    event Wrapped(address indexed user, uint256 rawAmount, uint256 unlockNonce);
    event Unwrapped(
        address indexed user,
        uint256 unlockNonce,
        uint256 amount,
        uint256 capitalRawOut,
        uint256 yieldLegRawOut
    );
    event UnwrapYield(address indexed user, uint256 unlockNonce, uint256 amount, uint256 rawOut);
    event UnwrapCapital(address indexed user, uint256 unlockNonce, uint256 amount, uint256 rawOut);

    constructor(
        IERC20 underlying_,
        IScaledUIAmountClasses scaledUnderlying_,
        string memory assetName_,
        string memory assetSymbol_
    ) {
        underlying = underlying_;
        scaledUnderlying = scaledUnderlying_;
        assetName = assetName_;
        assetSymbol = assetSymbol_;
    }

    // ─── Wrap ──────────────────────────────────────────────────────────────

    /// @notice Lock `rawAmount` underlying and mint 1:1 Capital + Yield of the pair
    ///         unlocking at `yieldNonce() + lockNonces`.
    /// @dev `lockNonces = 0` allows immediate solo redemption (pair of the current nonce).
    function wrap(uint256 rawAmount, uint256 lockNonces) external returns (uint256 unlockNonce) {
        if (rawAmount == 0) revert InvalidAmount();

        unlockNonce = scaledUnderlying.yieldNonce() + lockNonces;
        Pair storage pair = pairs[unlockNonce];
        if (address(pair.capital) == address(0)) {
            string memory suffix = Strings.toString(unlockNonce);
            pair.capital = new CapitalToken(
                string.concat("Capital-", suffix),
                string.concat("Cap", suffix),
                address(this)
            );
            pair.yield = new YieldToken(
                string.concat("Yield-", suffix),
                string.concat("Yld", suffix),
                address(this)
            );
            _pairNonces.push(unlockNonce);
        }

        underlying.safeTransferFrom(msg.sender, address(this), rawAmount);
        rawLocked += rawAmount;
        pair.capital.mint(msg.sender, rawAmount);
        pair.yield.mint(msg.sender, rawAmount);

        emit Wrapped(msg.sender, rawAmount, unlockNonce);
    }

    // ─── Unwrap (equal-leg, anytime) ───────────────────────────────────────

    /// @notice Burn `amount` of BOTH legs of the pair unlocking at `unlockNonce`.
    /// @dev Always allowed — the base guarantee. Exact: amount/Y + amount×(1−1/Y) = amount.
    function unwrap(uint256 amount, uint256 unlockNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(unlockNonce);

        (uint256 capitalRawOut, uint256 yieldLegRawOut) = _previewUnwrap(pair, amount);

        pair.capital.burn(msg.sender, amount);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= capitalRawOut + yieldLegRawOut;

        underlying.safeTransfer(msg.sender, capitalRawOut + yieldLegRawOut);

        emit Unwrapped(msg.sender, unlockNonce, amount, capitalRawOut, yieldLegRawOut);
    }

    // ─── Unwrap (solo legs, nonce-gated) ───────────────────────────────────

    /// @notice Burn `amount` yield tokens of pair `unlockNonce` and receive raw —
    ///         only after `yieldNonce() >= unlockNonce`.
    function unwrapYield(uint256 amount, uint256 unlockNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(unlockNonce);
        if (scaledUnderlying.yieldNonce() < unlockNonce) revert Locked();
        uint256 supply = yieldSupply();
        if (supply == 0) revert InsolventPool();

        uint256 rawOut = Math.mulDiv(amount, poolYieldRaw(), supply);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapYield(msg.sender, unlockNonce, amount, rawOut);
    }

    /// @notice Burn `amount` capital tokens of pair `unlockNonce` and receive raw —
    ///         only after `yieldNonce() >= unlockNonce`.
    function unwrapCapital(uint256 amount, uint256 unlockNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(unlockNonce);
        if (scaledUnderlying.yieldNonce() < unlockNonce) revert Locked();

        uint256 rawOut = capitalRawValue(amount);
        pair.capital.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapCapital(msg.sender, unlockNonce, amount, rawOut);
    }

    // ─── Views ─────────────────────────────────────────────────────────────

    /// @dev Current yield nonce (effective dividend count) — delegated to the extension.
    function currentNonce() public view returns (uint256) {
        return scaledUnderlying.yieldNonce();
    }

    function pairCount() public view returns (uint256) {
        return _pairNonces.length;
    }

    function pairNonceAt(uint256 index) public view returns (uint256) {
        return _pairNonces[index];
    }

    /// @dev Total capital supply across all pairs.
    function capitalSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairNonces.length; i++) {
            total += pairs[_pairNonces[i]].capital.totalSupply();
        }
        return total;
    }

    /// @dev Total yield supply across all pairs.
    function yieldSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairNonces.length; i++) {
            total += pairs[_pairNonces[i]].yield.totalSupply();
        }
        return total;
    }

    function capitalSupplyOf(uint256 unlockNonce) public view returns (uint256) {
        Pair storage pair = pairs[unlockNonce];
        return address(pair.capital) == address(0) ? 0 : pair.capital.totalSupply();
    }

    function yieldSupplyOf(uint256 unlockNonce) public view returns (uint256) {
        Pair storage pair = pairs[unlockNonce];
        return address(pair.yield) == address(0) ? 0 : pair.yield.totalSupply();
    }

    /// @dev Raw value of `capitalAmount` capital tokens at the current Yield factor.
    ///      Uniform across all pairs; 1 token = 1/Y raw while Y >= 1 (floored at 1:1 below).
    function capitalRawValue(uint256 capitalAmount) public view returns (uint256) {
        return Math.mulDiv(
            capitalAmount,
            UIScalingMath.MULTIPLIER_DECIMALS,
            _yieldFactorFloored()
        );
    }

    /// @dev Raw units currently attributable to the yield pool (0 when Y < 1).
    function poolYieldRaw() public view returns (uint256) {
        uint256 capitalClaim = Math.mulDiv(
            capitalSupply(),
            UIScalingMath.MULTIPLIER_DECIMALS,
            _yieldFactorFloored()
        );
        if (capitalClaim > rawLocked) revert InsolventPool();
        return rawLocked - capitalClaim;
    }

    /// @dev Raw value of one yield token (18-decimal fixed point) — uniform across ALL pairs.
    function yieldPerTokenRaw() public view returns (uint256) {
        uint256 supply = yieldSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(poolYieldRaw(), UIScalingMath.MULTIPLIER_DECIMALS, supply);
    }

    /// @notice Preview underlying returned for burning `amount` of both paired receipts of pair `unlockNonce`.
    function previewUnwrap(uint256 amount, uint256 unlockNonce)
        public
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        Pair storage pair = _requirePair(unlockNonce);
        return _previewUnwrap(pair, amount);
    }

    /// @notice Preview solo yield redemption of `amount` yield tokens of pair `unlockNonce`.
    function previewUnwrapYield(uint256 amount, uint256 unlockNonce) public view returns (uint256) {
        _requirePair(unlockNonce);
        uint256 supply = yieldSupply();
        if (supply == 0) revert InsolventPool();
        return Math.mulDiv(amount, poolYieldRaw(), supply);
    }

    /// @notice Preview solo capital redemption of `amount` capital tokens of pair `unlockNonce`.
    function previewUnwrapCapital(uint256 amount, uint256 unlockNonce) public view returns (uint256) {
        _requirePair(unlockNonce);
        return capitalRawValue(amount);
    }

    /// @dev Composite-UI display of `capitalAmount` capital tokens. Supply events (splits)
    ///      scale the display only; the raw claim `capitalRawValue` is untouched.
    function previewCapitalUI(uint256 capitalAmount) public view returns (uint256) {
        uint256 supplyFactorNow = scaledUnderlying.uiScalingFactor(UIScalingClass.Supply);
        return Math.mulDiv(capitalAmount, supplyFactorNow, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    // ─── Internals ─────────────────────────────────────────────────────────

    function _previewUnwrap(Pair storage pair, uint256 amount)
        internal
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        uint256 supply = pair.yield.totalSupply();
        if (supply == 0 && amount > 0) revert InsolventPool();
        capitalRawOut = capitalRawValue(amount);
        yieldLegRawOut = supply == 0 ? 0 : Math.mulDiv(amount, poolYieldRaw(), yieldSupply());
    }

    function _requirePair(uint256 unlockNonce) internal view returns (Pair storage pair) {
        pair = pairs[unlockNonce];
        if (address(pair.capital) == address(0)) revert PairNotFound();
    }

    /// @dev Yield factor floored at 1.0: the capital claim `1/Y` never exceeds 1:1 raw,
    ///      so factor markdowns (Y < 1) shrink the yield pool to zero instead of
    ///      freezing the pool or penalizing holders.
    function _yieldFactorFloored() internal view returns (uint256) {
        return Math.max(
            scaledUnderlying.uiScalingFactor(UIScalingClass.Yield),
            UIScalingMath.MULTIPLIER_DECIMALS
        );
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `forge test`
Expected: PASS — all 52 extension/library tests (43 existing + 9 new nonce tests) plus the 40 wrapper tests (92 total).

- [ ] **Step 5: Commit**

```bash
git add src/ScaledPairWrapper.sol test/ScaledPairWrapper.t.sol
git commit -m "feat: per-expiry token pairs with nonce-gated locks"
```

---

## Self-Review

**Spec coverage:**
- Yield nonce on extension, effective-time only, pending excluded, Supply excluded → Task 1 (tests: `test_yieldNonce_ticksOnlyWhenEffective`, `test_yieldNonce_supplyUpdatesDoNotTick`, `test_yieldNonce_reschedule_keepsSingleEvent`).
- Per-wrap lock choice, per-expiry pairs, lazily created, Capital-N/Yield-N naming → Task 2 (`test_wrap_lockCount_setsUnlockNonce`, `test_pairTokens_createdLazilyOnFirstWrap`).
- Shared pool, uniform per-token yield across pairs → Task 2 (`test_yieldPerToken_uniformAcrossPairs`, `test_yieldTokens_fungibleUniformValue`).
- Equal-leg anytime exact; solo gated by nonce (`Locked`) → Task 2 (`test_equalLeg_unwrap_anytime_evenWhileLocked`, `test_unwrapYield_blockedBeforeNonce`, `test_unwrapCapital_blockedBeforeNonce`, `test_unwrapYield_allowedAtNonce`, `test_unwrapCapital_allowedAtNonce`).
- Delayed-dividend scenario → Task 2 (`test_delayedDividend_lockCapturesLateDividend`, `test_pendingDividend_doesNotConsumeLock`).
- Invariant preserved under solo unwraps → Task 2 (`test_invariant_afterSoloUnwraps`).
- Markdown floor with solo paths → Task 2 (`test_markdown_soloYieldPaysZero`).
- Views/events/errors (`Locked`, `PairNotFound`, `InvalidAmount`, `InsolventPool`) → Task 2 (`test_preview_revertsForUnknownPair`, `test_unwrapYield_revertsForUnknownPair`, `test_events_emitted`, `test_events_soloUnwraps`).
- Pre-existing 43 tests untouched and passing → Task 1 keeps them; Task 2 only replaces the wrapper test file.

**Placeholder scan:** No TBD/TODO; all steps contain complete code and exact commands.

**Type consistency:** `yieldNonce()` (Task 1) consumed by wrapper in Task 2 as `scaledUnderlying.yieldNonce()`; `wrap(rawAmount, lockNonces)` returns `unlockNonce`; `previewUnwrap(amount, unlockNonce)` returns `(capitalRawOut, yieldLegRawOut)` — used consistently in tests. `pairs(uint256)` getter returns `Pair { CapitalToken capital; YieldToken yield; }`, accessed as `wrapper.pairs(n).capital` in the test helpers.
