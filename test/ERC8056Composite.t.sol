// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056Composite} from "../src/extensions/ERC8056Composite.sol";
import {IERC8056Composite} from "../src/extensions/interfaces/IERC8056Composite.sol";
import {UIScalingClass} from "../src/extensions/interfaces/UIScalingClass.sol";
import {UIScalingMath} from "../src/libraries/UIScalingMath.sol";

contract ERC8056CompositeTest is ScalingTestBase {
    ERC8056Composite internal token;
    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");

    function setUp() public {
        token = new ERC8056Composite("Classed UI Token", "CUI", owner);
        vm.prank(owner);
        token.mint(holder, RAW_STAKE);
    }

    function _scheduleScalingDelta(UIScalingClass scalingClass, uint256 factorDelta, uint256 delay)
        internal
        returns (uint256 effectiveAt)
    {
        effectiveAt = block.timestamp + delay;
        vm.prank(owner);
        token.applyUIMultiplierDelta(scalingClass, factorDelta, effectiveAt, "", "", "");
    }

    function _warpToEffective(uint256 effectiveAt) internal {
        vm.warp(effectiveAt);
    }

    //==============================================================================//
    // Initial state                                                                //
    //==============================================================================//
    function test_initial_neutralAllClasses() public view {
        assertEq(token.uiScalingFactor(UIScalingClass.Supply), NEUTRAL);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), NEUTRAL);
        assertEq(token.uiScalingFactor(UIScalingClass.Other), NEUTRAL);
        assertEq(token.uiMultiplier(), NEUTRAL);
        assertEq(token.balanceOfUI(holder), RAW_STAKE);
        assertEq(token.scalingHistoryLength(UIScalingClass.Supply), 1);
        assertEq(token.scalingHistoryLength(UIScalingClass.Yield), 1);
        assertEq(token.scalingHistoryLength(UIScalingClass.Other), 1);
    }

    function test_initial_genesisCheckpoint() public view {
        IERC8056Composite.ScalingCheckpoint memory genesis = token.scalingCheckpointAt(UIScalingClass.Supply, 0);
        assertEq(genesis.effectiveAt, 0);
        assertEq(genesis.cumulativeFactor, NEUTRAL);

        IERC8056Composite.ScalingCheckpoint memory genesisOther = token.scalingCheckpointAt(UIScalingClass.Other, 0);
        assertEq(genesisOther.effectiveAt, 0);
        assertEq(genesisOther.cumulativeFactor, NEUTRAL);
    }

    function test_initial_supportsClassedInterface() public view {
        assertTrue(token.supportsInterface(type(IERC8056Composite).interfaceId));
    }

    //==============================================================================//
    // Order independence                                                           //
    //==============================================================================//
    function test_orderIndependence_yieldThenSupply() public {
        uint256 tYield = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 hours);
        uint256 tSupply = _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 2 hours);

        _warpToEffective(tYield);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), DOUBLE);
        assertEq(token.uiMultiplier(), DOUBLE);

        _warpToEffective(tSupply);
        assertEq(token.uiMultiplier(), 4e18);
        assertEq(token.balanceOfUI(holder), 400 ether);
    }

    function test_orderIndependence_supplyThenYield() public {
        uint256 tSupply = _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        uint256 tYield = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 2 hours);

        _warpToEffective(tSupply);
        assertEq(token.uiScalingFactor(UIScalingClass.Supply), DOUBLE);
        assertEq(token.uiMultiplier(), DOUBLE);

        _warpToEffective(tYield);
        assertEq(token.uiMultiplier(), 4e18);
    }

    function test_orderIndependence_sameEffectiveTimestamp() public {
        uint256 effectiveAt = block.timestamp + 1 days;

        ERC8056Composite pathA = new ERC8056Composite("A", "A", owner);
        vm.startPrank(owner);
        pathA.applyUIMultiplierDelta(UIScalingClass.Yield, DOUBLE, effectiveAt, "", "", "");
        pathA.applyUIMultiplierDelta(UIScalingClass.Supply, DOUBLE, effectiveAt, "", "", "");
        vm.stopPrank();

        ERC8056Composite pathB = new ERC8056Composite("B", "B", owner);
        vm.startPrank(owner);
        pathB.applyUIMultiplierDelta(UIScalingClass.Supply, DOUBLE, effectiveAt, "", "", "");
        pathB.applyUIMultiplierDelta(UIScalingClass.Yield, DOUBLE, effectiveAt, "", "", "");
        vm.stopPrank();

        _warpToEffective(effectiveAt);
        assertEq(pathA.uiMultiplier(), pathB.uiMultiplier());
        assertEq(pathA.uiMultiplier(), 4e18);
    }

    //==============================================================================//
    // Historical lookups                                                           //
    //==============================================================================//
    function test_uiScalingFactorAt_beforeFirstUpdate() public view {
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, block.timestamp), NEUTRAL);
        assertEq(token.uiMultiplierAt(block.timestamp), NEUTRAL);
    }

    function test_uiScalingFactorAt_betweenScheduledUpdates() public {
        uint256 t0 = block.timestamp;
        uint256 tYield = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 days);
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 2 days);

        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, t0), NEUTRAL);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, tYield), DOUBLE);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Supply, tYield + 1 hours), NEUTRAL);

        _warpToEffective(tYield + 1 hours);
        assertEq(token.uiMultiplierAt(tYield), DOUBLE);
    }

    function test_uiMultiplierAt_timeline() public {
        uint256 t0 = block.timestamp;
        uint256 tYield = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 days);
        uint256 tSupply = _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 2 days);

        assertEq(token.uiMultiplierAt(t0), NEUTRAL);
        assertEq(token.uiMultiplierAt(tYield), DOUBLE);
        assertEq(token.uiMultiplierAt(tSupply), 4e18);
    }

    function test_history_appendsAndOverwritesPending() public {
        uint256 t0 = block.timestamp;
        uint256 tFirst = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 days);
        assertEq(token.scalingHistoryLength(UIScalingClass.Yield), 2);

        IERC8056Composite.ScalingCheckpoint memory first = token.scalingCheckpointAt(UIScalingClass.Yield, 1);
        assertEq(first.effectiveAt, tFirst);
        assertEq(first.cumulativeFactor, DOUBLE);

        _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 2 days);
        assertEq(token.scalingHistoryLength(UIScalingClass.Yield), 2);

        _warpToEffective(t0 + 2 days + 1 hours);
        _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 days);
        assertEq(token.scalingHistoryLength(UIScalingClass.Yield), 3);
    }

    //==============================================================================//
    // Conversion overloads                                                         //
    //==============================================================================//
    function test_toUIAmountAt_compositeHistory() public {
        uint256 tYield = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 days);
        _warpToEffective(tYield);
        assertEq(token.toUIAmountAt(RAW_STAKE, tYield - 1), RAW_STAKE);
        assertEq(token.toUIAmountAt(RAW_STAKE, tYield), 200 ether);
    }

    function test_toUIAmount_withScalingClass() public {
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.toUIAmount(RAW_STAKE, UIScalingClass.Supply), 200 ether);
        assertEq(token.toUIAmount(RAW_STAKE, UIScalingClass.Yield), RAW_STAKE);
        assertEq(token.toUIAmount(RAW_STAKE), 200 ether);
    }

    function test_toUIAmountAt_withScalingClass() public {
        uint256 tYield = _scheduleScalingDelta(UIScalingClass.Yield, 1.5e18, 1 days);
        assertEq(token.toUIAmountAt(RAW_STAKE, UIScalingClass.Yield, tYield - 1), RAW_STAKE);
        assertEq(token.toUIAmountAt(RAW_STAKE, UIScalingClass.Yield, tYield), 150 ether);
        assertEq(token.toUIAmountAt(RAW_STAKE, UIScalingClass.Supply, tYield), RAW_STAKE);
    }

    //==============================================================================//
    // Supply class                                                                 //
    //==============================================================================//
    function test_supply_reverseSplitResetsFactor() public {
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        assertEq(token.uiScalingFactor(UIScalingClass.Supply), DOUBLE);

        _scheduleScalingDelta(UIScalingClass.Supply, HALF, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        assertEq(token.uiScalingFactor(UIScalingClass.Supply), NEUTRAL);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), NEUTRAL);
    }

    function test_supply_doesNotAffectYieldFactor() public {
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), NEUTRAL);
        assertEq(token.uiScalingFactor(UIScalingClass.Supply), DOUBLE);
    }

    //==============================================================================//
    // Yield class                                                                  //
    //==============================================================================//
    function test_yield_accretionDoublesUIBalance() public {
        _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(UIScalingClass.Yield), DOUBLE);
        assertEq(token.balanceOfUI(holder), 200 ether);
        assertEq(token.balanceOf(holder), RAW_STAKE);
    }

    function test_yield_accretionAfterSupply_usesSeparateClasses() public {
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        _scheduleScalingDelta(UIScalingClass.Yield, 1.05e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(UIScalingClass.Supply), DOUBLE);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), 1.05e18);
        assertEq(token.uiMultiplier(), 2.1e18);
        assertEq(token.balanceOfUI(holder), 210 ether);
    }

    function test_yield_growthSinceStake() public {
        uint256 yieldAtStake = NEUTRAL;
        _scheduleScalingDelta(UIScalingClass.Yield, 1.5e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(UIScalingMath.yieldGrowthSinceStake(yieldAtStake, token.uiScalingFactor(UIScalingClass.Yield)), 3e18);
    }

    //==============================================================================//
    // Other class                                                                  //
    //==============================================================================//
    function test_other_composesIntoMultiplier() public {
        _scheduleScalingDelta(UIScalingClass.Other, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(UIScalingClass.Other), DOUBLE);
        assertEq(token.uiScalingFactor(UIScalingClass.Supply), NEUTRAL);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), NEUTRAL);
        assertEq(token.uiMultiplier(), DOUBLE);
        assertEq(token.balanceOfUI(holder), 200 ether);
    }

    function test_other_multipliesSupplyAndYield() public {
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        _scheduleScalingDelta(UIScalingClass.Yield, 1.5e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        _scheduleScalingDelta(UIScalingClass.Other, 3e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(UIScalingClass.Supply), DOUBLE);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), 1.5e18);
        assertEq(token.uiScalingFactor(UIScalingClass.Other), 3e18);
        assertEq(token.uiMultiplier(), 9e18);
        assertEq(token.balanceOfUI(holder), 900 ether);
    }

    function test_other_doesNotTickYieldNonce() public {
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Other, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(UIScalingClass.Yield), 0);
    }

    //==============================================================================//
    // Capital / yield leg math                                                     //
    //==============================================================================//
    function test_capitalRaw_yieldAccretionReducesPrincipal() public {
        uint256 yieldAtStake = NEUTRAL;
        _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        uint256 yieldNow = token.uiScalingFactor(UIScalingClass.Yield);
        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, yieldAtStake, yieldNow);
        uint256 yieldLeg = UIScalingMath.yieldLegRaw(RAW_STAKE, capital);

        assertEq(capital, 50 ether);
        assertEq(yieldLeg, 50 ether);
        assertEq(UIScalingMath.toUIAmount(capital, token.uiMultiplier()), RAW_STAKE);
    }

    function test_capitalRaw_supplyDoesNotReducePrincipal() public {
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, NEUTRAL, token.uiScalingFactor(UIScalingClass.Yield));
        assertEq(capital, RAW_STAKE);
        assertEq(UIScalingMath.yieldLegRaw(RAW_STAKE, capital), 0);
    }

    function test_capitalRaw_orderIndependent() public {
        (uint256 capitalA,) = _runMixedClassScenario(true);
        (uint256 capitalB,) = _runMixedClassScenario(false);
        assertEq(capitalA, capitalB);
        assertEq(capitalA, 50 ether);
    }

    function _runMixedClassScenario(bool yieldFirst)
        internal
        returns (uint256 capitalRawAmount, uint256 yieldLegRawAmount)
    {
        ERC8056Composite local = new ERC8056Composite("Local", "LOC", owner);
        uint256 yieldAtStake = local.uiScalingFactor(UIScalingClass.Yield);

        if (yieldFirst) {
            vm.prank(owner);
            local.applyUIMultiplierDelta(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
            vm.prank(owner);
            local.applyUIMultiplierDelta(UIScalingClass.Supply, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
        } else {
            vm.prank(owner);
            local.applyUIMultiplierDelta(UIScalingClass.Supply, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
            vm.prank(owner);
            local.applyUIMultiplierDelta(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
        }

        capitalRawAmount =
            UIScalingMath.capitalRaw(RAW_STAKE, yieldAtStake, local.uiScalingFactor(UIScalingClass.Yield));
        yieldLegRawAmount = UIScalingMath.yieldLegRaw(RAW_STAKE, capitalRawAmount);
    }

    //==============================================================================//
    // Year-lock integration scenario                                               //
    //==============================================================================//
    function test_yearLock_mixedActions_orderIndependent() public {
        YearLockSnapshot memory pathA = _runYearLockScenario(_yearLockOrderingA());
        YearLockSnapshot memory pathB = _runYearLockScenario(_yearLockOrderingB());

        assertEq(pathA.finalYieldFactor, pathB.finalYieldFactor);
        assertEq(pathA.finalSupplyFactor, pathB.finalSupplyFactor);
        assertEq(pathA.finalCompositeFactor, pathB.finalCompositeFactor);
        assertEq(pathA.capitalRaw, pathB.capitalRaw);
        assertEq(pathA.yieldLegRaw, pathB.yieldLegRaw);

        assertEq(pathA.finalYieldFactor, 3e18);
        assertEq(pathA.finalSupplyFactor, NEUTRAL);
        assertEq(pathA.finalCompositeFactor, 3e18);
    }

    function test_yearLock_yieldSnapshotAtStakeTime() public {
        ERC8056Composite local = new ERC8056Composite("Lock", "LOCK", owner);
        uint256 stakeTime = block.timestamp;
        uint256 yieldAtStake = local.uiScalingFactorAt(UIScalingClass.Yield, stakeTime);
        assertEq(yieldAtStake, NEUTRAL);

        _warpToEffective(stakeTime + 90 days);
        vm.prank(owner);
        local.applyUIMultiplierDelta(UIScalingClass.Yield, 1.5e18, block.timestamp + 1 hours, "", "", "");
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(local.uiScalingFactorAt(UIScalingClass.Yield, stakeTime), NEUTRAL);
        assertEq(local.uiScalingFactorAt(UIScalingClass.Yield, block.timestamp), 1.5e18);
        assertEq(UIScalingMath.yieldGrowthSinceStake(yieldAtStake, local.uiScalingFactor(UIScalingClass.Yield)), 1.5e18);
    }

    function test_yearLock_intermediateHistory() public {
        uint256 start = block.timestamp;
        uint256 tYield = start + 90 days;
        uint256 tSupply = tYield + 90 days;

        _warpToEffective(tYield);
        _scheduleScalingDelta(UIScalingClass.Yield, 1.5e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        _warpToEffective(tSupply);
        _scheduleScalingDelta(UIScalingClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, tYield), NEUTRAL);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, block.timestamp), 1.5e18);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Supply, tSupply), NEUTRAL);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Supply, block.timestamp), DOUBLE);
        assertEq(token.uiMultiplierAt(block.timestamp), 3e18);
    }

    struct ScalingAction {
        UIScalingClass scalingClass;
        uint256 factorDelta;
        uint256 dayOffset;
    }

    struct YearLockSnapshot {
        uint256 finalYieldFactor;
        uint256 finalSupplyFactor;
        uint256 finalCompositeFactor;
        uint256 capitalRaw;
        uint256 yieldLegRaw;
    }

    function _yearLockOrderingA() private pure returns (ScalingAction[] memory actions) {
        actions = new ScalingAction[](4);
        actions[0] = ScalingAction(UIScalingClass.Yield, 1.5e18, 90);
        actions[1] = ScalingAction(UIScalingClass.Supply, DOUBLE, 180);
        actions[2] = ScalingAction(UIScalingClass.Supply, HALF, 270);
        actions[3] = ScalingAction(UIScalingClass.Yield, DOUBLE, 330);
    }

    function _yearLockOrderingB() private pure returns (ScalingAction[] memory actions) {
        actions = new ScalingAction[](4);
        actions[0] = ScalingAction(UIScalingClass.Supply, DOUBLE, 60);
        actions[1] = ScalingAction(UIScalingClass.Yield, 1.5e18, 120);
        actions[2] = ScalingAction(UIScalingClass.Yield, DOUBLE, 240);
        actions[3] = ScalingAction(UIScalingClass.Supply, HALF, 360);
    }

    function _runYearLockScenario(ScalingAction[] memory actions) private returns (YearLockSnapshot memory snapshot) {
        ERC8056Composite local = new ERC8056Composite("Year", "YR", owner);
        uint256 yieldAtStake = local.uiScalingFactor(UIScalingClass.Yield);
        uint256 start = block.timestamp;

        for (uint256 i = 0; i < actions.length; i++) {
            _warpToEffective(start + actions[i].dayOffset * 1 days);
            vm.prank(owner);
            local.applyUIMultiplierDelta(
                actions[i].scalingClass, actions[i].factorDelta, block.timestamp + 1 hours, "", "", ""
            );
            _warpToEffective(block.timestamp + 1 hours);
        }

        snapshot.finalYieldFactor = local.uiScalingFactor(UIScalingClass.Yield);
        snapshot.finalSupplyFactor = local.uiScalingFactor(UIScalingClass.Supply);
        snapshot.finalCompositeFactor = local.uiMultiplier();
        snapshot.capitalRaw = UIScalingMath.capitalRaw(RAW_STAKE, yieldAtStake, snapshot.finalYieldFactor);
        snapshot.yieldLegRaw = UIScalingMath.yieldLegRaw(RAW_STAKE, snapshot.capitalRaw);
    }

    //==============================================================================//
    // Scheduling & reverts                                                         //
    //==============================================================================//
    function test_schedule_pendingVisibleBeforeEffective() public {
        uint256 effectiveAt = _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 days);
        assertTrue(token.hasPendingUIMultiplier(UIScalingClass.Yield));
        assertEq(token.newUIMultiplier(UIScalingClass.Yield), DOUBLE);
        assertEq(token.uiScalingFactor(UIScalingClass.Yield), NEUTRAL);
        assertEq(token.newUIMultiplier(), DOUBLE);
        assertEq(token.effectiveAt(), effectiveAt);
    }

    function test_schedule_emitsScalingFactorUpdated() public {
        vm.expectEmit(true, true, true, true);
        emit IERC8056Composite.UIScalingFactorUpdated(
            UIScalingClass.Yield,
            DOUBLE,
            DOUBLE,
            block.timestamp + 1 hours,
            0, // nonce 0: not yet effective
            IERC8056Composite.Announcement({id: "", description: "", uri: ""})
        );
        _scheduleScalingDelta(UIScalingClass.Yield, DOUBLE, 1 hours);
    }

    function test_revert_zeroDelta() public {
        vm.prank(owner);
        vm.expectRevert("ERC8056: delta must be positive");
        token.applyUIMultiplierDelta(UIScalingClass.Yield, 0, block.timestamp + 1, "", "", "");
    }

    function test_revert_effectiveAtNotFuture() public {
        vm.prank(owner);
        vm.expectRevert("ERC8056: effective time must be future");
        token.setUIMultiplier(UIScalingClass.Yield, DOUBLE, block.timestamp, "", "", "");
    }

    //==============================================================================//
    // Yield nonce (event-based expiry)                                             //
    //==============================================================================//
    function test_getClassNonce_zeroInitially() public view {
        assertEq(token.getClassNonce(UIScalingClass.Yield), 0);
    }

    function test_getClassNonce_ticksOnlyWhenEffective() public {
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        assertEq(token.getClassNonce(UIScalingClass.Yield), 0); // pending: not counted
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(UIScalingClass.Yield), 1);
    }

    function test_getClassNonce_supplyUpdatesDoNotTick() public {
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Supply, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(UIScalingClass.Yield), 0);
    }

    function test_getClassNonce_countsEffectiveEvents() public {
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, 11e17, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days); // nonce 1
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, 12e17, block.timestamp + 2 days, "", "", "");
        vm.warp(block.timestamp + 1 days); // second update still pending
        assertEq(token.getClassNonce(UIScalingClass.Yield), 1);
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(UIScalingClass.Yield), 2);
    }

    function test_getClassNonce_reschedule_keepsSingleEvent() public {
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, 15e17, block.timestamp + 2 days, "", "", "");
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, 15e17, block.timestamp + 4 days, "", "", ""); // delayed: pending popped + re-pushed
        vm.warp(block.timestamp + 2 days); // old date passes
        assertEq(token.getClassNonce(UIScalingClass.Yield), 0);
        vm.warp(block.timestamp + 2 days); // new date
        assertEq(token.getClassNonce(UIScalingClass.Yield), 1);
    }

    function test_classEventAtNonce_returnsTimestampAndMultiplier() public {
        uint256 t1 = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, 15e17, t1, "", "", "");
        vm.warp(t1);

        IERC8056Composite.ClassScalingEvent memory ev = token.classEventAtNonce(UIScalingClass.Yield, 1);
        assertEq(ev.timestamp, t1);
        assertEq(ev.cumulativeFactor, 15e17);
    }

    function test_classEventAtNonce_notRecorded_reverts() public {
        vm.expectRevert(ERC8056Composite.EventNotRecorded.selector);
        token.classEventAtNonce(UIScalingClass.Yield, 1);
    }

    function _scheduleScalingFactor(UIScalingClass clazz, uint256 factor, uint256 effectiveAt) internal {
        vm.prank(owner);
        token.setUIMultiplier(clazz, factor, effectiveAt, "", "", "");
    }

    //==============================================================================//
    // Binary search correctness                                                    //
    //==============================================================================//
    function test_binarySearch_beforeFirstCheckpoint() public view {
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, 0), NEUTRAL);
    }

    function test_binarySearch_betweenCheckpoints() public {
        uint256 t1 = _scheduleScalingDelta(UIScalingClass.Yield, 1.5e18, 1 hours);
        vm.warp(t1); // make first effective
        uint256 t2 = _scheduleScalingDelta(UIScalingClass.Yield, 2e18, 2 hours);

        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, t1 - 1), NEUTRAL);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, t1), 1.5e18);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, t2 - 1), 1.5e18);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Yield, t2), 3e18);
    }

    function test_binarySearch_exactTimestamp() public {
        uint256 t1 = block.timestamp + 1 hours;
        _scheduleScalingFactor(UIScalingClass.Supply, DOUBLE, t1);

        assertEq(token.uiScalingFactorAt(UIScalingClass.Supply, t1), DOUBLE);
        assertEq(token.uiScalingFactorAt(UIScalingClass.Supply, t1 - 1), NEUTRAL);
    }

    function test_binarySearch_multipleClasses() public {
        _scheduleScalingFactor(UIScalingClass.Supply, DOUBLE, block.timestamp + 1 hours);
        _scheduleScalingFactor(UIScalingClass.Yield, 1.5e18, block.timestamp + 2 hours);
        _scheduleScalingFactor(UIScalingClass.Other, 3e18, block.timestamp + 3 hours);

        uint256 ts = block.timestamp + 4 hours;
        assertEq(token.uiMultiplierAt(UIScalingClass.Supply, ts), DOUBLE);
        assertEq(token.uiMultiplierAt(UIScalingClass.Yield, ts), 1.5e18);
        assertEq(token.uiMultiplierAt(UIScalingClass.Other, ts), 3e18);
        assertEq(token.uiMultiplierAt(ts), DOUBLE * 1.5e18 / 1e18 * 3e18 / 1e18);
    }

    function test_getClassNonce_allClasses() public {
        assertEq(token.getClassNonce(UIScalingClass.Supply), 0);
        assertEq(token.getClassNonce(UIScalingClass.Yield), 0);
        assertEq(token.getClassNonce(UIScalingClass.Other), 0);

        _scheduleScalingFactor(UIScalingClass.Supply, DOUBLE, block.timestamp + 1 hours);
        _scheduleScalingFactor(UIScalingClass.Yield, 1.5e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        assertEq(token.getClassNonce(UIScalingClass.Supply), 1);
        assertEq(token.getClassNonce(UIScalingClass.Yield), 1);
        assertEq(token.getClassNonce(UIScalingClass.Other), 0);
    }

    function test_classEventAtNonce_supply() public {
        uint256 t1 = block.timestamp + 1 hours;
        _scheduleScalingFactor(UIScalingClass.Supply, DOUBLE, t1);
        vm.warp(t1 + 1);

        IERC8056Composite.ClassScalingEvent memory ev = token.classEventAtNonce(UIScalingClass.Supply, 1);
        assertEq(ev.timestamp, t1);
        assertEq(ev.cumulativeFactor, DOUBLE);
    }

    function test_uiMultiplierAtNonce_composite() public {
        uint256 t1 = block.timestamp + 1 hours;
        _scheduleScalingFactor(UIScalingClass.Supply, DOUBLE, t1);
        vm.warp(t1 + 1);

        assertEq(token.uiMultiplierAtNonce(UIScalingClass.Supply, 1), DOUBLE);
    }

    function test_classEventAtNonce_pendingNotVisible_reverts() public {
        vm.prank(owner);
        token.setUIMultiplier(UIScalingClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.expectRevert(ERC8056Composite.EventNotEffective.selector);
        token.classEventAtNonce(UIScalingClass.Yield, 1);
    }
}
