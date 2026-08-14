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
        assertEq(capBal, yldBal); // full pairs only - equal-leg invariant
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(capBal, unlockNonce);
        assertApproxEqAbs(capOut + yldOut, expected, tolerance);
    }

    //==============================================================================//
    // Pair tokens                                                                  //
    //==============================================================================//
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

    //==============================================================================//
    // Wrap                                                                         //
    //==============================================================================//
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
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2.0, nonce -> 1
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

    //==============================================================================//
    // Capital leg                                                                  //
    //==============================================================================//
    function test_capitalToken_isOneConstantYieldUIUnit() public {
        _wrap(alice, RAW_STAKE);

        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE); // Y=1: 1 raw per token
        assertEq(wrapper.capitalRawValue(1 ether), NEUTRAL); // raw * Y = 1 Yield-UI unit

        _applyYieldDelta(DOUBLE, 1 hours);
        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE / 2); // Y=2: 0.5 raw per token
        assertEq(wrapper.capitalRawValue(1 ether) * DOUBLE / 1e18, NEUTRAL); // still 1 UI unit
    }

    function test_capitalTokens_fungibleAcrossWrapTimes() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce -> 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1

        // Capital tokens minted in different pairs share one uniform raw value (1/Y).
        assertEq(wrapper.capitalRawValue(RAW_STAKE), Math.mulDiv(RAW_STAKE, 1e18, 11e17));
        assertEq(
            wrapper.capitalRawValue(_capital(0).balanceOf(bob)),
            wrapper.capitalRawValue(_capital(1).balanceOf(alice))
        );
    }

    //==============================================================================//
    // Pair-exactness (pool model)                                                  //
    //==============================================================================//
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
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce -> 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1

        // Immediately after Alice's wrap, both pairs are exact (1 wei rounding).
        _assertPairExact(bob, 0, RAW_STAKE, 1);
        _assertPairExact(alice, 1, RAW_STAKE, 1);

        _applyYieldDelta(DOUBLE, 1 hours); // Y=2.0, nonce -> 2
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
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce -> 1
        _wrap(alice, RAW_STAKE); // pair 1 @ Y=1.1
        _applyYieldDelta(13e17, 1 hours); // Y=1.3, nonce -> 2
        _wrap(carol, HALF); // pair 2, 50 @ Y=1.3

        _assertPairExact(bob, 0, RAW_STAKE, 1);
        _assertPairExact(alice, 1, RAW_STAKE, 1);
        _assertPairExact(carol, 2, HALF, 1);

        _setYieldFactor(DOUBLE, 1 hours); // absolute: Y=2.0 exactly, nonce -> 3

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
        _applyYieldDelta(15e17, 1 hours); // dividend *1.5, nonce -> 1
        _wrap(alice, RAW_STAKE); // pair 1, mid-stream wrap
        _applyYieldDelta(DOUBLE, 1 hours); // dividend *2, nonce -> 2
        _applySupplyDelta(HALF, 1 hours); // reverse split *0.5 (nonce unchanged)
        _setYieldFactor(DOUBLE, 1 hours); // absolute: Y=2.0 exactly, nonce -> 3

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

    //==============================================================================//
    // Yield leg fungibility                                                        //
    //==============================================================================//
    function test_yieldTokens_fungibleUniformValue() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(11e17, 1 hours); // Y=1.1, nonce -> 1
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

    //==============================================================================//
    // Unwrap rules (equal-leg)                                                     //
    //==============================================================================//
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

    //==============================================================================//
    // Lock rules (solo unwraps, nonce-gated)                                       //
    //==============================================================================//
    function test_wrap_lockZero_pairAtCurrentNonce() public {
        _wrapLocked(alice, RAW_STAKE, 0); // nonce 0 -> pair 0
        assertEq(wrapper.pairCount(), 1);
        assertEq(wrapper.pairNonceAt(0), 0);
        assertEq(_capital(0).balanceOf(alice), RAW_STAKE);
    }

    function test_wrap_lockCount_setsUnlockNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // nonce 0 -> pair 2
        assertEq(wrapper.pairCount(), 1);
        assertEq(wrapper.pairNonceAt(0), 2);
        assertEq(_capital(2).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(2).balanceOf(alice), RAW_STAKE);
    }

    function test_wrap_lockCount_afterDividends_countsFutureOnly() public {
        _wrapLocked(alice, RAW_STAKE, 1); // nonce 0 -> pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // nonce -> 1: alice's lock is satisfied
        _wrapLocked(bob, RAW_STAKE, 1); // nonce 1 -> pair 2

        assertEq(wrapper.pairNonceAt(0), 1);
        assertEq(wrapper.pairNonceAt(1), 2);
        assertEq(_yield(1).balanceOf(alice), RAW_STAKE);
        assertEq(_yield(2).balanceOf(bob), RAW_STAKE);
    }

    function test_unwrapYield_blockedBeforeNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce -> 1 < 2

        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapYield(RAW_STAKE, 2);
    }

    function test_unwrapYield_allowedAtNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2, nonce 0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce -> 1
        _setYieldFactor(DOUBLE, 1 hours); // Y=2 (absolute), nonce -> 2 -> unlocked

        uint256 aliceBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 2);

        // Y=2: yield per token = 0.5 raw -> 50 raw out; capital untouched.
        assertEq(underlying.balanceOf(alice), aliceBefore + 50 ether);
        assertEq(wrapper.rawLocked(), 50 ether);
        assertEq(wrapper.capitalSupply(), RAW_STAKE);
        assertEq(wrapper.yieldSupply(), 0);
    }

    function test_unwrapCapital_blockedBeforeNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2
        _applyYieldDelta(DOUBLE, 1 hours); // nonce -> 1 < 2

        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapCapital(RAW_STAKE, 2);
    }

    function test_unwrapCapital_allowedAtNonce() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2, nonce 0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce -> 1
        _setYieldFactor(DOUBLE, 1 hours); // Y=2 (absolute), nonce -> 2 -> unlocked

        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 2);

        // Y=2: capital per token = 0.5 raw -> 50 raw out; yield untouched.
        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE + 50 ether);
        assertEq(wrapper.rawLocked(), 50 ether);
        assertEq(wrapper.capitalSupply(), 0);
        assertEq(wrapper.yieldSupply(), RAW_STAKE);
    }

    function test_equalLeg_unwrap_anytime_evenWhileLocked() public {
        _wrapLocked(alice, RAW_STAKE, 2); // pair 2
        _applyYieldDelta(DOUBLE, 1 hours); // nonce -> 1, still locked

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

        vm.warp(block.timestamp + 2 days); // old "expiry" date passes - still locked, still entitled
        assertEq(wrapper.currentNonce(), 0);
        vm.prank(alice);
        vm.expectRevert(ScaledPairWrapper.Locked.selector);
        wrapper.unwrapYield(RAW_STAKE, 1);

        vm.warp(block.timestamp + 2 days); // dividend finally lands
        assertEq(wrapper.currentNonce(), 1);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1);

        // Y=1.5: yield per token = 1/3 raw -> 33.333...e18 raw out.
        assertEq(underlying.balanceOf(alice), 9900 ether + 33333333333333333334);
    }

    function test_yieldPerToken_uniformAcrossPairs() public {
        _wrap(bob, RAW_STAKE); // pair 0
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce -> 1

        (uint256 c0, uint256 y0) = wrapper.previewUnwrap(RAW_STAKE, 0);
        (uint256 c1, uint256 y1) = wrapper.previewUnwrap(RAW_STAKE, 1);
        assertEq(c0, c1); // capital uniform (1/Y)
        assertEq(y0, y1); // yield uniform across expiries
        assertEq(y0, RAW_STAKE / 2);
    }

    function test_invariant_afterSoloUnwraps() public {
        _wrap(bob, RAW_STAKE); // pair 0
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce -> 1
        _applyYieldDelta(15e17, 1 hours); // Y=3, nonce -> 2

        vm.prank(bob);
        wrapper.unwrapYield(50 ether, 0); // solo yield (nonce 2 >= 0)
        vm.prank(alice);
        wrapper.unwrapCapital(40 ether, 1); // solo capital (nonce 2 >= 1)

        // Invariant: rawLocked == C/Y + YS*(1-1/Y) at Y=3 (1-2 wei rounding drift).
        uint256 Y = 3e18;
        uint256 rhs = Math.mulDiv(wrapper.capitalSupply(), 1e18, Y)
            + Math.mulDiv(wrapper.yieldSupply(), Y - 1e18, Y);
        assertApproxEqAbs(wrapper.rawLocked(), rhs, 2);

        // Per-token yield remains uniform = 1 - 1/Y.
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

    //==============================================================================//
    // Supply class is display-only                                                 //
    //==============================================================================//
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

    //==============================================================================//
    // Factor markdowns                                                             //
    //==============================================================================//
    function test_factorDrop_neverLocksOrPenalizes() public {
        _wrap(alice, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(8e17, 1 hours); // maintainer marks Yield down to 0.8x, nonce -> 1

        // Supply display is untouched (Yield-class event); redemption is floored at 1:1 raw.
        assertEq(wrapper.previewCapitalUI(RAW_STAKE), RAW_STAKE);
        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE);
        assertEq(wrapper.poolYieldRaw(), 0);
        assertEq(wrapper.yieldPerTokenRaw(), 0);

        // Full pair still redeems exactly the stake - no lock, no penalty.
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
        _applyYieldDelta(DOUBLE, 1 hours); // dividend to *2, nonce -> 1
        _applyYieldDelta(4e17, 1 hours); // markdown *0.4 -> Y = 0.8 < 1, nonce -> 2

        // Capital floor keeps redemption at 1:1; the *2 dividend is unwound.
        assertEq(wrapper.capitalRawValue(RAW_STAKE), RAW_STAKE);
        assertEq(wrapper.poolYieldRaw(), 0);

        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 0);
        assertEq(underlying.balanceOf(alice), 10_000 ether);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
    }

    function test_markdown_soloYieldPaysZero() public {
        _wrapLocked(alice, RAW_STAKE, 1); // pair 1
        _applyYieldDelta(DOUBLE, 1 hours); // nonce -> 1 -> unlocked
        _applyYieldDelta(4e17, 1 hours); // markdown -> Y = 0.8, nonce -> 2

        assertEq(wrapper.poolYieldRaw(), 0);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1); // pays 0: the markdown was absorbed

        assertEq(underlying.balanceOf(alice), 10_000 ether - RAW_STAKE);
        assertEq(wrapper.rawLocked(), RAW_STAKE);
    }

    //==============================================================================//
    // Conservation                                                                 //
    //==============================================================================//
    function test_conservation_afterMixedUnwraps() public {
        _wrap(bob, RAW_STAKE); // pair 0 @ Y=1.0
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2.0, nonce -> 1
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

    //==============================================================================//
    // Events                                                                       //
    //==============================================================================//
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
        _applyYieldDelta(DOUBLE, 1 hours); // Y=2, nonce -> 1 -> unlocked

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