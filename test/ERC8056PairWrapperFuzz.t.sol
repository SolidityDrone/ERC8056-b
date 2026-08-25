// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056PairWrapper} from "../src/wrapper/ERC8056PairWrapper.sol";
import {ERC8056Composite} from "../src/extensions/ERC8056Composite.sol";
import {UIScalingClass} from "../src/extensions/interfaces/UIScalingClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC8056PairWrapperFuzzTest is ScalingTestBase {
    ERC8056Composite internal underlying;
    ERC8056PairWrapper internal wrapper;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        underlying = new ERC8056Composite("Stock", "STK", owner);
        wrapper = new ERC8056PairWrapper(IERC20(address(underlying)), underlying, "Tesla", "Tesla");
        vm.prank(owner);
        underlying.mint(alice, type(uint96).max);
        vm.startPrank(alice);
        underlying.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    function _setYieldFactor(uint256 factor, uint256 delay) internal {
        vm.prank(owner);
        underlying.setUIScalingFactor(UIScalingClass.Yield, factor, block.timestamp + delay, "", "", "");
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
        vm.prank(alice);
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
        vm.prank(alice);
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

        vm.prank(alice);
        (uint256 start, uint256 target) = wrapper.wrap(amount, lockNonces);

        // random dividend events BEFORE unwrap
        for (uint256 i = 0; i < dividends; i++) {
            vm.prank(owner);
            underlying.applyUIScalingDelta(
                UIScalingClass.Yield,
                bound(uint256(keccak256(abi.encode(i))), 5e17, 2e18),
                block.timestamp + 1 days,
                "",
                "",
                ""
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
        vm.prank(alice);
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

        vm.prank(alice);
        (uint256 start, uint256 target) = wrapper.wrap(amount, lockNonces);
        vm.prank(alice);
        wrapper.unwrap(amount, start, target);
        assertEq(underlying.balanceOf(alice), type(uint96).max, "full round trip");
        assertEq(wrapper.rawLocked(), 0);
        assertEq(underlying.balanceOf(address(wrapper)), 0);
    }
}
