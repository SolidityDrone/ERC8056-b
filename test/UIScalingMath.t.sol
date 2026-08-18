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

    function test_composeFactors_neutralSupplyYield() public view {
        uint256[] memory factors = _supplyYieldFactors(NEUTRAL, NEUTRAL);
        assertEq(harness.composeFactors(factors), NEUTRAL);
    }

    function test_composeFactors_orderIndependent() public view {
        uint256[] memory supplyFirst = _supplyYieldFactors(DOUBLE, 3e18);
        uint256[] memory yieldFirst = _supplyYieldFactors(3e18, DOUBLE);
        assertEq(harness.composeFactors(supplyFirst), harness.composeFactors(yieldFirst));
        assertEq(harness.composeFactors(supplyFirst), 6e18);
    }

    function test_composeSupplyYield() public pure {
        assertEq(UIScalingMath.composeSupplyYield(DOUBLE, 1.5e18), 3e18);
    }

    function test_composeFactors_revertsOnZero() public {
        uint256[] memory factors = _supplyYieldFactors(NEUTRAL, 0);
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

    function _supplyYieldFactors(uint256 supplyFactor, uint256 yieldFactor)
        private
        pure
        returns (uint256[] memory factors)
    {
        factors = new uint256[](2);
        factors[0] = supplyFactor;
        factors[1] = yieldFactor;
    }
}
