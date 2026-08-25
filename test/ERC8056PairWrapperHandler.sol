// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC8056PairWrapper} from "../src/wrapper/ERC8056PairWrapper.sol";
import {IERC8056PairWrapper} from "../src/wrapper/interfaces/IERC8056PairWrapper.sol";
import {ERC8056Composite} from "../src/extensions/ERC8056Composite.sol";
import {UIScalingClass} from "../src/extensions/interfaces/UIScalingClass.sol";

/// @dev Action handler for the wrapper invariant suite. Every entrypoint either
///      performs an operation or reverts; asserts inside handlers fail the suite.
contract ERC8056PairWrapperHandler is Test {
    ERC8056Composite public immutable underlying;
    ERC8056PairWrapper public immutable wrapper;
    address public immutable owner;

    uint256 public totalDeposited;
    uint256 public totalRedeemed;
    uint256 public soloRedemptions;

    constructor(ERC8056Composite underlying_, ERC8056PairWrapper wrapper_, address owner_) {
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
            vm.expectRevert(IERC8056PairWrapper.Locked.selector);
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
        soloRedemptions++;
    }

    function unwrapCapital(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 capBal = wrapper.pairs(start, target).capital.balanceOf(actor);
        if (capBal == 0) return;
        uint256 amount = bound(amountSeed, 1, capBal);

        if (wrapper.currentNonce() < target) {
            vm.expectRevert(IERC8056PairWrapper.Locked.selector);
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
        soloRedemptions++;
    }

    function applyYieldDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        vm.prank(owner);
        underlying.applyUIMultiplierDelta(UIScalingClass.Yield, delta, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function applySupplyDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        vm.prank(owner);
        underlying.applyUIMultiplierDelta(UIScalingClass.Supply, delta, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function applyOtherDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        vm.prank(owner);
        underlying.applyUIMultiplierDelta(UIScalingClass.Other, delta, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }
}
