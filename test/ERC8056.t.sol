// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC8056} from "../src/ERC8056.sol";
import {IERC8056} from "../src/extensions/interfaces/IERC8056.sol";

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
        assertTrue(token.supportsInterface(0x57854fc3));
        assertTrue(token.supportsInterface(0xd890fd71));
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
        token.transfer(bob, 10 ether);
    }

    function test_revertWhenMultiplierNotPositive() public {
        vm.prank(owner);
        vm.expectRevert("Multiplier must be positive");
        token.setUIMultiplier(0, block.timestamp + 1);
    }

    function test_revertWhenEffectiveAtNotInFuture() public {
        vm.prank(owner);
        vm.expectRevert("Effective At must be in the future");
        token.setUIMultiplier(2 * MULTIPLIER_DECIMALS, block.timestamp);
    }
}
