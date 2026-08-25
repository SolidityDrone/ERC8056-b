// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {UIScalingMath} from "../src/libraries/UIScalingMath.sol";

/// @dev External harness so `vm.expectRevert` can intercept internal-library reverts.
contract UIScalingMathHarness {
    function composeUiMultiplier(uint256 supplyFactor, uint256 yieldFactor, uint256 otherFactor)
        external
        pure
        returns (uint256)
    {
        return UIScalingMath.composeUiMultiplier(supplyFactor, yieldFactor, otherFactor);
    }
}

contract UIScalingMathTest is ScalingTestBase {
    UIScalingMathHarness internal harness;

    function setUp() public {
        harness = new UIScalingMathHarness();
    }

    function test_composeUiMultiplier_neutralAllClasses() public pure {
        assertEq(UIScalingMath.composeUiMultiplier(NEUTRAL, NEUTRAL, NEUTRAL), NEUTRAL);
    }

    function test_composeUiMultiplier_orderIndependent() public pure {
        assertEq(
            UIScalingMath.composeUiMultiplier(DOUBLE, 3e18, 1.5e18), UIScalingMath.composeUiMultiplier(1.5e18, DOUBLE, 3e18)
        );
        assertEq(
            UIScalingMath.composeUiMultiplier(DOUBLE, 3e18, 1.5e18), UIScalingMath.composeUiMultiplier(3e18, 1.5e18, DOUBLE)
        );
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 3e18, 1.5e18), 9e18);
    }

    function test_composeUiMultiplier() public pure {
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 1.5e18, 3e18), 9e18);
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 1.5e18, NEUTRAL), 3e18);
    }

    function test_composeUiMultiplier_neutralOther() public pure {
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 1.5e18, NEUTRAL), 3e18);
    }

    function test_composeUiMultiplier_revertsOnZero() public {
        vm.expectRevert(UIScalingMath.ZeroFactor.selector);
        harness.composeUiMultiplier(NEUTRAL, 0, NEUTRAL);
    }

    function test_toUIAmount_roundTrip() public pure {
        uint256 composite = 4e18;
        assertEq(UIScalingMath.toUIAmount(RAW_STAKE, composite), 400 ether);
        assertEq(UIScalingMath.fromUIAmount(400 ether, composite), RAW_STAKE);
    }

    function test_capitalRaw_yieldAccretionOnly() public pure {
        assertEq(UIScalingMath.capitalRaw(RAW_STAKE, NEUTRAL, DOUBLE), 50 ether);
        assertEq(UIScalingMath.yieldLegRaw(RAW_STAKE, 50 ether), 50 ether);
    }

    function test_capitalRaw_supplyNeutral() public pure {
        assertEq(UIScalingMath.capitalRaw(RAW_STAKE, NEUTRAL, NEUTRAL), RAW_STAKE);
        assertEq(UIScalingMath.yieldLegRaw(RAW_STAKE, RAW_STAKE), 0);
    }

    function test_yieldGrowthSinceStake() public pure {
        assertEq(UIScalingMath.yieldGrowthSinceStake(NEUTRAL, 3e18), 3e18);
    }

    /// @dev Principal protection: when the yield factor decreased since stake,
    ///      capitalRaw exceeds rawStaked and the yield leg must saturate to 0
    ///      instead of panicking on underflow.
    function test_yieldLegRaw_saturatesToZeroWhenYieldFactorDecreased() public pure {
        // capitalRaw = 100e18 * 2e18 / 1e18 = 200e18 > rawStaked
        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, DOUBLE, NEUTRAL);
        assertEq(capital, 200 ether);
        assertEq(UIScalingMath.yieldLegRaw(RAW_STAKE, capital), 0);
    }
}
