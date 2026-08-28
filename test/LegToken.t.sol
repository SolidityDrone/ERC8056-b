// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LegToken} from "../src/LegToken.sol";

/// @dev Dedicated LegToken suite: metadata, decimals, minter immutability and
///      authorization, plus standard ERC20 behaviors the wrapper relies on.
contract LegTokenTest is Test {
    LegToken internal token;
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new LegToken("Capital-W0", "CapW0", minter, 6);
    }

    //==========================================================================//
    // Metadata & immutability                                                   //
    //==========================================================================//

    function test_metadata_fromConstructor() public view {
        assertEq(token.name(), "Capital-W0");
        assertEq(token.symbol(), "CapW0");
        assertEq(token.decimals(), 6);
    }

    function test_minter_immutable() public view {
        assertEq(token.minter(), minter);
    }

    function test_decimals_independentOfConstructorOrder() public {
        LegToken other = new LegToken("Yield-W1", "YldW1", minter, 8);
        assertEq(other.decimals(), 8);
        assertEq(other.symbol(), "YldW1");
    }

    //==========================================================================//
    // Authorization                                                             //
    //==========================================================================//

    function test_mint_byNonMinter_reverts() public {
        vm.expectRevert(LegToken.Unauthorized.selector);
        vm.prank(alice);
        token.mint(alice, 100e6);
    }

    function test_burn_byNonMinter_reverts() public {
        vm.prank(minter);
        token.mint(alice, 100e6);
        vm.expectRevert(LegToken.Unauthorized.selector);
        vm.prank(alice);
        token.burn(alice, 100e6);
    }

    function test_mint_burn_byMinter_succeeds() public {
        vm.startPrank(minter);
        token.mint(alice, 100e6);
        assertEq(token.balanceOf(alice), 100e6);
        assertEq(token.totalSupply(), 100e6);
        token.burn(alice, 40e6);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 60e6);
        assertEq(token.totalSupply(), 60e6);
    }

    //==========================================================================//
    // Standard ERC20 behaviors                                                  //
    //==========================================================================//

    function test_transfer_updatesBalancesAndAllowanceFlow() public {
        vm.prank(minter);
        token.mint(alice, 100e6);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 30e6));
        assertEq(token.balanceOf(alice), 70e6);
        assertEq(token.balanceOf(bob), 30e6);
    }

    function test_approve_andTransferFrom() public {
        vm.prank(minter);
        token.mint(alice, 100e6);

        vm.prank(alice);
        assertTrue(token.approve(bob, 50e6));
        assertEq(token.allowance(alice, bob), 50e6);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 20e6));
        assertEq(token.allowance(alice, bob), 30e6);
        assertEq(token.balanceOf(alice), 80e6);
        assertEq(token.balanceOf(bob), 20e6);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(minter);
        token.mint(alice, 10e6);
        vm.expectRevert();
        vm.prank(alice);
        bool ok = token.transfer(bob, 11e6);
        assertFalse(ok);
    }

    function test_transferFrom_revertsWithoutAllowance() public {
        vm.prank(minter);
        token.mint(alice, 10e6);
        vm.expectRevert();
        vm.prank(bob);
        bool okFrom = token.transferFrom(alice, bob, 1e6);
        assertFalse(okFrom);
    }
}
