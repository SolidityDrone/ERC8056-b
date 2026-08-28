// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056CompositePairWrapper} from "../src/token-side/ERC8056CompositePairWrapper.sol";
import {MultiplierClass} from "../src/interfaces/extension/IERC8056MultiplierClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Port of the standalone wrapper fuzz suite to the token-side variant.
///      No decimals fuzz scenarios exist here: wrap/unwrap are internal ledger
///      moves on an 18-decimal, full-metadata token (see the unit file header
///      for the structural rationale).
contract ERC8056CompositePairWrapperFuzzTest is ScalingTestBase {
    ERC8056CompositePairWrapper internal token;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new ERC8056CompositePairWrapper("Stock", "STK", owner);
        vm.prank(owner);
        token.mint(alice, type(uint96).max);
        // No approval: wrap self-escrows via an internal ledger update.
    }

    function _setYieldFactor(uint256 factor, uint256 delay) internal {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, factor, block.timestamp + delay, "", "", "");
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
        (uint256 start, uint256 target) = token.wrap(amount, 1); // pair (1,2)
        _setYieldFactor(yTarget, 1 days); // nonce 2: Y = yTarget

        (uint256 capOut, uint256 yldOut) = token.previewUnwrap(amount, start, target);
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
        (uint256 start, uint256 target) = token.wrap(amount, 1);
        _setYieldFactor(yTarget, 1 days); // nonce 2

        uint256 coupon = _coupon(yStart, yTarget);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrapYield(amount, start, target);
        assertEq(token.balanceOf(alice) - before, Math.mulDiv(amount, coupon, 1e18));

        before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrapCapital(amount, start, target);
        assertEq(token.balanceOf(alice) - before, Math.mulDiv(amount, 1e18 - coupon, 1e18));

        // at most 1 wei of dust stays in the escrow (floor rounding on both legs)
        assertLe(token.balanceOf(address(token)), 1);
    }

    function testFuzz_equalLegExact_anytime(uint256 amount, uint256 lockNonces, uint256 dividends) public {
        amount = bound(amount, 1, 100_000 ether);
        lockNonces = bound(lockNonces, 1, 5);
        dividends = bound(dividends, 0, 4);

        vm.prank(alice);
        (uint256 start, uint256 target) = token.wrap(amount, lockNonces);

        // random dividend events BEFORE unwrap
        for (uint256 i = 0; i < dividends; i++) {
            vm.prank(owner);
            token.setUIMultiplier(
                MultiplierClass.Yield,
                bound(uint256(keccak256(abi.encode(i))), 5e17, 2e18),
                block.timestamp + 1 days,
                "",
                "",
                ""
            );
            vm.warp(block.timestamp + 1 days);
        }

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.unwrap(amount, start, target);
        assertEq(token.balanceOf(alice) - before, amount, "equal-leg exact at any time");
    }

    function testFuzz_laterDividends_doNotChangeClaims(uint256 amount, uint256 laterEvents) public {
        amount = bound(amount, 1, 100_000 ether);
        laterEvents = bound(laterEvents, 1, 4);

        _setYieldFactor(2e18, 1 days); // nonce 1: Y = 2x
        vm.prank(alice);
        (uint256 start, uint256 target) = token.wrap(amount, 1); // pair (1,2)
        _setYieldFactor(3e18, 1 days); // nonce 2: Y = 3x -> frozen

        (uint256 capAtExpiry, uint256 yldAtExpiry) = token.previewUnwrap(amount, start, target);
        uint256 yldSoloAtExpiry = token.previewUnwrapYield(amount, start, target);

        for (uint256 i = 0; i < laterEvents; i++) {
            _setYieldFactor(bound(uint256(keccak256(abi.encode("later", i))), 3e18, 50e18), 1 days);
        }

        (uint256 capNow, uint256 yldNow) = token.previewUnwrap(amount, start, target);
        assertEq(capNow, capAtExpiry, "capital frozen");
        assertEq(yldNow, yldAtExpiry, "yield frozen");
        assertEq(token.previewUnwrapYield(amount, start, target), yldSoloAtExpiry, "solo frozen");
    }

    function testFuzz_roundTrip_singleWindow(uint256 amount, uint256 lockNonces) public {
        amount = bound(amount, 1, 100_000 ether);
        lockNonces = bound(lockNonces, 0, 5);

        vm.prank(alice);
        (uint256 start, uint256 target) = token.wrap(amount, lockNonces);
        vm.prank(alice);
        token.unwrap(amount, start, target);
        assertEq(token.balanceOf(alice), type(uint96).max, "full round trip");
        assertEq(token.rawLocked(), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
