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
            UIScalingMath.composeUiMultiplier(DOUBLE, 3e18, 1.5e18),
            UIScalingMath.composeUiMultiplier(1.5e18, DOUBLE, 3e18)
        );
        assertEq(
            UIScalingMath.composeUiMultiplier(DOUBLE, 3e18, 1.5e18),
            UIScalingMath.composeUiMultiplier(3e18, 1.5e18, DOUBLE)
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

    /// @dev Principal protection done right: when the yield factor decreased
    ///      since stake, the capital leg is CLAMPED to the staked amount (not
    ///      inflated above it) and the yield leg saturates to 0, so the legs
    ///      always conserve the deposit exactly.
    function test_capitalRaw_clampsToStakeWhenYieldFactorDecreased() public pure {
        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, DOUBLE, NEUTRAL);
        assertEq(capital, RAW_STAKE, "capital must never exceed the stake");
        assertEq(UIScalingMath.yieldLegRaw(RAW_STAKE, capital), 0);
    }

    function test_yieldGrowthSinceStake() public pure {
        assertEq(UIScalingMath.yieldGrowthSinceStake(NEUTRAL, 3e18), 3e18);
    }

    /// @dev Principal protection: when the yield factor decreased since stake,
    ///      the capital leg is clamped to the stake and the yield leg saturates
    ///      to 0 instead of panicking on underflow.
    function test_yieldLegRaw_saturatesToZeroWhenYieldFactorDecreased() public pure {
        // pre-clamp would give 100e18 * 2e18 / 1e18 = 200e18 > rawStaked;
        // clamped so that capital + yield always conserves the deposit.
        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, DOUBLE, NEUTRAL);
        assertEq(capital, RAW_STAKE);
        assertEq(UIScalingMath.yieldLegRaw(RAW_STAKE, capital), 0);
    }

    //==========================================================================//
    // Fuzz                                                                      //
    //==========================================================================//

    uint256 internal constant MIN_FACTOR = 1e18;
    uint256 internal constant MAX_FACTOR = 1e30;

    /// @dev composeUiMultiplier must be order-independent. Each sequential
    ///      mulDiv floors its intermediate, and one unit lost mid-pipeline is
    ///      amplified by the remaining factors (<= 1e30 / 1e18 per step), so
    ///      permutations may drift by a few trillionths of the smallest result.
    function testFuzz_composeUiMultiplier_orderIndependent(uint256 a, uint256 b, uint256 c) public pure {
        a = bound(a, MIN_FACTOR, MAX_FACTOR);
        b = bound(b, MIN_FACTOR, MAX_FACTOR);
        c = bound(c, MIN_FACTOR, MAX_FACTOR);

        // two floored intermediates can each contribute <= MAX_FACTOR/N of drift
        uint256 slack = 2 * (MAX_FACTOR / NEUTRAL) + 2;

        uint256 abc = UIScalingMath.composeUiMultiplier(a, b, c);
        assertApproxEqAbs(abc, UIScalingMath.composeUiMultiplier(a, c, b), slack);
        assertApproxEqAbs(abc, UIScalingMath.composeUiMultiplier(b, a, c), slack);
        assertApproxEqAbs(abc, UIScalingMath.composeUiMultiplier(b, c, a), slack);
        assertApproxEqAbs(abc, UIScalingMath.composeUiMultiplier(c, a, b), slack);
        assertApproxEqAbs(abc, UIScalingMath.composeUiMultiplier(c, b, a), slack);

        // monotone in each argument
        assertGe(abc, UIScalingMath.composeUiMultiplier(MIN_FACTOR, MIN_FACTOR, MIN_FACTOR));
    }

    /// @dev When the yield factor grew since stake (current >= atStake), the
    ///      capital leg can never exceed the stake and the legs must conserve
    ///      capitalRaw + yieldLegRaw == rawStaked exactly.
    function testFuzz_legConservation_whenYieldGrew(uint256 rawStaked, uint256 factorAtStake, uint256 growth)
        public
        pure
    {
        rawStaked = bound(rawStaked, 0, 1e30);
        factorAtStake = bound(factorAtStake, MIN_FACTOR, MAX_FACTOR);
        growth = bound(growth, 0, MAX_FACTOR - MIN_FACTOR);
        uint256 factorCurrent = factorAtStake + growth;

        uint256 capital = UIScalingMath.capitalRaw(rawStaked, factorAtStake, factorCurrent);
        assertLe(capital, rawStaked, "capital exceeds stake when yield grew");

        uint256 yieldLeg = UIScalingMath.yieldLegRaw(rawStaked, capital);
        assertEq(yieldLeg, rawStaked - capital, "yield leg is not the exact remainder");
        assertEq(capital + yieldLeg, rawStaked, "legs do not conserve the staked amount");
    }

    /// @dev Legs must conserve the stake in EVERY direction — including yield
    ///      decreases (reverse events), where an unclamped capital leg would
    ///      claim more than was deposited (economically unsound split).
    function testFuzz_legConservation_anyDirection(uint256 rawStaked, uint256 fS, uint256 fC) public pure {
        rawStaked = bound(rawStaked, 0, 1e30);
        fS = bound(fS, MIN_FACTOR, MAX_FACTOR);
        fC = bound(fC, MIN_FACTOR, MAX_FACTOR);

        uint256 capital = UIScalingMath.capitalRaw(rawStaked, fS, fC);
        uint256 yieldLeg = UIScalingMath.yieldLegRaw(rawStaked, capital);

        assertLe(capital, rawStaked, "capital exceeds stake");
        assertEq(capital + yieldLeg, rawStaked, "legs do not conserve the staked amount");

        // and in the reversed-time direction too
        uint256 swappedCapital = UIScalingMath.capitalRaw(rawStaked, fC, fS);
        assertLe(swappedCapital, rawStaked, "reversed capital exceeds stake");
        assertEq(swappedCapital + UIScalingMath.yieldLegRaw(rawStaked, swappedCapital), rawStaked);
    }

    /// @dev toUIAmount -> fromUIAmount must recover the raw amount within 1 wei
    ///      for any neutral-or-higher factor (rounding only ever rounds down).
    function testFuzz_conversion_roundTrip(uint256 rawAmount, uint256 factor) public pure {
        rawAmount = bound(rawAmount, 0, type(uint128).max);
        factor = bound(factor, MIN_FACTOR, MAX_FACTOR);

        uint256 ui = UIScalingMath.toUIAmount(rawAmount, factor);
        assertGe(ui, rawAmount, "UI amount below raw for factor >= 1e18");

        uint256 roundTripped = UIScalingMath.fromUIAmount(ui, factor);
        assertLe(roundTripped, rawAmount, "round trip inflated the raw amount");
        if (rawAmount > 0) {
            assertGe(roundTripped, rawAmount - 1, "round trip lost more than 1 wei");
        }
    }
}
