# Frozen-Delta Pricing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current-multiplier pool pricing in `ScaledPairWrapper` with frozen-delta (window coupon) pricing keyed by `(startNonce, targetNonce)`, then prove it with unit, fuzz, and invariant tests.

**Architecture:** Pairs become `(start, target)` windows. Yield claims are frozen at `1 - Y_start/Y_target` (from the extension's append-only checkpoint history — the current multiplier is never read). Equal-leg unwrap pays exactly `amount` anytime; solo legs are gated by `yieldNonce() >= target` and pay the frozen coupon/share. A single shared raw vault remains solvent by construction (coupon + share = 1 per unit).

**Tech Stack:** Solidity 0.8.24, Foundry (forge test), OpenZeppelin (Math, SafeERC20, Strings), forge-std.

**User overrides:** NO intermediate commits. All tasks run without committing; the final task makes ONE commit and pushes to `origin main`.

## Global Constraints

- Coupon per token: `max(1 - Y_start/Y_target, 0)` in 1e18 fixed point = `(yT - yS) * 1e18 / yT` when `yT > yS`, else `0`. `Y_start` = `yieldEventAt(start).multiplier`, `Y_target` = `yieldEventAt(target).multiplier`.
- Capital share per token: `1e18 - coupon` (hence `min(Y_start/Y_target, 1)`); coupon + share always sum to `1e18`.
- Gates: `unwrapYield` / `unwrapCapital` revert `Locked()` while `yieldNonce() < target`. `unwrap` (equal-leg) allowed ANYTIME, pays exactly `amount`.
- Pair tokens: `Capital-<start>-<target>` / `Yield-<start>-<target>`, symbols `Cap<start>-<target>` / `Yld<start>-<target>` (lazy creation, fungible within identical windows).
- Errors: `InvalidAmount`, `PairNotFound`, `Locked` (wrapper); `EventNotEffective`/`EventNotRecorded` bubble from the extension. `InsolventPool` is REMOVED.
- Vault accounting: `rawLocked` is the single bookkeeping counter; `underlying.balanceOf(address(wrapper)) == rawLocked` always. Solo-leg rounding leaves at most 1 wei dust per pair; invariant assertions allow `pairCount()` wei of dust.
- Floor: `yT <= yS` (including markdowns below 1e18) -> coupon 0, capital pays full. Mid-window multiplier moves price nothing.
- `lockNonces = 0` -> pair `(N, N)`: coupon 0, capital full, equal-leg still exact 1:1.

---

### Task 1: Rewrite the wrapper unit test suite for the new API

**Files:**
- Create (full replacement): `test/ScaledPairWrapper.t.sol`

**Interfaces:**
- Consumes: the NEW wrapper API (does not exist yet — tests must fail to compile until Task 2):
  - `wrap(uint256 rawAmount, uint256 lockNonces) external returns (uint256 startNonce, uint256 targetNonce)`
  - `unwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)`
  - `unwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce)`
  - `unwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce)`
  - `currentNonce()`, `pairCount()`, `pairAt(uint256) returns (uint256 start, uint256 target)`
  - `pairs(uint256 start, uint256 target) returns (Pair memory)` with `.capital` / `.yield`
  - `capitalSupply()`, `yieldSupply()`, `capitalSupplyOf(s,t)`, `yieldSupplyOf(s,t)`
  - `couponOf(uint256 start, uint256 target)` (1e18 fixed point; reverts `EventNotEffective` before target)
  - `capitalShareOf(uint256 start, uint256 target)` = `1e18 - couponOf`
  - `previewUnwrap(amount, s, t) returns (uint256 capitalRawOut, uint256 yieldLegRawOut)` — split `(amount*share/1e18, amount - that)` when target effective, else `(amount, 0)`
  - `previewUnwrapYield(amount, s, t)`, `previewUnwrapCapital(amount, s, t)` (revert `EventNotEffective` before target)
  - `previewCapitalUI(uint256)` unchanged
  - `rawLocked`, `underlying`, `scaledUnderlying` public
  - Errors: `InvalidAmount`, `PairNotFound`, `Locked`
- Consumes extension: `ScaledUIClassedToken` (constructor `(name, symbol, owner)`; `mint(to, amount)` owner-only; `applyUIScalingDelta(class, delta, ts)`; `setUIScalingFactor(class, factor, ts)`; `yieldNonce()`; `yieldEventAt(nonce)`).

- [ ] **Step 1: Write the failing test file**

Replace `test/ScaledPairWrapper.t.sol` entirely with:

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

        for (uint256 i = 0; i < 3; i++) {
            address user = i == 0 ? alice : (i == 1 ? bob : carol);
            vm.startPrank(user);
            underlying.approve(address(wrapper), type(uint256).max);
            vm.stopPrank();
        }
    }

    //==============================================================================//
    // Helpers                                                                      //
    //==============================================================================//
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

    /// @dev A yield event that does not change the multiplier (advances the nonce only).
    function _advanceNonce(uint256 delay) internal {
        _applyYieldDelta(NEUTRAL, delay);
    }

    function _wrap(address user, uint256 amount) internal returns (uint256 start, uint256 target) {
        vm.prank(user);
        (start, target) = wrapper.wrap(amount, 0);
    }

    function _wrapLocked(address user, uint256 amount, uint256 lockNonces)
        internal
        returns (uint256 start, uint256 target)
    {
        vm.prank(user);
        (start, target) = wrapper.wrap(amount, lockNonces);
    }

    function _capital(uint256 start, uint256 target) internal view returns (CapitalToken) {
        return CapitalToken(address(wrapper.pairs(start, target).capital));
    }

    function _yield(uint256 start, uint256 target) internal view returns (YieldToken) {
        return YieldToken(address(wrapper.pairs(start, target).yield));
    }

    function _assertPairExact(address user, uint256 start, uint256 target, uint256 expected)
        internal
        view
    {
        uint256 capBal = _capital(start, target).balanceOf(user);
        uint256 yldBal = _yield(start, target).balanceOf(user);
        assertEq(capBal, yldBal); // full pairs only - equal-leg invariant
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(capBal, start, target);
        assertEq(capOut + yldOut, expected);
    }

    //==============================================================================//
    // Pair tokens                                                                  //
    //==============================================================================//
    function test_pairTokens_createdLazily_withWindowNames() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3)
        assertEq(start, 1);
        assertEq(target, 3);

        assertEq(_capital(1, 3).name(), "Capital-1-3");
        assertEq(_capital(1, 3).symbol(), "Cap1-3");
        assertEq(_yield(1, 3).name(), "Yield-1-3");
        assertEq(_yield(1, 3).symbol(), "Yld1-3");

        // re-wrap into the same window merges fungibly (same token addresses)
        (uint256 s2, uint256 t2) = _wrapLocked(bob, RAW_STAKE, 2);
        assertEq(s2, 1);
        assertEq(t2, 3);
        assertEq(address(_capital(1, 3)), address(_capital(s2, t2)));
        assertEq(_capital(1, 3).balanceOf(bob), RAW_STAKE);
    }

    function test_pairTokens_distinctWindowsDistinctTokens() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _setYieldFactor(3e18, 1 days); // nonce 3, Y = 3x

        _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3)
        _advanceNonce(1 days); // nonce 4
        _wrapLocked(bob, RAW_STAKE, 2); // pair (4,6)

        assertTrue(address(_capital(1, 3)) != address(_capital(4, 6)));
        assertTrue(address(_yield(1, 3)) != address(_yield(4, 6)));
        assertEq(wrapper.pairCount(), 2);
    }

    function test_pairEnumeration_pairCountAndPairAt() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1)
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(bob, RAW_STAKE, 2); // pair (1,3)

        assertEq(wrapper.pairCount(), 2);
        (uint256 s0, uint256 t0) = wrapper.pairAt(0);
        (uint256 s1, uint256 t1) = wrapper.pairAt(1);
        assertEq(s0, 0);
        assertEq(t0, 1);
        assertEq(s1, 1);
        assertEq(t1, 3);
    }

    //==============================================================================//
    // Wrap                                                                          //
    //==============================================================================//
    function test_wrap_mintsOneToOne() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        assertEq(_capital(start, target).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(start, target).balanceOf(alice), RAW_STAKE);
        assertEq(wrapper.rawLocked(), RAW_STAKE);
        assertEq(underlying.balanceOf(address(wrapper)), RAW_STAKE);
    }

    function test_wrap_capturesStartNonce() public {
        _advanceNonce(1 days); // nonce 1
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 5);
        assertEq(start, wrapper.currentNonce());
        assertEq(start, 1);
        assertEq(target, 6);
    }

    function test_wrap_lockZero_pairAtCurrentNonce() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 0);
        assertEq(start, 1);
        assertEq(target, 1);
        // degenerate window: coupon 0, capital full
        assertEq(wrapper.couponOf(1, 1), 0);
        assertEq(wrapper.capitalShareOf(1, 1), NEUTRAL);
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 1, 1);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);
    }

    function test_wrap_zeroAmount_reverts() public {
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.wrap(0, 1);
    }

    function test_unknownPair_operationsRevert() public {
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.unwrap(1, 0, 1);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.unwrapYield(1, 0, 1);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.unwrapCapital(1, 0, 1);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.previewUnwrap(1, 0, 1);
        vm.expectRevert(ScaledPairWrapper.PairNotFound.selector);
        wrapper.couponOf(0, 1);
    }

    //==============================================================================//
    // Delta pricing                                                                //
    //==============================================================================//
    function test_coupon_positiveDelta() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        assertEq(wrapper.couponOf(1, 2), 5e17); // 1 - 1/2
        assertEq(wrapper.capitalShareOf(1, 2), 5e17);
    }

    function test_coupon_zeroWhenNoDelta() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _advanceNonce(1 days); // nonce 2, Y unchanged
        assertEq(wrapper.couponOf(1, 2), 0);
        assertEq(wrapper.capitalShareOf(1, 2), NEUTRAL);
    }

    function test_coupon_zeroOnMarkdown_principalProtected() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _setYieldFactor(HALF, 1 days); // nonce 2, Y = 0.5x < 1x
        assertEq(wrapper.couponOf(1, 2), 0);
        assertEq(wrapper.capitalShareOf(1, 2), NEUTRAL);
        uint256 rawOut = wrapper.previewUnwrapCapital(RAW_STAKE, 1, 2);
        assertEq(rawOut, RAW_STAKE); // full principal
    }

    function test_coupon_usesAbsoluteFactors_notDeltas() public {
        // Y goes 1x -> 2x -> 1.5x over three events; window (1,3): coupon = 1 - 1/1.5
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _setYieldFactor(15e17, 1 days); // nonce 3, Y = 1.5x
        assertEq(wrapper.couponOf(1, 3), 333333333333333333); // 1 - 1/1.5
        assertEq(wrapper.capitalShareOf(1, 3), 666666666666666667);
    }

    //==============================================================================//
    // Equal-leg unwrap                                                             //
    //==============================================================================//
    function test_unwrap_equalLeg_anytimeExact() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        // BEFORE expiry: exact refund, even though the split is undefined
        uint256 before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, start, target);
        assertEq(underlying.balanceOf(alice) - before, RAW_STAKE);
        assertEq(wrapper.rawLocked(), 0);

        // AFTER expiry: same exact total
        (uint256 s2, uint256 t2) = _wrapLocked(bob, RAW_STAKE, 1);
        _applyYieldDelta(DOUBLE, 1 days); // nonce 1, Y = 2x
        uint256 before2 = underlying.balanceOf(bob);
        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, s2, t2);
        assertEq(underlying.balanceOf(bob) - before2, RAW_STAKE);
    }

    function test_unwrap_equalLeg_paysSplitAtExpiry() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 1, 2);
        assertEq(capOut, 50 ether);
        assertEq(yldOut, 50 ether);

        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1, 2);
        assertEq(underlying.balanceOf(alice), 10_000 ether); // deposited 100, received 100 back
        assertEq(wrapper.rawLocked(), 0);
    }

    function test_unwrap_partialAmount() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE / 4, start, target);
        assertEq(_capital(start, target).balanceOf(alice), 75 ether);
        assertEq(_yield(start, target).balanceOf(alice), 75 ether);
        assertEq(wrapper.rawLocked(), 75 ether);
    }

    //==============================================================================//
    // Solo legs (nonce-gated, frozen)                                              //
    //==============================================================================//
    function test_unwrapYield_gated_beforeTarget() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, start, target);
        _advanceNonce(1 days); // nonce 1, still < target
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, start, target);
    }

    function test_unwrapCapital_gated_beforeTarget() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, start, target);
    }

    function test_unwrapYield_paysFrozenCoupon() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        uint256 before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1, 2);
        assertEq(underlying.balanceOf(alice) - before, 50 ether);
        assertEq(_yield(1, 2).balanceOf(alice), 0);
        assertEq(_capital(1, 2).balanceOf(alice), RAW_STAKE);
        assertEq(wrapper.rawLocked(), 50 ether);
    }

    function test_unwrapCapital_paysFrozenShare() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        uint256 before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 1, 2);
        assertEq(underlying.balanceOf(alice) - before, 50 ether);
        assertEq(_capital(1, 2).balanceOf(alice), 0);
        assertEq(_yield(1, 2).balanceOf(alice), RAW_STAKE);
        assertEq(wrapper.rawLocked(), 50 ether);
    }

    function test_soloLegs_sequence_totalsExactly() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1, 2);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 1, 2);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(wrapper.rawLocked(), 0);
    }

    function test_soloLegs_partial_roundingDust() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        // odd amount with coupon 0.5: floor(33 * 5e17 / 1e18) = 16 per leg
        uint256 amount = 33;
        vm.prank(alice);
        wrapper.unwrapYield(amount, 1, 2); // pays 16
        vm.prank(alice);
        wrapper.unwrapCapital(amount, 1, 2); // pays 16
        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE + 32);
        assertEq(wrapper.rawLocked(), RAW_STAKE - 32);
    }

    //==============================================================================//
    // Frozen claims (the x5 scenario)                                              //
    //==============================================================================//
    function test_frozen_atExpiry_laterMultipliersDoNotChangeClaims() public {
        // Bob wraps 100 at nonce 1 (Y=1x), locked to nonce 3 where Y lands at 2x.
        _advanceNonce(1 days); // nonce 1, Y = 1x
        (uint256 start, uint256 target) = _wrapLocked(bob, RAW_STAKE, 2); // (1,3)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x -> target reached
        assertEq(wrapper.couponOf(1, 3), 5e17);
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 1, 3);
        assertEq(capOut, 50 ether);
        assertEq(yldOut, 50 ether);

        // Nonce 5: multiplier lands at 5x. Claims MUST NOT change.
        _advanceNonce(1 days); // nonce 4, Y = 2x
        _setYieldFactor(5e18, 1 days); // nonce 5, Y = 5x
        assertEq(wrapper.couponOf(1, 3), 5e17, "yield frozen at expiry");
        assertEq(wrapper.capitalShareOf(1, 3), 5e17, "capital frozen at expiry");
        (uint256 capOut2, uint256 yldOut2) = wrapper.previewUnwrap(RAW_STAKE, 1, 3);
        assertEq(capOut2, 50 ether);
        assertEq(yldOut2, 50 ether);

        // Unwrapping months later pays the frozen split.
        uint256 before = underlying.balanceOf(bob);
        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, 1, 3);
        assertEq(underlying.balanceOf(bob) - before, RAW_STAKE);
    }

    function test_frozen_laterDividendsOnlyAffectLaterPairs() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x
        _wrapLocked(bob, RAW_STAKE, 2); // pair (3,5)
        _advanceNonce(1 days); // nonce 4, Y = 2x
        _setYieldFactor(5e18, 1 days); // nonce 5, Y = 5x
        assertEq(wrapper.couponOf(3, 5), 1e18 - 2e18 * 1e18 / 5e18); // 1 - 2/5 = 0.6
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, 3, 5);
        assertEq(capOut, 40 ether);
        assertEq(yldOut, 60 ether);
    }

    function test_frozen_historicalIndependence() public {
        // Same pair redeems identically at expiry and after more dividends.
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        uint256 yldAtExpiry = wrapper.previewUnwrapYield(RAW_STAKE, 1, 2);
        assertEq(yldAtExpiry, 50 ether);
        _applyYieldDelta(DOUBLE, 1 days); // nonce 3, Y = 4x
        _setYieldFactor(10e18, 1 days); // nonce 4, Y = 10x
        assertEq(wrapper.previewUnwrapYield(RAW_STAKE, 1, 2), yldAtExpiry);
        assertEq(wrapper.previewUnwrapCapital(RAW_STAKE, 1, 2), 50 ether);
    }

    //==============================================================================//
    // Pending dividends                                                            //
    //==============================================================================//
    function test_pendingDividend_doesNotAffectPricing() public {
        _advanceNonce(1 days); // nonce 1
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        // schedule but do NOT warp past it
        vm.prank(owner);
        underlying.applyUIScalingDelta(UIScalingClass.Yield, DOUBLE, block.timestamp + 10 days);
        assertEq(wrapper.currentNonce(), 1, "pending does not tick the nonce");
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, start, target);
        vm.warp(block.timestamp + 10 days); // dividend lands -> nonce 2, Y = 2x
        assertEq(wrapper.currentNonce(), 2);
        assertEq(wrapper.couponOf(1, 2), 5e17, "landed dividend prices the window");
    }

    function test_pendingDividend_insideWindow_countsOnLanding() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3)
        vm.prank(owner);
        underlying.applyUIScalingDelta(UIScalingClass.Yield, DOUBLE, block.timestamp + 5 days);
        vm.warp(block.timestamp + 5 days); // lands before target: nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x
        assertEq(wrapper.couponOf(1, 3), 5e17);
    }

    //==============================================================================//
    // Preview & display                                                            //
    //==============================================================================//
    function test_previewUnwrap_beforeExpiry_returnsFullToCapital() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);
    }

    function test_previewSolo_revertsBeforeEffective() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        vm.expectRevert(bytes4(keccak256("EventNotEffective()")));
        wrapper.previewUnwrapYield(RAW_STAKE, start, target);
        vm.expectRevert(bytes4(keccak256("EventNotEffective()")));
        wrapper.previewUnwrapCapital(RAW_STAKE, start, target);
    }

    function test_previewCapitalUI_supplyDisplayOnly() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        assertEq(wrapper.previewCapitalUI(RAW_STAKE), RAW_STAKE);
        _applySupplyDelta(DOUBLE, 1 days); // 2-for-1 split: display doubles
        assertEq(wrapper.previewCapitalUI(RAW_STAKE), 2 * RAW_STAKE);
        assertEq(wrapper.previewUnwrapCapital(RAW_STAKE, 1, 2), 50 ether, "raw claim unchanged");
    }

    //==============================================================================//
    // Supplies                                                                     //
    //==============================================================================//
    function test_supplies_globalAndPerPair() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2), 100 + 100
        _advanceNonce(1 days); // nonce 2
        _wrapLocked(bob, 2 * RAW_STAKE, 1); // pair (2,3), 200 + 200
        assertEq(wrapper.capitalSupply(), 300 ether);
        assertEq(wrapper.yieldSupply(), 300 ether);
        assertEq(wrapper.capitalSupplyOf(1, 2), RAW_STAKE);
        assertEq(wrapper.yieldSupplyOf(1, 2), RAW_STAKE);
        assertEq(wrapper.capitalSupplyOf(2, 3), 2 * RAW_STAKE);
        assertEq(wrapper.capitalSupplyOf(9, 9), 0, "unknown pair -> 0");
    }

    //==============================================================================//
    // Conservation                                                                 //
    //==============================================================================//
    function test_conservation_fullDrain() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1)
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(bob, RAW_STAKE, 2); // pair (1,3)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3
        _wrapLocked(carol, RAW_STAKE, 1); // pair (3,4)
        _setYieldFactor(5e18, 1 days); // nonce 4, Y = 5x

        // everyone unwraps equal-leg
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0, 1);
        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, 1, 3);
        vm.prank(carol);
        wrapper.unwrap(RAW_STAKE, 3, 4);

        assertEq(underlying.balanceOf(address(wrapper)), 0);
        assertEq(wrapper.rawLocked(), 0);
    }

    function test_conservation_mixedRedemptions() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        // solo yield 60 -> 30 raw; then equal-leg 40 -> 40 raw; then solo capital 60 -> 30 raw
        vm.prank(alice);
        wrapper.unwrapYield(60 ether, 1, 2);
        vm.prank(alice);
        wrapper.unwrap(40 ether, 1, 2);
        vm.prank(alice);
        wrapper.unwrapCapital(60 ether, 1, 2);

        assertEq(underlying.balanceOf(alice), 10_000 ether); // 100 in, 100 out
        assertEq(wrapper.rawLocked(), 0);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
    }

    function test_conservation_multiUser_sharingWindow() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _wrapLocked(bob, RAW_STAKE, 1); // same window
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1, 2); // 50
        vm.prank(bob);
        wrapper.unwrapCapital(RAW_STAKE, 1, 2); // 50

        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE + 50 ether);
        assertEq(underlying.balanceOf(bob), 10_000 ether - RAW_STAKE + 50 ether);
        assertEq(wrapper.rawLocked(), 100 ether); // both capital(50) + yield(50) remain
        assertEq(underlying.balanceOf(address(wrapper)), 100 ether);
    }

    //==============================================================================//
    // Events                                                                       //
    //==============================================================================//
    function test_events_wrappedAndUnwrapped() public {
        _advanceNonce(1 days); // nonce 1
        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ScaledPairWrapper.Wrapped(alice, RAW_STAKE, 1, 3);
        vm.prank(alice);
        wrapper.wrap(RAW_STAKE, 2);

        _applyYieldDelta(DOUBLE, 1 days); // nonce 2
        _advanceNonce(1 days); // nonce 3, Y = 2x
        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ScaledPairWrapper.Unwrapped(alice, 1, 3, RAW_STAKE, 50 ether, 50 ether);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1, 3);
    }

    function test_events_unwrapYieldAndCapital() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ScaledPairWrapper.UnwrapYield(alice, 1, 2, RAW_STAKE, 50 ether);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1, 2);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ScaledPairWrapper.UnwrapCapital(alice, 1, 2, RAW_STAKE, 50 ether);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 1, 2);
    }

    function test_zeroAmount_reverts_everywhere() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.unwrap(0, 1, 2);
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.unwrapYield(0, 1, 2);
        vm.expectRevert(ScaledPairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.unwrapCapital(0, 1, 2);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `forge test --match-contract ScaledPairWrapperTest 2>&1 | tail -6`
Expected: `Error: Compilation failed` — member `pairs` not found / wrong arg counts (old wrapper API still in `src/ScaledPairWrapper.sol`).

---

### Task 2: Implement the frozen-delta wrapper

**Files:**
- Modify (full replacement): `src/ScaledPairWrapper.sol`

**Interfaces:**
- Consumes: `IScaledUIAmountClasses.yieldNonce()`, `.yieldEventAt(nonce)` (existing), `UIScalingClass.Supply` / `.Yield`, `UIScalingMath.MULTIPLIER_DECIMALS`, `CapitalToken`/`YieldToken` `(name, symbol, minter)` constructors.
- Produces: the API consumed by Task 1 tests (see Task 1 "Interfaces" block).

- [ ] **Step 1: Write the implementation**

Replace `src/ScaledPairWrapper.sol` entirely with:

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
 * @notice Window-coupon wrapper: splits raw RWA into Capital / Yield ERC-20 pairs,
 *         one pair per (startNonce, targetNonce) yield-event window.
 *
 *   wrap(raw, lockNonces) at current nonce N -> pair (N, N + lockNonces); mints
 *   `raw` Capital + `raw` Yield of that window (1:1 raw).
 *
 *   Claims are FROZEN at the target nonce, from historical checkpoints only:
 *     Y_s = yieldEventAt(start).multiplier   Y_t = yieldEventAt(target).multiplier
 *     yield coupon per token = max(1 - Y_s/Y_t, 0)   (0 when Y_t <= Y_s: principal protected)
 *     capital share per token = 1 - coupon
 *   The current multiplier is NEVER read; later dividends price nothing for a
 *   pair whose window has ended, so unwrapping months later pays the same split.
 *
 *   Redemption rules:
 *     - unwrap(amount, s, t)       — burn both legs, receive exactly `amount`, ANYTIME.
 *     - unwrapYield(amount, s, t)  — solo yield leg, only when yieldNonce() >= t.
 *     - unwrapCapital(amount, s, t)— solo capital leg, only when yieldNonce() >= t.
 *
 *   coupon + share = 1, so every pair's total claim equals its deposit and the
 *   shared vault stays solvent by construction.
 */
contract ScaledPairWrapper {
    using SafeERC20 for IERC20;

    error InvalidAmount();
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

    /// @dev One Capital/Yield pair per (start, target) window; created lazily.
    mapping(uint256 => mapping(uint256 => Pair)) internal _pairs;
    uint256[] internal _pairStarts;
    uint256[] internal _pairTargets;

    event Wrapped(address indexed user, uint256 rawAmount, uint256 startNonce, uint256 targetNonce);
    event Unwrapped(
        address indexed user,
        uint256 startNonce,
        uint256 targetNonce,
        uint256 amount,
        uint256 capitalRawOut,
        uint256 yieldLegRawOut
    );
    event UnwrapYield(address indexed user, uint256 startNonce, uint256 targetNonce, uint256 amount, uint256 rawOut);
    event UnwrapCapital(
        address indexed user,
        uint256 startNonce,
        uint256 targetNonce,
        uint256 amount,
        uint256 rawOut
    );

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

    // ------------------------------------------------------------------
    // Wrap
    // ------------------------------------------------------------------
    /// @notice Lock `rawAmount` underlying into the window (currentNonce, currentNonce + lockNonces).
    /// @dev `lockNonces = 0` creates a degenerate window with coupon 0 (capital = full).
    function wrap(uint256 rawAmount, uint256 lockNonces) external returns (uint256 startNonce, uint256 targetNonce) {
        if (rawAmount == 0) revert InvalidAmount();

        startNonce = scaledUnderlying.yieldNonce();
        targetNonce = startNonce + lockNonces;

        Pair storage pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) {
            string memory suffix = string.concat(
                Strings.toString(startNonce),
                "-",
                Strings.toString(targetNonce)
            );
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
            _pairStarts.push(startNonce);
            _pairTargets.push(targetNonce);
        }

        underlying.safeTransferFrom(msg.sender, address(this), rawAmount);
        rawLocked += rawAmount;
        pair.capital.mint(msg.sender, rawAmount);
        pair.yield.mint(msg.sender, rawAmount);

        emit Wrapped(msg.sender, rawAmount, startNonce, targetNonce);
    }

    // ------------------------------------------------------------------
    // Unwrap (equal-leg, anytime, exact)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` of BOTH legs of window (start, target); receive exactly `amount`.
    /// @dev The leg split in the event follows the frozen shares once the target is
    ///      effective; before that the whole amount is reported as capital.
    function unwrap(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(startNonce, targetNonce);

        (uint256 capitalRawOut, uint256 yieldLegRawOut) = _previewUnwrap(pair, amount, startNonce, targetNonce);

        pair.capital.burn(msg.sender, amount);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= amount;

        underlying.safeTransfer(msg.sender, amount);

        emit Unwrapped(msg.sender, startNonce, targetNonce, amount, capitalRawOut, yieldLegRawOut);
    }

    // ------------------------------------------------------------------
    // Unwrap (solo legs, nonce-gated, frozen payouts)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` yield tokens of window (start, target) for `amount * coupon` raw.
    /// @dev Only after `yieldNonce() >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(startNonce, targetNonce);
        if (scaledUnderlying.yieldNonce() < targetNonce) revert Locked();

        uint256 coupon = _couponOf(startNonce, targetNonce);
        uint256 rawOut = Math.mulDiv(amount, coupon, UIScalingMath.MULTIPLIER_DECIMALS);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapYield(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    /// @notice Burn `amount` capital tokens of window (start, target) for `amount * (1 - coupon)` raw.
    /// @dev Only after `yieldNonce() >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(startNonce, targetNonce);
        if (scaledUnderlying.yieldNonce() < targetNonce) revert Locked();

        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        uint256 rawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
        pair.capital.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapCapital(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    /// @dev Current yield nonce (effective dividend count) — delegated to the extension.
    function currentNonce() public view returns (uint256) {
        return scaledUnderlying.yieldNonce();
    }

    function pairCount() public view returns (uint256) {
        return _pairStarts.length;
    }

    function pairAt(uint256 index) public view returns (uint256 start, uint256 target) {
        return (_pairStarts[index], _pairTargets[index]);
    }

    /// @dev Pair whose tokens unlock at window (start, target); zero addresses if never created.
    function pairs(uint256 startNonce, uint256 targetNonce) public view returns (Pair memory) {
        return _pairs[startNonce][targetNonce];
    }

    /// @dev Total capital supply across all windows.
    function capitalSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].capital.totalSupply();
        }
        return total;
    }

    /// @dev Total yield supply across all windows.
    function yieldSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].yield.totalSupply();
        }
        return total;
    }

    function capitalSupplyOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        Pair storage pair = _pairs[startNonce][targetNonce];
        return address(pair.capital) == address(0) ? 0 : pair.capital.totalSupply();
    }

    function yieldSupplyOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        Pair storage pair = _pairs[startNonce][targetNonce];
        return address(pair.yield) == address(0) ? 0 : pair.yield.totalSupply();
    }

    /// @dev Frozen yield coupon of window (start, target): max(1 - Y_s/Y_t, 0), 1e18 fixed point.
    ///      Reverts EventNotEffective before the target nonce is effective.
    function couponOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        _requirePair(startNonce, targetNonce);
        return _couponOf(startNonce, targetNonce);
    }

    /// @dev Frozen capital share of window (start, target): 1e18 - coupon.
    function capitalShareOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        return UIScalingMath.MULTIPLIER_DECIMALS - couponOf(startNonce, targetNonce);
    }

    /// @notice Preview underlying returned for burning `amount` of both legs of window (start, target).
    /// @dev Returns (amount, 0) before the target is effective (split undefined); the total is
    ///      always exactly `amount`.
    function previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        Pair storage pair = _requirePair(startNonce, targetNonce);
        return _previewUnwrap(pair, amount, startNonce, targetNonce);
    }

    /// @notice Preview solo yield redemption of `amount` yield tokens of window (start, target).
    /// @dev Reverts EventNotEffective before the target is effective.
    function previewUnwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        returns (uint256)
    {
        _requirePair(startNonce, targetNonce);
        return Math.mulDiv(amount, _couponOf(startNonce, targetNonce), UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @notice Preview solo capital redemption of `amount` capital tokens of window (start, target).
    /// @dev Reverts EventNotEffective before the target is effective.
    function previewUnwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        returns (uint256)
    {
        _requirePair(startNonce, targetNonce);
        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        return Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @dev Composite-UI display of `capitalAmount` capital tokens. Supply events (splits)
    ///      scale the display only; the raw claim is untouched.
    function previewCapitalUI(uint256 capitalAmount) public view returns (uint256) {
        uint256 supplyFactorNow = scaledUnderlying.uiScalingFactor(UIScalingClass.Supply);
        return Math.mulDiv(capitalAmount, supplyFactorNow, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------
    function _couponOf(uint256 startNonce, uint256 targetNonce) internal view returns (uint256) {
        uint256 yStart = scaledUnderlying.yieldEventAt(startNonce).multiplier;
        uint256 yTarget = scaledUnderlying.yieldEventAt(targetNonce).multiplier;
        if (yTarget <= yStart) return 0;
        return Math.mulDiv(
            yTarget - yStart,
            UIScalingMath.MULTIPLIER_DECIMALS,
            yTarget
        );
    }

    function _previewUnwrap(Pair storage pair, uint256 amount, uint256 startNonce, uint256 targetNonce)
        internal
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        if (scaledUnderlying.yieldNonce() >= targetNonce) {
            uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
            capitalRawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
            yieldLegRawOut = amount - capitalRawOut;
        } else {
            capitalRawOut = amount;
            yieldLegRawOut = 0;
        }
    }

    function _requirePair(uint256 startNonce, uint256 targetNonce) internal view returns (Pair storage pair) {
        pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) revert PairNotFound();
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `forge test --match-contract ScaledPairWrapperTest`
Expected: PASS for the whole `ScaledPairWrapperTest` suite. If a test fails, check the failing assert against the frozen-delta math in Global Constraints (esp. `test_unwrap_equalLeg_paysSplitAtExpiry` balance accounting and `test_soloLegs_partial_roundingDust` tolerance).

---

### Task 3: Fuzz tests

**Files:**
- Create: `test/ScaledPairWrapperFuzz.t.sol`

**Interfaces:**
- Consumes: everything from Task 2 (same wrapper API as Task 1).

- [ ] **Step 1: Write the failing test file**

Create `test/ScaledPairWrapperFuzz.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ScaledPairWrapper} from "../src/ScaledPairWrapper.sol";
import {ScaledUIClassedToken} from "../src/ScaledUIClassedToken.sol";
import {UIScalingClass} from "../src/interfaces/UIScalingClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ScaledPairWrapperFuzzTest is ScalingTestBase {
    ScaledUIClassedToken internal underlying;
    ScaledPairWrapper internal wrapper;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        underlying = new ScaledUIClassedToken("Stock", "STK", owner);
        wrapper = new ScaledPairWrapper(IERC20(address(underlying)), underlying, "Tesla", "Tesla");
        vm.prank(owner);
        underlying.mint(alice, type(uint96).max);
        vm.startPrank(alice);
        underlying.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    function _setYieldFactor(uint256 factor, uint256 delay) internal {
        vm.prank(owner);
        underlying.setUIScalingFactor(UIScalingClass.Yield, factor, block.timestamp + delay);
        vm.warp(block.timestamp + delay);
    }

    /// @dev coupon formula in isolation: (yT - yS)*1e18/yT when yT > yS, else 0.
    function _coupon(uint256 yStart, uint256 yTarget) internal pure returns (uint256) {
        return yTarget > yStart ? Math.mulDiv(yTarget - yStart, 1e18, yTarget) : 0;
    }

    function testFuzz_couponAndShareSumToUnit(uint256 yStart, uint256 yTarget) public pure {
        yStart = bound(yStart, 1e18, 1e36);
        yTarget = bound(yTarget, 1e18, 1e36);
        uint256 coupon = _coupon(yStart, yTarget);
        uint256 share = 1e18 - coupon;
        assertEq(coupon + share, 1e18);
        assertLe(coupon, 1e18);
        assertLe(share, 1e18);
    }

    function testFuzz_coupon_zeroWhenFlatOrFalling(uint256 yStart, uint256 yTarget) public pure {
        yStart = bound(yStart, 1e18, 1e36);
        yTarget = bound(yTarget, 1e18, yStart);
        assertEq(_coupon(yStart, yTarget), 0, "falling/flat window has zero coupon");
    }

    function testFuzz_previewUnwrap_splitSumsToAmount(uint256 amount, uint256 yStart, uint256 yTarget) public {
        amount = bound(amount, 1, 100_000 ether);
        yStart = bound(yStart, 1e18, 10e18);
        yTarget = bound(yTarget, 1e18, 10e18);

        _setYieldFactor(yStart, 1 days); // nonce 1: Y = yStart
        (uint256 start, uint256 target) = wrapper.wrap(amount, 1); // pair (1,2)
        _setYieldFactor(yTarget, 1 days); // nonce 2: Y = yTarget

        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(amount, start, target);
        assertEq(capOut + yldOut, amount, "equal-leg split always sums to amount");

        // capital leg is computed exactly from the frozen share
        uint256 coupon = _coupon(yStart, yTarget);
        assertEq(capOut, Math.mulDiv(amount, 1e18 - coupon, 1e18));
    }

    function testFuzz_soloPayouts_matchFrozenCoupon(uint256 amount, uint256 yStart, uint256 yTarget) public {
        amount = bound(amount, 1, 100_000 ether);
        yStart = bound(yStart, 1e18, 10e18);
        yTarget = bound(yTarget, 1e18, 10e18);

        _setYieldFactor(yStart, 1 days); // nonce 1
        (uint256 start, uint256 target) = wrapper.wrap(amount, 1);
        _setYieldFactor(yTarget, 1 days); // nonce 2

        uint256 coupon = _coupon(yStart, yTarget);
        uint256 before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapYield(amount, start, target);
        assertEq(underlying.balanceOf(alice) - before, Math.mulDiv(amount, coupon, 1e18));

        before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapCapital(amount, start, target);
        assertEq(underlying.balanceOf(alice) - before, Math.mulDiv(amount, 1e18 - coupon, 1e18));

        // at most 1 wei of dust stays in the vault (floor rounding on both legs)
        assertLe(underlying.balanceOf(address(wrapper)), 1);
    }

    function testFuzz_equalLegExact_anytime(uint256 amount, uint256 lockNonces, uint256 dividends) public {
        amount = bound(amount, 1, 100_000 ether);
        lockNonces = bound(lockNonces, 1, 5);
        dividends = bound(dividends, 0, 4);

        (uint256 start, uint256 target) = wrapper.wrap(amount, lockNonces);

        // random dividend events BEFORE unwrap
        for (uint256 i = 0; i < dividends; i++) {
            vm.prank(owner);
            underlying.applyUIScalingDelta(
                UIScalingClass.Yield,
                bound(uint256(keccak256(abi.encode(i))), 5e17, 2e18),
                block.timestamp + 1 days
            );
            vm.warp(block.timestamp + 1 days);
        }

        uint256 before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrap(amount, start, target);
        assertEq(underlying.balanceOf(alice) - before, amount, "equal-leg exact at any time");
    }

    function testFuzz_laterDividends_doNotChangeClaims(uint256 amount, uint256 laterEvents) public {
        amount = bound(amount, 1, 100_000 ether);
        laterEvents = bound(laterEvents, 1, 4);

        _setYieldFactor(2e18, 1 days); // nonce 1: Y = 2x
        (uint256 start, uint256 target) = wrapper.wrap(amount, 1); // pair (1,2)
        _setYieldFactor(3e18, 1 days); // nonce 2: Y = 3x -> frozen

        (uint256 capAtExpiry, uint256 yldAtExpiry) = wrapper.previewUnwrap(amount, start, target);
        uint256 yldSoloAtExpiry = wrapper.previewUnwrapYield(amount, start, target);

        for (uint256 i = 0; i < laterEvents; i++) {
            _setYieldFactor(bound(uint256(keccak256(abi.encode("later", i))), 3e18, 50e18), 1 days);
        }

        (uint256 capNow, uint256 yldNow) = wrapper.previewUnwrap(amount, start, target);
        assertEq(capNow, capAtExpiry, "capital frozen");
        assertEq(yldNow, yldAtExpiry, "yield frozen");
        assertEq(wrapper.previewUnwrapYield(amount, start, target), yldSoloAtExpiry, "solo frozen");
    }

    function testFuzz_roundTrip_singleWindow(uint256 amount, uint256 lockNonces) public {
        amount = bound(amount, 1, 100_000 ether);
        lockNonces = bound(lockNonces, 0, 5);

        (uint256 start, uint256 target) = wrapper.wrap(amount, lockNonces);
        vm.prank(alice);
        wrapper.unwrap(amount, start, target);
        assertEq(underlying.balanceOf(alice), type(uint96).max, "full round trip");
        assertEq(wrapper.rawLocked(), 0);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
    }
}
```

- [ ] **Step 2: Run the fuzz tests**

Run: `forge test --match-contract ScaledPairWrapperFuzzTest`
Expected: PASS (suite header shows the fuzz cases ran; `testFuzz_*` auto-fuzz 256 runs each).

---

### Task 4: Invariant tests

**Files:**
- Create: `test/ScaledPairWrapperHandler.sol`
- Create: `test/ScaledPairWrapperInvariant.t.sol`

**Interfaces:**
- Consumes: full Task 2 wrapper API; `ScaledUIClassedToken.mint` (owner-only); `applyUIScalingDelta`.
- Produces: `ScaledPairWrapperHandler` (targeted by `targetContract`) with ghosts `totalDeposited`, `totalRedeemed`; invariant suite contract `ScaledPairWrapperInvariantTest`.

- [ ] **Step 1: Write the handler**

Create `test/ScaledPairWrapperHandler.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ScaledPairWrapper} from "../src/ScaledPairWrapper.sol";
import {ScaledUIClassedToken} from "../src/ScaledUIClassedToken.sol";
import {UIScalingClass} from "../src/interfaces/UIScalingClass.sol";

/// @dev Action handler for the wrapper invariant suite. Every entrypoint either
///      performs an operation or reverts; asserts inside handlers fail the suite.
contract ScaledPairWrapperHandler is Test {
    ScaledUIClassedToken public immutable underlying;
    ScaledPairWrapper public immutable wrapper;
    address public immutable owner;

    uint256 public totalDeposited;
    uint256 public totalRedeemed;

    constructor(ScaledUIClassedToken underlying_, ScaledPairWrapper wrapper_, address owner_) {
        underlying = underlying_;
        wrapper = wrapper_;
        owner = owner_;
    }

    function _actor(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("actor", seed % 8)))));
    }

    function _randomPair(uint256 seed) internal view returns (uint256 start, uint256 target, bool exists) {
        uint256 count = wrapper.pairCount();
        if (count == 0) return (0, 0, false);
        (start, target) = wrapper.pairAt(bound(seed, 0, count - 1));
        exists = true;
    }

    function wrap(uint256 seed, uint256 amountSeed, uint256 lockSeed) external {
        address actor = _actor(seed);
        uint256 amount = bound(amountSeed, 1, 10_000 ether);
        uint256 lockNonces = bound(lockSeed, 0, 6);

        vm.prank(owner);
        underlying.mint(actor, amount);
        vm.startPrank(actor);
        underlying.approve(address(wrapper), type(uint256).max);
        wrapper.wrap(amount, lockNonces);
        vm.stopPrank();

        totalDeposited += amount;
    }

    function unwrap(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 capBal = wrapper.pairs(start, target).capital.balanceOf(actor);
        uint256 yldBal = wrapper.pairs(start, target).yield.balanceOf(actor);
        uint256 maxAmount = capBal < yldBal ? capBal : yldBal;
        if (maxAmount == 0) return;
        uint256 amount = bound(amountSeed, 1, maxAmount);

        uint256 before = underlying.balanceOf(actor);
        vm.prank(actor);
        wrapper.unwrap(amount, start, target);
        assertEq(underlying.balanceOf(actor) - before, amount, "equal-leg pays exactly amount");
        totalRedeemed += amount;
    }

    function unwrapYield(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 yldBal = wrapper.pairs(start, target).yield.balanceOf(actor);
        if (yldBal == 0) return;
        uint256 amount = bound(amountSeed, 1, yldBal);

        if (wrapper.currentNonce() < target) {
            vm.expectRevert(ScaledPairWrapper.Locked.selector);
            vm.prank(actor);
            wrapper.unwrapYield(amount, start, target);
            return;
        }
        uint256 expected = Math.mulDiv(amount, wrapper.couponOf(start, target), 1e18);
        uint256 before = underlying.balanceOf(actor);
        vm.prank(actor);
        wrapper.unwrapYield(amount, start, target);
        assertEq(underlying.balanceOf(actor) - before, expected, "yield pays frozen coupon");
        totalRedeemed += expected;
    }

    function unwrapCapital(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 capBal = wrapper.pairs(start, target).capital.balanceOf(actor);
        if (capBal == 0) return;
        uint256 amount = bound(amountSeed, 1, capBal);

        if (wrapper.currentNonce() < target) {
            vm.expectRevert(ScaledPairWrapper.Locked.selector);
            vm.prank(actor);
            wrapper.unwrapCapital(amount, start, target);
            return;
        }
        uint256 share = 1e18 - wrapper.couponOf(start, target);
        uint256 expected = Math.mulDiv(amount, share, 1e18);
        uint256 before = underlying.balanceOf(actor);
        vm.prank(actor);
        wrapper.unwrapCapital(amount, start, target);
        assertEq(underlying.balanceOf(actor) - before, expected, "capital pays frozen share");
        totalRedeemed += expected;
    }

    function applyYieldDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        vm.prank(owner);
        underlying.applyUIScalingDelta(UIScalingClass.Yield, delta, block.timestamp + delay);
        vm.warp(block.timestamp + delay);
    }
}
```

- [ ] **Step 2: Write the invariant test contract**

Create `test/ScaledPairWrapperInvariant.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ScaledPairWrapper} from "../src/ScaledPairWrapper.sol";
import {ScaledPairWrapperHandler} from "./ScaledPairWrapperHandler.sol";
import {ScaledUIClassedToken} from "../src/ScaledUIClassedToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ScaledPairWrapperInvariantTest is ScalingTestBase {
    ScaledUIClassedToken internal underlying;
    ScaledPairWrapper internal wrapper;
    ScaledPairWrapperHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        underlying = new ScaledUIClassedToken("Stock", "STK", owner);
        wrapper = new ScaledPairWrapper(IERC20(address(underlying)), underlying, "Tesla", "Tesla");
        handler = new ScaledPairWrapperHandler(underlying, wrapper, owner);
        targetContract(address(handler));
    }

    /// @dev Upper bound of all outstanding claims. Effective pairs use the frozen
    ///      coupon; unexpired pairs claim at most one raw per unit (coupon in [0, 1e18]).
    function _totalClaims() internal view returns (uint256) {
        uint256 claims;
        uint256 count = wrapper.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = wrapper.pairAt(i);
            uint256 capSupply = wrapper.capitalSupplyOf(start, target);
            uint256 yldSupply = wrapper.yieldSupplyOf(start, target);
            if (wrapper.currentNonce() >= target) {
                uint256 coupon = wrapper.couponOf(start, target);
                claims += Math.mulDiv(yldSupply, coupon, 1e18);
                claims += Math.mulDiv(capSupply, 1e18 - coupon, 1e18);
            } else {
                claims += capSupply > yldSupply ? capSupply : yldSupply;
            }
        }
        return claims;
    }

    function invariant_solvency_claimsNeverExceedPool() public view {
        assertLe(_totalClaims(), wrapper.rawLocked(), "claims exceed pool");
    }

    function invariant_bookkeeping_balanceEqualsRawLocked() public view {
        assertEq(underlying.balanceOf(address(wrapper)), wrapper.rawLocked(), "balance != rawLocked");
    }

    function invariant_ghosts_noClaimsBeyondDeposits() public view {
        uint256 dust = wrapper.pairCount() * 8; // <=1 wei dust per claimer per pair; handler has 8 actors
        assertLe(_totalClaims() + dust, handler.totalDeposited() - handler.totalRedeemed(), "ghost drift");
    }

    function invariant_coupon_matchesHistory() public view {
        uint256 count = wrapper.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = wrapper.pairAt(i);
            if (wrapper.currentNonce() < target) continue;
            uint256 yStart = underlying.yieldEventAt(start).multiplier;
            uint256 yTarget = underlying.yieldEventAt(target).multiplier;
            uint256 expected = yTarget > yStart ? Math.mulDiv(yTarget - yStart, 1e18, yTarget) : 0;
            assertEq(wrapper.couponOf(start, target), expected, "coupon drifted from history");
        }
    }

    function invariant_noStuckRaw() public view {
        // Fully unwrapped pairs leave at most 1 wei of dust per claimer (handler: 8 actors).
        assertLe(wrapper.rawLocked() - _totalClaims(), wrapper.pairCount() * 8, "unclaimed raw exceeds dust");
    }
}
```

- [ ] **Step 3: Run the invariant suite**

Run: `forge test --match-contract ScaledPairWrapperInvariantTest -vvv`
Expected: PASS — 5 invariant properties hold across the default 256 runs x 100 calls. If a property fails, run `forge test --match-contract ScaledPairWrapperInvariantTest -vvvv` and inspect the failing sequence (invariant tests print the call trace leading to the failure).

---

### Task 5: Full verification, single commit, push

**Files:** none (verification only).

- [ ] **Step 1: Run the entire suite**

Run: `forge test`
Expected: all suites pass — `ScaledUIClassedTokenTest` (36), `ScaledPairWrapperTest` (~36 new), `ScaledPairWrapperFuzzTest` (6 fuzz cases), `ScaledPairWrapperInvariantTest` (5 invariants), `ScaledUITokenTest`, `UIScalingMathTest` (unchanged).

- [ ] **Step 2: Commit (single commit — user override, no per-task commits)**

```bash
git add src/ScaledPairWrapper.sol test/ScaledPairWrapper.t.sol test/ScaledPairWrapperFuzz.t.sol test/ScaledPairWrapperHandler.sol test/ScaledPairWrapperInvariant.t.sol
git commit -m "feat: frozen-delta window pricing with fuzz and invariant tests"
```

- [ ] **Step 3: Push**

Run: `git push origin main`
Expected: `main` updated on `origin` (fast-forward from `fb17bfb`).