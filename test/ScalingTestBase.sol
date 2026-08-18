// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UIScalingMath} from "../src/libraries/UIScalingMath.sol";

/// @dev Shared constants and helpers for scaling tests.
abstract contract ScalingTestBase is Test {
    uint256 internal constant NEUTRAL = UIScalingMath.MULTIPLIER_DECIMALS;
    uint256 internal constant DOUBLE = 2e18;
    uint256 internal constant HALF = 0.5e18;

    uint256 internal constant RAW_STAKE = 100 ether;
}
