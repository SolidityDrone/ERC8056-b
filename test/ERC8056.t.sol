// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC8056} from "../src/ERC8056.sol";
import {IERC8056} from "../src/interfaces/base/IERC8056.sol";
import {IERC8056NewUIMultiplier} from "../src/interfaces/base/IERC8056NewUIMultiplier.sol";
import {IERC8056Cancel} from "../src/interfaces/base/IERC8056Cancel.sol";

contract ERC8056Test is Test {
    ERC8056 internal token;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    uint256 internal constant MULTIPLIER_DECIMALS = 1e18;

    function setUp() public {
        token = new ERC8056("Scaled UI Token", "SUI", owner);
        vm.prank(owner);
        token.mint(alice, 100 ether);
    }

    function test_initialMultiplierIsOne() public view {
        assertEq(token.uiMultiplier(), MULTIPLIER_DECIMALS);
        assertEq(token.balanceOf(alice), token.balanceOfUI(alice));
    }

    function test_supportsInterface() public view {
        assertTrue(token.supportsInterface(type(IERC8056).interfaceId));
        assertTrue(token.supportsInterface(0xa60bf13d));
        assertTrue(token.supportsInterface(0x4bd27648));
        assertTrue(token.supportsInterface(type(IERC8056Cancel).interfaceId));
        assertTrue(token.supportsInterface(0x57854fc3));
        assertTrue(token.supportsInterface(0xd890fd71));
        // The pre-fix drifted ID (spec ID XOR cancel selector) must no longer be advertised
        assertFalse(token.supportsInterface(0xb80fdcb6));
    }

    function test_SpecInterfaceID_Preserved() public pure {
        // EIP-8056 mandates IScaledUIAmountNewUIMultiplier = 0x4bd27648
        assertEq(type(IERC8056NewUIMultiplier).interfaceId, bytes4(0x4bd27648));
    }

    function test_CancelInterfaceID_Exposed() public view {
        assertTrue(token.supportsInterface(type(IERC8056Cancel).interfaceId));
    }

    function test_stockSplitDoublesUIBalance() public {
        uint256 effectiveAt = block.timestamp + 1 days;

        vm.prank(owner);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, effectiveAt);

        assertEq(token.newUIMultiplier(), 2 * MULTIPLIER_DECIMALS);
        assertEq(token.effectiveAt(), effectiveAt);
        assertEq(token.uiMultiplier(), MULTIPLIER_DECIMALS);

        vm.warp(effectiveAt);

        assertEq(token.uiMultiplier(), 2 * MULTIPLIER_DECIMALS);
        assertEq(token.balanceOfUI(alice), 200 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_conversionFunctions() public {
        uint256 effectiveAt = block.timestamp + 1 hours;

        vm.prank(owner);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.toUIAmount(50 ether), 100 ether);
        assertEq(token.fromUIAmount(100 ether), 50 ether);
        assertEq(token.totalSupplyUI(), token.toUIAmount(token.totalSupply()));
    }

    function test_transferEmitsTransferWithUIAmount() public {
        address bob = makeAddr("bob");

        vm.expectEmit(true, true, true, true);
        emit IERC8056.TransferWithUIAmount(alice, bob, 10 ether, 10 ether);

        vm.prank(alice);
        bool ok = token.transfer(bob, 10 ether);
        assertTrue(ok);
    }

    function test_revertWhenMultiplierNotPositive() public {
        vm.prank(owner);
        vm.expectRevert(ERC8056.ZeroMultiplier.selector);
        token.setUIMultiplier(0, block.timestamp + 1);
    }

    function test_revertWhenEffectiveAtNotInFuture() public {
        vm.prank(owner);
        vm.expectRevert(ERC8056.EffectiveAtNotInFuture.selector);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, block.timestamp);
    }

    // ---- Cancel tests ----

    function test_cancelRestoresPreviousMultiplier() public {
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, effectiveAt);

        assertEq(token.newUIMultiplier(), 2 * MULTIPLIER_DECIMALS);
        assertEq(token.effectiveAt(), effectiveAt);

        vm.prank(owner);
        token.cancelPendingUIMultiplier();

        assertEq(token.newUIMultiplier(), MULTIPLIER_DECIMALS);
        assertEq(token.effectiveAt(), 0);
        assertEq(token.uiMultiplier(), MULTIPLIER_DECIMALS);
    }

    function test_cancelEmitsEvent() public {
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, effectiveAt);

        vm.expectEmit(true, true, true, true);
        emit IERC8056Cancel.UIMultiplierCancelled(
            2 * MULTIPLIER_DECIMALS, MULTIPLIER_DECIMALS, block.timestamp
        );

        vm.prank(owner);
        token.cancelPendingUIMultiplier();
    }

    function test_revertWhenCancelNothingPending() public {
        vm.prank(owner);
        vm.expectRevert(ERC8056.NothingToCancel.selector);
        token.cancelPendingUIMultiplier();
    }

    function test_revertWhenCancelAfterEffective() public {
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, effectiveAt);

        vm.warp(effectiveAt);

        vm.prank(owner);
        vm.expectRevert(ERC8056.NothingToCancel.selector);
        token.cancelPendingUIMultiplier();
    }

    function test_cancelAllowsNewSchedule() public {
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, effectiveAt);

        vm.prank(owner);
        token.cancelPendingUIMultiplier();

        uint256 newEffectiveAt = block.timestamp + 2 days;
        vm.prank(owner);
        token.setUIMultiplier(3 * MULTIPLIER_DECIMALS, newEffectiveAt);

        assertEq(token.newUIMultiplier(), 3 * MULTIPLIER_DECIMALS);
        assertEq(token.effectiveAt(), newEffectiveAt);
    }
}
