// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056PairWrapper} from "../src/wrapper/ERC8056PairWrapper.sol";
import {IERC8056PairWrapper} from "../src/wrapper/interfaces/IERC8056PairWrapper.sol";
import {LegToken} from "../src/wrapper/LegToken.sol";
import {ERC8056Composite} from "../src/extensions/ERC8056Composite.sol";
import {MultiplierClass} from "../src/extensions/interfaces/MultiplierClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ERC8056PairWrapperTest is ScalingTestBase {
    ERC8056Composite internal underlying;
    ERC8056PairWrapper internal wrapper;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        underlying = new ERC8056Composite("Stock", "STK", owner);

        wrapper = new ERC8056PairWrapper(IERC20(address(underlying)), underlying, "Tesla", "Tesla");

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
        uint256 current = underlying.uiScalingFactor(MultiplierClass.Yield);
        uint256 newMultiplier = (current * delta) / 1e18;
        vm.prank(owner);
        underlying.setUIMultiplier(MultiplierClass.Yield, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function _applySupplyDelta(uint256 delta, uint256 delay) internal {
        uint256 current = underlying.uiScalingFactor(MultiplierClass.Supply);
        uint256 newMultiplier = (current * delta) / 1e18;
        vm.prank(owner);
        underlying.setUIMultiplier(MultiplierClass.Supply, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function _setYieldFactor(uint256 factor, uint256 delay) internal {
        vm.prank(owner);
        underlying.setUIMultiplier(MultiplierClass.Yield, factor, block.timestamp + delay, "", "", "");
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

    function _capital(uint256 start, uint256 target) internal view returns (LegToken) {
        return LegToken(address(wrapper.pairs(start, target).capital));
    }

    function _yield(uint256 start, uint256 target) internal view returns (LegToken) {
        return LegToken(address(wrapper.pairs(start, target).yield));
    }

    function _assertPairExact(address user, uint256 start, uint256 target, uint256 expected) internal view {
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
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.wrap(0, 1);
    }

    function test_unknownPair_operationsRevert() public {
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        wrapper.unwrap(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        wrapper.unwrapYield(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        wrapper.unwrapCapital(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
        wrapper.previewUnwrap(1, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.PairNotFound.selector);
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
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, start, target);
        _advanceNonce(1 days); // nonce 1, still < target
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, start, target);
    }

    function test_unwrapCapital_gated_beforeTarget() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 2);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
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
        assertEq(start, 1);
        assertEq(target, 3);
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x
        _advanceNonce(1 days); // nonce 3, Y = 2x -> target reached
        assertEq(wrapper.couponOf(start, target), 5e17);
        (uint256 capOut, uint256 yldOut) = wrapper.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut, 50 ether);
        assertEq(yldOut, 50 ether);

        // Nonce 5: multiplier lands at 5x. Claims MUST NOT change.
        _advanceNonce(1 days); // nonce 4, Y = 2x
        _setYieldFactor(5e18, 1 days); // nonce 5, Y = 5x
        assertEq(wrapper.couponOf(start, target), 5e17, "yield frozen at expiry");
        assertEq(wrapper.capitalShareOf(start, target), 5e17, "capital frozen at expiry");
        (uint256 capOut2, uint256 yldOut2) = wrapper.previewUnwrap(RAW_STAKE, start, target);
        assertEq(capOut2, 50 ether);
        assertEq(yldOut2, 50 ether);

        // Unwrapping months later pays the frozen split.
        uint256 before = underlying.balanceOf(bob);
        vm.prank(bob);
        wrapper.unwrap(RAW_STAKE, start, target);
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
        underlying.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 10 days, "", "", "");
        assertEq(wrapper.currentNonce(), 1, "pending does not tick the nonce");
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
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
        underlying.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 5 days, "", "", "");
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
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1)
        // schedule a pending dividend: target nonce recorded but not yet effective
        vm.prank(owner);
        underlying.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 10 days, "", "", "");
        vm.expectRevert(bytes4(keccak256("EventNotEffective()")));
        wrapper.previewUnwrapYield(RAW_STAKE, start, target);
        vm.expectRevert(bytes4(keccak256("EventNotEffective()")));
        wrapper.previewUnwrapCapital(RAW_STAKE, start, target);
    }

    function test_previewSolo_revertsWhenTargetNotRecorded() public {
        (uint256 start, uint256 target) = _wrapLocked(alice, RAW_STAKE, 1); // pair (0,1), nothing scheduled
        vm.expectRevert(bytes4(keccak256("EventNotRecorded()")));
        wrapper.previewUnwrapYield(RAW_STAKE, start, target);
        vm.expectRevert(bytes4(keccak256("EventNotRecorded()")));
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
        emit IERC8056PairWrapper.Wrapped(alice, RAW_STAKE, 1, 3);
        vm.prank(alice);
        wrapper.wrap(RAW_STAKE, 2);

        _applyYieldDelta(DOUBLE, 1 days); // nonce 2
        _advanceNonce(1 days); // nonce 3, Y = 2x
        vm.expectEmit(true, true, true, true, address(wrapper));
        emit IERC8056PairWrapper.Unwrapped(alice, 1, 3, RAW_STAKE, 50 ether, 50 ether);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE, 1, 3);
    }

    function test_events_unwrapYieldAndCapital() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2, Y = 2x

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit IERC8056PairWrapper.UnwrapYield(alice, 1, 2, RAW_STAKE, 50 ether);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE, 1, 2);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit IERC8056PairWrapper.UnwrapCapital(alice, 1, 2, RAW_STAKE, 50 ether);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE, 1, 2);
    }

    function test_zeroAmount_reverts_everywhere() public {
        _advanceNonce(1 days); // nonce 1
        _wrapLocked(alice, RAW_STAKE, 1); // pair (1,2)
        _applyYieldDelta(DOUBLE, 1 days); // nonce 2
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.unwrap(0, 1, 2);
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.unwrapYield(0, 1, 2);
        vm.expectRevert(IERC8056PairWrapper.InvalidAmount.selector);
        vm.prank(alice);
        wrapper.unwrapCapital(0, 1, 2);
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
        wrapper.unwrap(RAW_STAKE, 1, 2);
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
        underlying.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.prank(owner);
        underlying.setUIMultiplier(MultiplierClass.Yield, 3e18, block.timestamp + 1 days, "", "", "");

        uint256 before = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrap(RAW_STAKE / 2, 0, 1);
        assertEq(underlying.balanceOf(alice) - before, RAW_STAKE / 2);

        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE / 2, 0, 1);
        vm.expectRevert(IERC8056PairWrapper.Locked.selector);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE / 2, 0, 1);

        // The next dividend fills nonce 1; solo legs unlock with the frozen coupon.
        _setYieldFactor(2e18, 1 days); // nonce 1, Y = 2x
        assertEq(wrapper.couponOf(0, 1), 5e17);
        uint256 yldBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapYield(RAW_STAKE / 2, 0, 1);
        assertEq(underlying.balanceOf(alice) - yldBefore, RAW_STAKE / 4);
        uint256 capBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        wrapper.unwrapCapital(RAW_STAKE / 2, 0, 1);
        assertEq(underlying.balanceOf(alice) - capBefore, RAW_STAKE / 4);
    }
}
