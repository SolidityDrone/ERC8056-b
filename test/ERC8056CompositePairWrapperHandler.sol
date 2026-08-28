// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC8056CompositePairWrapper} from "../src/token-side/ERC8056CompositePairWrapper.sol";
import {IERC8056PairWrapper} from "../src/interfaces/wrapper/IERC8056PairWrapper.sol";
import {MultiplierClass} from "../src/interfaces/extension/IERC8056MultiplierClass.sol";

/// @dev Action handler for the token-side wrapper invariant suite. Every
///      entrypoint either performs an operation or reverts; asserts inside
///      handlers fail the suite.
///
///      Port of ERC8056PairWrapperHandler: the handler drives ONE contract (the
///      composite token, which IS the pair wrapper) via IERC8056PairWrapper.
///      Wrap self-escrows, so the mint + wrap flow needs no approval ceremony.
contract ERC8056CompositePairWrapperHandler is Test {
    ERC8056CompositePairWrapper public immutable token;
    address public immutable owner;

    uint256 public totalDeposited;
    uint256 public totalRedeemed;
    uint256 public soloRedemptions;

    constructor(ERC8056CompositePairWrapper token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    function _actor(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("actor", seed % 8)))));
    }

    function _randomPair(uint256 seed) internal view returns (uint256 start, uint256 target, bool exists) {
        uint256 count = token.pairCount();
        if (count == 0) return (0, 0, false);
        (start, target) = token.pairAt(bound(seed, 0, count - 1));
        exists = true;
    }

    function wrap(uint256 seed, uint256 amountSeed, uint256 lockSeed) external {
        address actor = _actor(seed);
        uint256 amount = bound(amountSeed, 1, 10_000 ether);
        uint256 lockNonces = bound(lockSeed, 0, 6);

        vm.prank(owner);
        token.mint(actor, amount);
        vm.prank(actor);
        token.wrap(amount, lockNonces);

        totalDeposited += amount;
    }

    function unwrap(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 capBal = token.pairs(start, target).capital.balanceOf(actor);
        uint256 yldBal = token.pairs(start, target).yield.balanceOf(actor);
        uint256 maxAmount = capBal < yldBal ? capBal : yldBal;
        if (maxAmount == 0) return;
        uint256 amount = bound(amountSeed, 1, maxAmount);

        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        token.unwrap(amount, start, target);
        assertEq(token.balanceOf(actor) - before, amount, "equal-leg pays exactly amount");
        totalRedeemed += amount;
    }

    function unwrapYield(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 yldBal = token.pairs(start, target).yield.balanceOf(actor);
        if (yldBal == 0) return;
        uint256 amount = bound(amountSeed, 1, yldBal);

        if (token.currentNonce() < target) {
            vm.expectRevert(IERC8056PairWrapper.Locked.selector);
            vm.prank(actor);
            token.unwrapYield(amount, start, target);
            return;
        }
        uint256 expected = Math.mulDiv(amount, token.couponOf(start, target), 1e18);
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        token.unwrapYield(amount, start, target);
        assertEq(token.balanceOf(actor) - before, expected, "yield pays frozen coupon");
        totalRedeemed += expected;
        soloRedemptions++;
    }

    function unwrapCapital(uint256 seed, uint256 pairSeed, uint256 amountSeed) external {
        address actor = _actor(seed);
        (uint256 start, uint256 target, bool exists) = _randomPair(pairSeed);
        if (!exists) return;
        uint256 capBal = token.pairs(start, target).capital.balanceOf(actor);
        if (capBal == 0) return;
        uint256 amount = bound(amountSeed, 1, capBal);

        if (token.currentNonce() < target) {
            vm.expectRevert(IERC8056PairWrapper.Locked.selector);
            vm.prank(actor);
            token.unwrapCapital(amount, start, target);
            return;
        }
        uint256 share = 1e18 - token.couponOf(start, target);
        uint256 expected = Math.mulDiv(amount, share, 1e18);
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        token.unwrapCapital(amount, start, target);
        assertEq(token.balanceOf(actor) - before, expected, "capital pays frozen share");
        totalRedeemed += expected;
        soloRedemptions++;
    }

    function applyYieldDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        uint256 current = token.uiScalingFactor(MultiplierClass.Yield);
        uint256 newMultiplier = Math.mulDiv(current, delta, 1e18);
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function applySupplyDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        uint256 current = token.uiScalingFactor(MultiplierClass.Supply);
        uint256 newMultiplier = Math.mulDiv(current, delta, 1e18);
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }

    function applyOtherDelta(uint256 deltaSeed, uint256 delaySeed) external {
        uint256 delta = bound(deltaSeed, 5e17, 2e18);
        uint256 delay = bound(delaySeed, 1, 3 days);
        uint256 current = token.uiScalingFactor(MultiplierClass.Other);
        uint256 newMultiplier = Math.mulDiv(current, delta, 1e18);
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Other, newMultiplier, block.timestamp + delay, "", "", "");
        vm.warp(block.timestamp + delay);
    }
}
