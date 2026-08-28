// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056CompositePairWrapper} from "../src/token-side/ERC8056CompositePairWrapper.sol";
import {IERC8056PairWrapper} from "../src/interfaces/wrapper/IERC8056PairWrapper.sol";
import {LegToken} from "../src/wrapper/LegToken.sol";
import {ERC8056Composite} from "../src/ERC8056Composite.sol";
import {IERC8056Composite} from "../src/interfaces/extension/IERC8056Composite.sol";
import {MultiplierClass} from "../src/interfaces/extension/IERC8056MultiplierClass.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8056} from "../src/ERC8056.sol";

/// @dev Port of the standalone wrapper suite (test/ERC8056PairWrapper.t.sol) to the
///      token-side variant, where the ERC-8056 composite token IS the pair wrapper
///      (one contract = stock token + composite + Capital/Yield factory).
///
///      Dropped on purpose — structurally impossible in this variant:
///      - Fee-on-transfer tests (inbound FoT + late outbound-fee transition): wrap
///        and unwrap are internal `_update` ledger moves; the token cannot fee on
///        its own balance changes, so there is no FoT surface at all.
///      - Custom-decimals passthrough and bare-metadata fallback: the token always
///        has 18 decimals and full ERC-20 metadata (name/symbol/decimals).
///      - Registry tests: there is no ERC8056PairWrapperRegistry; discovery is a
///        single `supportsInterface` call on the token itself.
contract ERC8056CompositePairWrapperTest is ScalingTestBase {
    ERC8056CompositePairWrapper internal token;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new ERC8056CompositePairWrapper("Stock", "STK", owner);

        vm.prank(owner);
        token.mint(alice, 10_000 ether);
        vm.prank(owner);
        token.mint(bob, 10_000 ether);
        vm.prank(owner);
        token.mint(carol, 10_000 ether);

        // No approvals: wrap SELF-ESCROWS via an internal ledger update.
    }

    //==============================================================================//
    // Helpers                                                                      //
    //==============================================================================//
    function _applyYieldDelta(uint256 delta, uint256 delay) internal {
        uint256 current = token.uiScalingFactor(MultiplierClass.Yield);
        uint256 newMultiplier = (current * delta) / 1e18;
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function _applySupplyDelta(uint256 delta, uint256 delay) internal {
        uint256 current = token.uiScalingFactor(MultiplierClass.Supply);
        uint256 newMultiplier = (current * delta) / 1e18;
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function _setYieldFactor(uint256 factor, uint256 delay) internal {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, factor, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    /// @dev A yield event that does not change the multiplier (advances the nonce only).
    function _advanceNonce(uint256 delay) internal {
        _applyYieldDelta(NEUTRAL, delay);
    }

    function _wrap(address user, uint256 amount) internal returns (uint256 start, uint256 target) {
        vm.prank(user);
        (start, target) = token.wrap(amount, 0);
    }

    function _wrapLocked(address user, uint256 amount, uint256 lockNonces)
        internal
        returns (uint256 start, uint256 target)
    {
        vm.prank(user);
        (start, target) = token.wrap(amount, lockNonces);
    }

    function _capital(uint256 start, uint256 target) internal view returns (LegToken) {
        return LegToken(address(token.pairs(start, target).capital));
    }

    function _yield(uint256 start, uint256 target) internal view returns (LegToken) {
        return LegToken(address(token.pairs(start, target).yield));
    }

    function _assertPairExact(address user, uint256 start, uint256 target, uint256 expected) internal view {
        uint256 capBal = _capital(start, target).balanceOf(user);
        uint256 yldBal = _yield(start, target).balanceOf(user);
        assertEq(capBal, yldBal); // full pairs only - equal-leg invariant
        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(capBal, start, target);
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
        assertEq(token.pairCount(), 2);
    }

    function test_pairEnumeration_pairCountAndPairAt() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1)
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(bob, RAW_STAKE, 2); // pair (1,3)

        assertEq(token.pairCount(), 2);
        (uint256 s0, uint256 t0) = token.pairAt(0);
        (uint256 s1, uint256 t1) = token.pairAt(1);
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
        assertEq(token.rawLocked(), RAW_STAKE);
        assertEq(token.balanceOf(address(token)), RAW_STAKE);
    }

    //==============================================================================//
    // Maturity (isMatured)                                                          //
    //==============================================================================//
    function test_isMatured_falseWhileLocked_trueAtTargetNonce() public {
        (uint256 s, uint256 t) = _wrapLocked(alice, RAW_STAKE, 2);
        assertFalse(token.isMatured(s, t));

        _advanceNonce(1 days); // nonce 1
        assertFalse(token.isMatured(s, t));

        _advanceNonce(1 days); // nonce 2 == target
        assertTrue(token.isMatured(s, t));
    }

    function test_isMatured_degenerateWindow_maturedImmediately() public {
        (uint256 s, uint256 t) = _wrap(alice, RAW_STAKE); // lockNonces = 0
        assertTrue(token.isMatured(s, t));
    }

    function test_isMatured_revertsForUnknownWindow() public {
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        token.isMatured(9, 10);
    }

    function test_redemptions_returnRawAmounts_matchingPreviews() public {
        (uint256 s, uint256 t) = _wrapLocked(alice, RAW_STAKE, 2);

        // combined unwrap: returns exactly the burned amount, anytime
        vm.prank(alice);
        uint256 combinedOut = token.unwrap(10 ether, s, t);
        assertEq(combinedOut, 10 ether);

        // mature the window: nonce -> 2, Yield 1e18 -> 2e18 => coupon 0.5e18
        _advanceNonce(1 days);
        _applyYieldDelta(2 * NEUTRAL, 1 days);

        vm.prank(alice);
        uint256 yieldOut = token.unwrapYield(50 ether, s, t);
        assertEq(yieldOut, token.previewUnwrapYield(50 ether, s, t));
        assertEq(yieldOut, 25 ether);

        vm.prank(alice);
        uint256 capitalOut = token.unwrapCapital(50 ether, s, t);
        assertEq(capitalOut, token.previewUnwrapCapital(50 ether, s, t));
        assertEq(capitalOut, 25 ether);

        // combined preview splits exactly to the amount: capital + yield legs
        (uint256 cRaw, uint256 yRaw) = token.previewUnwrap(50 ether, s, t);
        assertEq(cRaw + yRaw, 50 ether);
    }

    function test_wrap_capturesStartNonce() public {
        _advanceNonce(1 days); // nonce 1
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 5);
        assertEq(start, token.currentNonce());
        assertEq(start, 1);
        assertEq(target, 6);
    }

    function test_wrap_lockZero_pairAtCurrentNonce() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 0);
        assertEq(start, 1);
        assertEq(target, 1);
        // degenerate window: coupon 0, capital full
        assertEq(token.couponOf(1, 1), 0);
        assertEq(token.capitalShareOf(1, 1), NEUTRAL);
        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(RAW_STAKE, 1, 1);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);
    }

    function test_wrap_zeroAmount_reverts() public {
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        token.wrap(0, 1);
    }

    function test_unknownPair_operationsRevert() public {
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        token.unwrap(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        token.unwrapYield(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        token.unwrapCapital(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        token.previewUnwrap(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        token.couponOf(0, 1);
    }

    //==============================================================================//
    // Delta pricing                                                                //
    //==============================================================================//
    function test_coupon_positiveDelta() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        assertEq(token.couponOf(1, 2), 5e17); // 1 - 1/2
        assertEq(token.capitalShareOf(1, 2), 5e17);
    }

    function test_coupon_zeroWhenNoDelta() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _advanceNonce(1 days); // nonce 2, Y unchanged
        assertEq(token.couponOf(1, 2), 0);
        assertEq(token.capitalShareOf(1, 2), NEUTRAL);
    }

    function test_coupon_zeroOnMarkdown_principalProtected() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _setYieldFactor(HALF, 1 days); // nonce 2, Y = 0.5x < 1x
        assertEq(token.couponOf(1, 2), 0);
        assertEq(token.capitalShareOf(1, 2), NEUTRAL);
        uint256 rawOut = token.previewUnwrapCapital(RAW_STAKE, 1, 2);
        assertEq(rawOut, RAW_STAKE); // full principal
    }

    function test_coupon_usesAbsoluteFactors_notDeltas() public {
        // Y goes 1x -> 2x -> 1.5x over three events; window (1,3): coupon = 1 - 1/1.5
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _setYieldFactor(15e17, 1 days); // nonce 3, Y = 1.5x
        assertEq(token.couponOf(1, 3), 333333333333333333); // 1 - 1/1.5
        assertEq(token.capitalShareOf(1, 3), 666666666666666667);
    }

    //==============================================================================//
    // Equal-leg unwrap                                                             //
    //==============================================================================//
    function test_unwrap_equalLeg_anytimeExact() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        // BEFORE expiry: exact refund, even though the split is undefined
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrap(RAW_STAKE, start, target);
        assertEq(token.balanceOf(alice) - before, RAW_STAKE);
        assertEq(token.rawLocked(), 0);

        // AFTER expiry: same exact total
        (uint256 s2, uint256 t2) = _wrapLocked(bob, RAW_STAKE, 1);
        _applyYieldDelta(DOUBLE, 1 days); // nonce 1, Y = 2x
        uint256 before2 = token.balanceOf(bob);
        vm.prank(bob);
        token.unwrap(RAW_STAKE, s2, t2);
        assertEq(token.balanceOf(bob) - before2, RAW_STAKE);
    }

    function test_unwrap_equalLeg_paysSplitAtExpiry() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(RAW_STAKE, 1, 2);
        assertEq(capOut, 50 ether);
        assertEq(yldOut, 50 ether);

        vm.prank(alice);
        token.unwrap(RAW_STAKE, 1, 2);
        assertEq(token.balanceOf(alice), 10_000 ether); // deposited 100, received 100 back
        assertEq(token.rawLocked(), 0);
    }

    function test_unwrap_partialAmount() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1);
        vm.prank(alice);
        token.unwrap(RAW_STAKE / 4, start, target);
        assertEq(_capital(start, target).balanceOf(alice), 75 ether);
        assertEq(_yield(start, target).balanceOf(alice), 75 ether);
        assertEq(token.rawLocked(), 75 ether);
    }

    //==============================================================================//
    // Solo legs (nonce-gated, frozen)                                              //
    //==============================================================================//
    function test_unwrapYield_gated_beforeTarget() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, start, target);
        _advanceNonce(1 days); // nonce 1, still < target
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, start, target);
    }

    function test_unwrapCapital_gated_beforeTarget() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        token.unwrapCapital(RAW_STAKE, start, target);
    }

    function test_unwrapYield_paysFrozenCoupon() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, 1, 2);
        assertEq(token.balanceOf(alice) - before, 50 ether);
        assertEq(_yield(1, 2).balanceOf(alice), 0);
        assertEq(_capital(1, 2).balanceOf(alice), RAW_STAKE);
        assertEq(token.rawLocked(), 50 ether);
    }

    function test_unwrapCapital_paysFrozenShare() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrapCapital(RAW_STAKE, 1, 2);
        assertEq(token.balanceOf(alice) - before, 50 ether);
        assertEq(_capital(1, 2).balanceOf(alice), 0);
        assertEq(_yield(1, 2).balanceOf(alice), RAW_STAKE);
        assertEq(token.rawLocked(), 50 ether);
    }

    function test_soloLegs_sequence_totalsExactly() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, 1, 2);
        vm.prank(alice);
        token.unwrapCapital(RAW_STAKE, 1, 2);
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(token.rawLocked(), 0);
    }

    function test_soloLegs_partial_roundingDust() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        // odd amount with coupon 0.5: floor(33 * 5e17 / 1e18) = 16 per leg
        uint256 amount = 33;
        vm.prank(alice);
        token.unwrapYield(amount, 1, 2); // pays 16
        vm.prank(alice);
        token.unwrapCapital(amount, 1, 2); // pays 16
        assertEq(token.balanceOf(alice), 10_000 ether - RAW_STAKE + 32);
        assertEq(token.rawLocked(), RAW_STAKE - 32);
    }

    //==============================================================================//
    // Frozen claims (the x5 scenario)                                              //
    //==============================================================================//
    function test_frozen_atExpiry_laterMultipliersDoNotChangeClaims() public {
        // Bob wraps 100 at nonce 1 (Y=1x), locked to nonce 3 where Y lands at 2x.
        _advanceNonce(1 days); // nonce 1, Y = 1x
        (uint256 start, uint256 target) = _wrapLocked(bob, RAW_STAKE, 2); // (1,3)
        assertEq(start, 1);
        assertEq(target, 3);
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x -> target reached
        assertEq(token.couponOf(start, target), 5e17);
        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut, 50 ether);
        assertEq(yldOut, 50 ether);

        // Nonce 5: multiplier lands at 5x. Claims MUST NOT change.
        _advanceNonce(1 days); // nonce 4, Y = 2x
        _setYieldFactor(5e18, 1 days); // nonce 5, Y = 5x
        assertEq(token.couponOf(start, target), 5e17, "yield frozen at expiry");
        assertEq(token.capitalShareOf(start, target), 5e17, "capital frozen at expiry");
        (uint256 capOut2, uint256 yldOut2) = token.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut2, 50 ether);
        assertEq(yldOut2, 50 ether);

        // Unwrapping months later pays the frozen split.
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        token.unwrap(RAW_STAKE, start, target);
        assertEq(token.balanceOf(bob) - before, RAW_STAKE);
    }

    function test_frozen_laterDividendsOnlyAffectLaterPairs() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x
        _wrapLocked(bob, RAW_STAKE, 2); // pair (3,5)
        _advanceNonce(1 days); // nonce 4, Y = 2x
        _setYieldFactor(5e18, 1 days); // nonce 5, Y = 5x
        assertEq(token.couponOf(3, 5), 1e18 - 2e18 * 1e18 / 5e18); // 1 - 2/5 = 0.6
        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(RAW_STAKE, 3, 5);
        assertEq(capOut, 40 ether);
        assertEq(yldOut, 60 ether);
    }

    function test_frozen_historicalIndependence() public {
        // Same pair redeems identically at expiry and after more dividends.
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        uint256 yldAtExpiry = token.previewUnwrapYield(RAW_STAKE, 1, 2);
        assertEq(yldAtExpiry, 50 ether);
        _applyYieldDelta(DOUBLE, 1 days); // nonce 3, Y = 4x
        _setYieldFactor(10e18, 1 days); // nonce 4, Y = 10x
        assertEq(token.previewUnwrapYield(RAW_STAKE, 1, 2), yldAtExpiry);
        assertEq(token.previewUnwrapCapital(RAW_STAKE, 1, 2), 50 ether);
    }

    //==============================================================================//
    // Pending dividends                                                            //
    //==============================================================================//
    function test_pendingDividend_doesNotAffectPricing() public {
        _advanceNonce(1 days); // nonce 1
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        // schedule but do NOT warp past it
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 10 days, "", "", "");
        assertEq(token.currentNonce(), 1, "pending does not tick the nonce");
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, start, target);
        vm.warp(block.timestamp + 10 days); // dividend lands -> nonce 2, Y = 2x
        assertEq(token.currentNonce(), 2);
        assertEq(token.couponOf(1, 2), 5e17, "landed dividend prices the window");
    }

    function test_pendingDividend_insideWindow_countsOnLanding() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3)
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 5 days, "", "", "");
        vm.warp(block.timestamp + 5 days); // lands before target: nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x
        assertEq(token.couponOf(1, 3), 5e17);
    }

    //==============================================================================//
    // Preview & display                                                            //
    //==============================================================================//
    function test_previewUnwrap_beforeExpiry_returnsFullToCapital() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);
    }

    function test_previewSolo_revertsBeforeEffective() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1)
        // schedule a pending dividend: target nonce recorded but not yet effective
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 10 days, "", "", "");
        // Immature window quotes principal-protected pricing: coupon 0 -> yield leg
        // worth 0 raw, capital leg worth the full amount. Solo redemptions still
        // revert `Locked` until maturity.
        assertEq(token.previewUnwrapYield(RAW_STAKE, start, target), 0);
        assertEq(token.previewUnwrapCapital(RAW_STAKE, start, target), RAW_STAKE);
        vm.prank(alice);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        token.unwrapYield(RAW_STAKE, start, target);
    }

    function test_previewSolo_revertsWhenTargetNotRecorded() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1), nothing scheduled
        // Immature window (target nonce not yet effective): quotes principal-protected
        // pricing instead of a confusing `EventNotRecorded` from a missing checkpoint.
        assertEq(token.previewUnwrapYield(RAW_STAKE, start, target), 0);
        assertEq(token.previewUnwrapCapital(RAW_STAKE, start, target), RAW_STAKE);
    }

    function test_previewCapitalUI_supplyDisplayOnly() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        assertEq(token.previewCapitalUI(RAW_STAKE), RAW_STAKE);
        _applySupplyDelta(DOUBLE, 1 days); // 2-for-1 split: display doubles
        assertEq(token.previewCapitalUI(RAW_STAKE), 2 * RAW_STAKE);
        assertEq(token.previewUnwrapCapital(RAW_STAKE, 1, 2), 50 ether, "raw claim unchanged");
    }

    //==============================================================================//
    // Supplies                                                                     //
    //==============================================================================//
    function test_supplies_globalAndPerPair() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2), 100 + 100
        _advanceNonce(1 days); // nonce 2
        _wrapLocked(bob, 2 * RAW_STAKE, 1); // pair (2,3), 200 + 200
        assertEq(token.capitalSupply(), 300 ether);
        assertEq(token.yieldSupply(), 300 ether);
        assertEq(token.capitalSupplyOf(1, 2), RAW_STAKE);
        assertEq(token.yieldSupplyOf(1, 2), RAW_STAKE);
        assertEq(token.capitalSupplyOf(2, 3), 2 * RAW_STAKE);
        assertEq(token.capitalSupplyOf(9, 9), 0, "unknown pair -> 0");
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
        token.unwrap(RAW_STAKE, 0, 1);
        vm.prank(bob);
        token.unwrap(RAW_STAKE, 1, 3);
        vm.prank(carol);
        token.unwrap(RAW_STAKE, 3, 4);

        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.rawLocked(), 0);
    }

    function test_conservation_mixedRedemptions() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        // solo yield 60 -> 30 raw; then equal-leg 40 -> 40 raw; then solo capital 60 -> 30 raw
        vm.prank(alice);
        token.unwrapYield(60 ether, 1, 2);
        vm.prank(alice);
        token.unwrap(40 ether, 1, 2);
        vm.prank(alice);
        token.unwrapCapital(60 ether, 1, 2);

        assertEq(token.balanceOf(alice), 10_000 ether); // 100 in, 100 out
        assertEq(token.rawLocked(), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_conservation_multiUser_sharingWindow() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _wrapLocked(bob, RAW_STAKE, 1); // same window
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, 1, 2); // 50
        vm.prank(bob);
        token.unwrapCapital(RAW_STAKE, 1, 2); // 50

        assertEq(token.balanceOf(alice), 10_000 ether - RAW_STAKE + 50 ether);
        assertEq(token.balanceOf(bob), 10_000 ether - RAW_STAKE + 50 ether);
        assertEq(token.rawLocked(), 100 ether); // both capital(50) + yield(50) remain
        assertEq(token.balanceOf(address(token)), 100 ether);
    }

    //==============================================================================//
    // Events                                                                       //
    //==============================================================================//
    function test_events_wrappedAndUnwrapped() public {
        _advanceNonce(1 days); // nonce 1
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC8056PairWrapper.Wrapped(alice, RAW_STAKE, 1, 3);
        vm.prank(alice);
        token.wrap(RAW_STAKE, 2);

        _applyYieldDelta(DOUBLE, 1 days); // nonce 2
        _advanceNonce(1 days); // nonce 3, Y = 2x
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC8056PairWrapper.Unwrapped(alice, 1, 3, RAW_STAKE, 50 ether, 50 ether);
        vm.prank(alice);
        token.unwrap(RAW_STAKE, 1, 3);
    }

    function test_events_unwrapYieldAndCapital() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC8056PairWrapper.UnwrapYield(alice, 1, 2, RAW_STAKE, 50 ether);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE, 1, 2);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC8056PairWrapper.UnwrapCapital(alice, 1, 2, RAW_STAKE, 50 ether);
        vm.prank(alice);
        token.unwrapCapital(RAW_STAKE, 1, 2);
    }

    function test_zeroAmount_reverts_everywhere() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        token.unwrap(0, 1, 2);
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        token.unwrapYield(0, 1, 2);
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        token.unwrapCapital(0, 1, 2);
    }

    //==============================================================================//
    // Liveness edges                                                               //
    //==============================================================================//
    function test_unwrap_revertsForHolderOfSingleLeg() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        vm.startPrank(alice);
        _yield(1, 2).transfer(carol, RAW_STAKE); // alice now holds capital only
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, RAW_STAKE));
        vm.prank(alice);
        token.unwrap(RAW_STAKE, 1, 2);
    }

    function test_tokens_areTransferableErc20() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        vm.startPrank(alice);
        _capital(1, 2).transfer(carol, 10 ether);
        assertEq(_capital(1, 2).balanceOf(alice), RAW_STAKE - 10 ether);
        assertEq(_capital(1, 2).balanceOf(carol), 10 ether);
        _yield(1, 2).transfer(carol, 20 ether);
        assertEq(_yield(1, 2).balanceOf(alice), RAW_STAKE - 20 ether);
        assertEq(_yield(1, 2).balanceOf(carol), 20 ether);
        vm.stopPrank();
    }

    function test_delayedDividend_lockCapturesLateDividend() public {
        // Pair (0,1); the pending dividend is superseded before it lands, so the
        // window's target nonce only fills when a dividend actually becomes
        // effective. Equal-leg unwrap must work throughout; solo legs stay locked
        // until then.
        _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1)

        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 3e18, block.timestamp + 1 days, "", "", "");

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrap(RAW_STAKE / 2, 0, 1);
        assertEq(token.balanceOf(alice) - before, RAW_STAKE / 2);

        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE / 2, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        token.unwrapCapital(RAW_STAKE / 2, 0, 1);

        // The next dividend fills nonce 1; solo legs unlock with the frozen coupon.
        _setYieldFactor(2e18, 1 days); // nonce 1, Y = 2x
        assertEq(token.couponOf(0, 1), 5e17);
        uint256 yldBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrapYield(RAW_STAKE / 2, 0, 1);
        assertEq(token.balanceOf(alice) - yldBefore, RAW_STAKE / 4);
        uint256 capBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrapCapital(RAW_STAKE / 2, 0, 1);
        assertEq(token.balanceOf(alice) - capBefore, RAW_STAKE / 4);
    }

    //==============================================================================//
    // ERC-165 interface detection                                                  //
    //==============================================================================//
    function test_supportsInterface_wrapperInterface() public view {
        assertTrue(token.supportsInterface(type(IERC8056PairWrapper).interfaceId));
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC-165 itself
        assertFalse(token.supportsInterface(0xffffffff));
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    /// @dev Token-side discovery: the SAME contract advertises both the composite
    ///      and the pair-wrapper interface — no registry lookup needed.
    function test_supportsInterface_advertisesPairWrapper() public view {
        assertTrue(token.supportsInterface(type(IERC8056PairWrapper).interfaceId));
        assertTrue(token.supportsInterface(type(IERC8056Composite).interfaceId));
    }

    function test_supportsInterface_legTokens() public {
        _wrapLocked(alice, RAW_STAKE, 1);
        (IERC20 capital, IERC20 yieldLeg) = (token.capitalToken(0, 1), token.yieldToken(0, 1));
        // LegToken is plain ERC-20: it must expose standard ERC-165 probing
        assertTrue(IERC165(address(capital)).supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(IERC165(address(yieldLeg)).supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(IERC165(address(capital)).supportsInterface(0xdeadbeef));
    }

    //==============================================================================//
    // Token-side variant specifics                                                 //
    //==============================================================================//
    /// @dev Self-escrow: wrap must succeed with ZERO approvals granted anywhere.
    function test_wrap_selfEscrow_noApprovalNeeded() public {
        uint256 before = token.balanceOf(alice);
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1);

        assertEq(token.balanceOf(alice), before - RAW_STAKE, "caller debited internally");
        assertEq(token.balanceOf(address(token)), RAW_STAKE, "escrow == token's own balance");
        assertEq(_capital(start, target).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(start, target).balanceOf(alice), RAW_STAKE);
        assertEq(token.allowance(alice, address(token)), 0, "no approval was ever needed");
    }

    /// @dev LegToken minter is the token contract itself; nobody else can mint legs.
    function test_legMinter_isTheToken() public {
        _wrapLocked(alice, RAW_STAKE, 1);
        LegToken capital = _capital(0, 1);
        assertEq(capital.minter(), address(token), "minter must be the token contract");

        vm.prank(alice);
        vm.expectRevert(LegToken.Unauthorized.selector);
        capital.mint(alice, 1);
    }

    /// @dev The wrapped asset IS the token: metadata views return the token's own.
    function test_assetMetadata_matchesToken() public view {
        assertEq(token.assetName(), token.name());
        assertEq(token.assetSymbol(), token.symbol());
        assertEq(address(token.underlying()), address(token), "underlying() is the token itself");
        assertEq(address(token.scaledUnderlying()), address(token), "scaledUnderlying() is the token itself");
    }

    //==============================================================================//
    // Truthful backing view (MED-2-docs)                                           //
    //==============================================================================//
    function test_windowBackingOf_zeroForNonexistentPair() public view {
        assertEq(token.windowBackingOf(9, 9), 0, "nonexistent pair -> 0");
    }

    function test_windowBackingOf_matchesFrozenSplit() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x -> coupon = 0.5

        // backing = 100 * (1 - 0.5) + 100 * 0.5 = 100
        assertEq(token.windowBackingOf(1, 2), RAW_STAKE);
    }

    function test_windowBackingOf_afterSoloYieldRedemption_isTruthful() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x -> coupon = 0.5

        vm.prank(alice);
        token.unwrapYield(60 ether, 1, 2); // pays 30 raw; yield supply -> 40

        // rawLocked is truthful here (70) but rawLockedOf still reports capital supply
        assertEq(token.rawLocked(), 70 ether);
        assertEq(token.rawLockedOf(1, 2), RAW_STAKE, "deprecated view is misleading by design");
        // windowBackingOf: capital 100 * share 0.5 + yield 40 * coupon 0.5 = 70
        assertEq(token.windowBackingOf(1, 2), 70 ether, "backing reflects solo redemption");
    }

    function test_windowBackingOf_immatureWindow_oneToOne_thenFrozen() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2); // pair (1,3), immature

        // Pre-maturity: solo redemptions are gated, so each pair is held in equal
        // capital/yield amounts and only the combined `unwrap` is exercisable at 1:1.
        // Realizable backing is therefore min(capitalSupply, yieldSupply), not their sum.
        assertEq(token.currentNonce(), 1, "window still immature");
        assertEq(
            token.windowBackingOf(start, target),
            token.capitalSupplyOf(start, target),
            "immature -> min(capital, yield) backing (equal supplies)"
        );
        assertEq(token.windowBackingOf(start, target), RAW_STAKE);

        vm.prank(alice);
        token.unwrap(RAW_STAKE / 2, start, target);
        assertEq(
            token.windowBackingOf(start, target),
            token.capitalSupplyOf(start, target),
            "immature -> 1:1 backing after partial unwrap"
        );
        assertEq(token.windowBackingOf(start, target), RAW_STAKE / 2); // 50 each, min = 50

        // Matures: frozen formula applies.
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3 -> target reached, coupon = 0.5
        assertEq(token.windowBackingOf(start, target), RAW_STAKE / 2, "mature -> frozen formula");
    }

    function test_windowBackingOf_zeroCoupon_fullCapitalBacking() public {
        _advanceNonce(1 days); // nonce 1, Y = 1x
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _setYieldFactor(HALF, 1 days); // nonce 2, Y falls -> coupon 0

        assertEq(token.windowBackingOf(1, 2), RAW_STAKE, "principal protected -> full backing");
    }

    /// @dev Regression for fresh/upgraded composite with no Yield events yet: wrapping a
    ///      real window (lockNonces > 0) must NOT brick on a missing checkpoint. The immature
    ///      window prices at 1:1 (coupon 0) so the combined `unwrap` pays back exactly the
    ///      stake, while solo redemptions stay gated by `Locked`.
    function test_wrapLockedOnFreshComposite_pricesOneToOne() public {
        // Token has zero Yield events at setUp: currentNonce() == 0.
        assertEq(token.currentNonce(), 0);
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        assertEq(target, 2);

        // Immature window: coupon 0, both legs redeem 1:1 via unwrap.
        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);

        // Solo redemptions remain gated until the target nonce matures.
        vm.prank(alice);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        token.unwrapYield(RAW_STAKE, start, target);

        // Combined unwrap pays back the full stake, leaving the escrow drained.
        vm.prank(alice);
        token.unwrap(RAW_STAKE, start, target);
        assertEq(token.balanceOf(address(token)), 0);
    }

    //==============================================================================//
    // Upgraded vanilla proxy: degenerate (0,0) window must not brick funds         //
    //==============================================================================//
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Regression: wrap(amount, 0) on a freshly-upgraded proxy creates window
    ///      (0,0); unwrap/solo legs/preview must resolve via the synthetic genesis
    ///      event instead of reverting EventNotRecorded.
    function test_upgradedVanillaProxy_wrapLockZero_unwrapPaysBack() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        address impl = address(new ERC8056CompositePairWrapper("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(impl))));
        ERC8056CompositePairWrapper upgraded = ERC8056CompositePairWrapper(address(proxy));

        vm.prank(owner);
        upgraded.mint(alice, RAW_STAKE);
        vm.startPrank(alice);
        (uint256 start, uint256 target) = upgraded.wrap(RAW_STAKE, 0);
        assertEq(start, 0, "window starts at empty-history nonce 0");
        assertEq(target, 0);

        assertTrue(upgraded.hasPair(0, 0));
        assertEq(upgraded.couponOf(0, 0), 0, "degenerate window: coupon 0");
        assertEq(upgraded.capitalShareOf(0, 0), NEUTRAL);

        (uint256 capOut, uint256 yldOut) = upgraded.previewUnwrap(RAW_STAKE, 0, 0);
        assertEq(capOut, RAW_STAKE);
        assertEq(yldOut, 0);

        // matured gate passes (classNonce 0 >= target 0) and solo previews resolve
        assertEq(upgraded.previewUnwrapCapital(RAW_STAKE, 0, 0), RAW_STAKE);
        assertEq(upgraded.previewUnwrapYield(RAW_STAKE, 0, 0), 0);

        upgraded.unwrap(RAW_STAKE, 0, 0);
        vm.stopPrank();

        assertEq(upgraded.balanceOf(alice), RAW_STAKE, "full amount paid back");
        assertEq(upgraded.windowBackingOf(0, 0), 0);
        assertEq(upgraded.balanceOf(address(proxy)), 0, "self-escrow drained");
    }

    /// @dev Migration guard on the token-side variant: while a live vanilla pending
    ///      exists, the first classed schedule reverts VanillaPendingUpdate (the
    ///      bootstrap guard). Wrap itself is view-bootstrap-safe, but a wrapper
    ///      window that needs a priced nonce (lockNonces > 0) requires the issuer
    ///      to land or cancel the vanilla pending first, per the composite's
    ///      landed/cancelled resolution paths.
    function test_upgradedVanillaProxy_livePending_scheduleGuarded_thenLandAndWrap() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        uint256 pendEff = block.timestamp + 30 days;
        // vanilla layout: slot 5 owner, 6 _uiMultiplier, 7 _newUIMultiplier, 8 _effectiveAt
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        vm.store(address(proxy), bytes32(uint256(6)), bytes32(uint256(2 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(7)), bytes32(uint256(3 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(8)), bytes32(uint256(pendEff)));
        address impl = address(new ERC8056CompositePairWrapper("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(impl))));
        ERC8056CompositePairWrapper upgraded = ERC8056CompositePairWrapper(address(proxy));

        // first classed schedule is guarded while the vanilla pending is live
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC8056Composite.VanillaPendingUpdate.selector, pendEff));
        upgraded.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");

        // resolution path 1: let the vanilla update land, then schedule + wrap
        vm.warp(pendEff + 1);
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days); // nonce 1, Y = 2x

        vm.prank(owner);
        upgraded.mint(alice, RAW_STAKE);
        vm.prank(alice);
        (uint256 start, uint256 target) = upgraded.wrap(RAW_STAKE, 1); // pair (1,2)
        assertEq(start, 1);
        assertEq(target, 2);
        assertEq(upgraded.couponOf(1, 2), 0, "window still immature");
    }
}
