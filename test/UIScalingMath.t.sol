// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {UIScalingMath} from "../src/libraries/UIScalingMath.sol";

contract UIScalingMathHarness {
    function composeFactors(uint256[] memory factors) external pure returns (uint256) {
        return UIScalingMath.composeFactors(factors);
    }
}

contract UIScalingMathTest is ScalingTestBase {
    UIScalingMathHarness internal harness;

    function setUp() public {
        harness = new UIScalingMathHarness();
    }

    function test_composeFactors_neutralAllClasses() public view {
        uint256[] memory factors = _classFactors(NEUTRAL, NEUTRAL, NEUTRAL);
        assertEq(harness.composeFactors(factors), NEUTRAL);
    }

    function test_composeFactors_orderIndependent() public view {
        uint256[] memory supplyFirst = _classFactors(DOUBLE, 3e18, 1.5e18);
        uint256[] memory yieldFirst = _classFactors(1.5e18, DOUBLE, 3e18);
        uint256[] memory otherFirst = _classFactors(3e18, 1.5e18, DOUBLE);
        assertEq(harness.composeFactors(supplyFirst), harness.composeFactors(yieldFirst));
        assertEq(harness.composeFactors(supplyFirst), harness.composeFactors(otherFirst));
        assertEq(harness.composeFactors(supplyFirst), 9e18);
    }

    function test_composeUiMultiplier() public pure {
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 1.5e18, 3e18), 9e18);
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 1.5e18, NEUTRAL), 3e18);
    }

    function test_composeUiMultiplier_neutralOther() public pure {
        assertEq(UIScalingMath.composeUiMultiplier(DOUBLE, 1.5e18, NEUTRAL), 3e18);
    }

    function test_composeFactors_revertsOnZero() public {
        uint256[] memory factors = _classFactors(NEUTRAL, 0, NEUTRAL);
        vm.expectRevert(UIScalingMath.ZeroFactor.selector);
        harness.composeFactors(factors);
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

    function _classFactors(uint256 supplyFactor, uint256 yieldFactor, uint256 otherFactor)
        private
        pure
        returns (uint256[] memory factors)
    {
        factors = new uint256[](3);
        factors[0] = supplyFactor;
        factors[1] = yieldFactor;
        factors[2] = otherFactor;
    }
}
