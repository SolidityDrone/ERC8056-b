// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC8056TokenClasses} from "../src/ERC8056TokenClasses.sol";
import {ERC8056PairWrapper} from "../src/ERC8056PairWrapper.sol";
import {ERC8056PairWrapperRegistry} from "../src/ERC8056PairWrapperRegistry.sol";
import {IERC8056PairWrapper} from "../src/interfaces/IERC8056PairWrapper.sol";
import {IERC8056PairWrapperRegistry} from "../src/interfaces/IERC8056PairWrapperRegistry.sol";

contract ERC8056PairWrapperRegistryTest is ScalingTestBase {
    ERC8056TokenClasses internal underlying;
    ERC8056TokenClasses internal underlyingB;
    ERC8056PairWrapperRegistry internal registry;

    address internal owner = makeAddr("owner");

    function setUp() public {
        underlying = new ERC8056TokenClasses("Stock", "STK", owner);
        underlyingB = new ERC8056TokenClasses("Bond", "BND", owner);
        registry = new ERC8056PairWrapperRegistry();
    }

    function test_DeployOrGet_CreatesCanonicalSingleton() public {
        IERC8056PairWrapper w1 = registry.deployOrGet(IERC20(address(underlying)), underlying, "Tesla", "Tesla");
        IERC8056PairWrapper w2 = registry.deployOrGet(IERC20(address(underlying)), underlying, "Tesla", "Tesla");

        assertTrue(address(w1) != address(0), "deployed non-zero");
        assertEq(address(w1), address(w2), "singleton per underlying");
        assertEq(address(registry.wrapperFor(IERC20(address(underlying)))), address(w1), "wrapperFor matches");
    }

    function test_DeployOrGet_KeysByIdentity_NotMetadata() public {
        IERC8056PairWrapper w1 = registry.deployOrGet(IERC20(address(underlying)), underlying, "NameA", "SymA");
        IERC8056PairWrapper w2 = registry.deployOrGet(IERC20(address(underlying)), underlying, "NameB", "SymB");

        assertEq(address(w1), address(w2), "metadata ignored on repeat call");
    }

    function test_DeployOrGet_DistinctPerUnderlying() public {
        IERC8056PairWrapper wa = registry.deployOrGet(IERC20(address(underlying)), underlying, "A", "A");
        IERC8056PairWrapper wb = registry.deployOrGet(IERC20(address(underlyingB)), underlyingB, "B", "B");

        assertTrue(address(wa) != address(wb), "distinct wrappers for distinct underlyings");
        assertEq(registry.wrapperCount(), 2, "count enumerates both");
    }

    function test_WrapperFor_ZeroBeforeRegistration() public {
        assertEq(address(registry.wrapperFor(IERC20(address(underlying)))), address(0), "zero before deploy");
    }

    function test_Enumeration() public {
        registry.deployOrGet(IERC20(address(underlying)), underlying, "A", "A");
        registry.deployOrGet(IERC20(address(underlyingB)), underlyingB, "B", "B");

        assertEq(registry.wrapperCount(), 2, "count");
        assertEq(address(registry.wrapperAt(0)), address(registry.wrapperFor(IERC20(address(underlying)))), "at0");
        assertEq(address(registry.wrapperAt(1)), address(registry.wrapperFor(IERC20(address(underlyingB)))), "at1");
    }

    function test_UnderlyingOf_ReverseLookup() public {
        IERC8056PairWrapper w = registry.deployOrGet(IERC20(address(underlying)), underlying, "A", "A");
        assertEq(address(registry.underlyingOf(w)), address(underlying), "reverse maps back");
    }

    function test_DeployOrGet_ValidatesExtensionViaERC165() public {
        IERC20 bogusUnderlying = IERC20(address(new BogusToken("Bogus", "BOG")));
        ERC8056TokenClasses bogusExtension = ERC8056TokenClasses(address(new BogusExtension()));
        vm.expectRevert(ERC8056PairWrapperRegistry.UnsupportedExtension.selector);
        registry.deployOrGet(bogusUnderlying, bogusExtension, "B", "B");
    }

    function test_DeployedWrapper_IsUsable() public {
        IERC8056PairWrapper w = registry.deployOrGet(IERC20(address(underlying)), underlying, "Tesla", "Tesla");

        vm.prank(owner);
        underlying.mint(address(this), RAW_STAKE);
        underlying.approve(address(w), type(uint256).max);

        (uint256 start, uint256 target) = w.wrap(RAW_STAKE, 1);
        assertGt(target, start, "wrapped through registry wrapper");

        assertEq(address(w.capitalToken(start, target)), address(w.pairs(start, target).capital), "token getter");
        assertEq(w.rawLockedOf(start, target), RAW_STAKE, "rawLockedOf equals staked");
    }
}

/// @dev A plain ERC20 with no ERC-165 support, used as a bogus scaledUnderlying.
contract BogusToken {
    string public name;
    string public symbol;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }
}

/// @dev A contract that does not implement IERC8056TokenClasses (no supportsInterface).
contract BogusExtension {}
