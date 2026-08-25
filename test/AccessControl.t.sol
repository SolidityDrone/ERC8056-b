// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC8056} from "../src/ERC8056.sol";
import {ERC8056Composite} from "../src/ERC8056Composite.sol";
import {MultiplierClass} from "../src/interfaces/extension/IERC8056MultiplierClass.sol";
import {LegToken} from "../src/wrapper/LegToken.sol";

/// @dev Negative access-control coverage: every privileged entry point must
///      revert for non-owners with OZ's OwnableUnauthorizedAccount, and LegToken
///      mint/burn must revert Unauthorized for any caller other than the minter.
contract AccessControlTest is Test {
    ERC8056 internal vanilla;
    ERC8056Composite internal composite;
    LegToken internal leg;

    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant MULTIPLIER_DECIMALS = 1e18;

    function setUp() public {
        vanilla = new ERC8056("Vanilla", "VNL", owner);
        composite = new ERC8056Composite("Composite", "CMP", owner);
        leg = new LegToken("Capital-X", "CapX", address(this), 18);
    }

    function _expectOnlyOwner(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    //==========================================================================//
    // Vanilla ERC8056                                                           //
    //==========================================================================//

    function test_vanilla_mint_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        vanilla.mint(attacker, 100 ether);
    }

    function test_vanilla_setUIMultiplier_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        vanilla.setUIMultiplier(2 * MULTIPLIER_DECIMALS, block.timestamp + 1 days);
    }

    function test_vanilla_cancelPendingUIMultiplier_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        vanilla.cancelPendingUIMultiplier();
    }

    //==========================================================================//
    // Composite                                                                 //
    //==========================================================================//

    function test_composite_mint_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        composite.mint(attacker, 100 ether);
    }

    /// @dev Legacy 2-arg setter delegates to Supply but keeps onlyOwner.
    function test_composite_setUIMultiplier_legacy_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        composite.setUIMultiplier(2 * MULTIPLIER_DECIMALS, block.timestamp + 1 days);
    }

    function test_composite_setUIMultiplier_classed_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        composite.setUIMultiplier(
            MultiplierClass.Yield, 2 * MULTIPLIER_DECIMALS, block.timestamp + 1 days, "", "", ""
        );
    }

    function test_composite_cancelPendingUIMultiplier_noArg_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        composite.cancelPendingUIMultiplier();
    }

    function test_composite_cancelPendingUIMultiplier_classed_revertsForNonOwner() public {
        _expectOnlyOwner(attacker);
        vm.prank(attacker);
        composite.cancelPendingUIMultiplier(MultiplierClass.Supply);
    }

    //==========================================================================//
    // LegToken                                                                  //
    //==========================================================================//

    function test_legToken_mint_revertsForNonMinter() public {
        vm.expectRevert(LegToken.Unauthorized.selector);
        vm.prank(attacker);
        leg.mint(attacker, 100 ether);
    }

    function test_legToken_burn_revertsForNonMinter() public {
        leg.mint(owner, 100 ether);
        vm.expectRevert(LegToken.Unauthorized.selector);
        vm.prank(attacker);
        leg.burn(owner, 100 ether);
    }
}
