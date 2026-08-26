// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8056} from "../src/ERC8056.sol";
import {ERC8056Composite} from "../src/ERC8056Composite.sol";
import {IERC8056Composite} from "../src/interfaces/extension/IERC8056Composite.sol";
import {MultiplierClass} from "../src/interfaces/extension/IERC8056MultiplierClass.sol";
import {IERC8056NewUIMultiplier} from "../src/interfaces/base/IERC8056NewUIMultiplier.sol";
import {IERC8056Cancel} from "../src/interfaces/base/IERC8056Cancel.sol";
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

    function _scheduleMultiplier(MultiplierClass scalingClass, uint256 newMultiplier, uint256 delay)
        internal
        returns (uint256 effectiveAt)
    {
        effectiveAt = block.timestamp + delay;
        vm.prank(owner);
        token.setUIMultiplier(scalingClass, newMultiplier, effectiveAt, "", "", "");
    }

    function _warpToEffective(uint256 effectiveAt) internal {
        vm.warp(effectiveAt);
    }

    //==============================================================================//
    // Initial state                                                                //
    //==============================================================================//
    function test_initial_neutralAllClasses() public view {
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), NEUTRAL);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(token.uiScalingFactor(MultiplierClass.Other), NEUTRAL);
        assertEq(token.uiMultiplier(), NEUTRAL);
        assertEq(token.balanceOfUI(holder), RAW_STAKE);
        assertEq(token.scalingHistoryLength(MultiplierClass.Supply), 1);
        assertEq(token.scalingHistoryLength(MultiplierClass.Yield), 1);
        assertEq(token.scalingHistoryLength(MultiplierClass.Other), 1);
    }

    function test_initial_genesisCheckpoint() public view {
        IERC8056Composite.ScalingCheckpoint memory genesis = token.scalingCheckpointAt(MultiplierClass.Supply, 0);
        assertEq(genesis.effectiveAt, 0);
        assertEq(genesis.cumulativeMultiplier, NEUTRAL);

        IERC8056Composite.ScalingCheckpoint memory genesisOther = token.scalingCheckpointAt(MultiplierClass.Other, 0);
        assertEq(genesisOther.effectiveAt, 0);
        assertEq(genesisOther.cumulativeMultiplier, NEUTRAL);
    }

    function test_initial_supportsClassedInterface() public view {
        assertTrue(token.supportsInterface(type(IERC8056Composite).interfaceId));
    }

    function test_SpecInterfaceID_Preserved() public pure {
        // EIP-8056 mandates IScaledUIAmountNewUIMultiplier = 0x4bd27648
        assertEq(type(IERC8056NewUIMultiplier).interfaceId, bytes4(0x4bd27648));
    }

    function test_CancelInterfaceID_Exposed() public view {
        assertTrue(token.supportsInterface(type(IERC8056Cancel).interfaceId));
    }

    //==============================================================================//
    // Order independence                                                           //
    //==============================================================================//
    function test_orderIndependence_yieldThenSupply() public {
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 hours);
        uint256 tSupply = _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 2 hours);

        _warpToEffective(tYield);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), DOUBLE);
        assertEq(token.uiMultiplier(), DOUBLE);

        _warpToEffective(tSupply);
        assertEq(token.uiMultiplier(), 4e18);
        assertEq(token.balanceOfUI(holder), 400 ether);
    }

    function test_orderIndependence_supplyThenYield() public {
        uint256 tSupply = _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 2 hours);

        _warpToEffective(tSupply);
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), DOUBLE);
        assertEq(token.uiMultiplier(), DOUBLE);

        _warpToEffective(tYield);
        assertEq(token.uiMultiplier(), 4e18);
    }

    function test_orderIndependence_sameEffectiveTimestamp() public {
        uint256 effectiveAt = block.timestamp + 1 days;

        ERC8056Composite pathA = new ERC8056Composite("A", "A", owner);
        vm.startPrank(owner);
        pathA.setUIMultiplier(MultiplierClass.Yield, DOUBLE, effectiveAt, "", "", "");
        pathA.setUIMultiplier(MultiplierClass.Supply, DOUBLE, effectiveAt, "", "", "");
        vm.stopPrank();

        ERC8056Composite pathB = new ERC8056Composite("B", "B", owner);
        vm.startPrank(owner);
        pathB.setUIMultiplier(MultiplierClass.Supply, DOUBLE, effectiveAt, "", "", "");
        pathB.setUIMultiplier(MultiplierClass.Yield, DOUBLE, effectiveAt, "", "", "");
        vm.stopPrank();

        _warpToEffective(effectiveAt);
        assertEq(pathA.uiMultiplier(), pathB.uiMultiplier());
        assertEq(pathA.uiMultiplier(), 4e18);
    }

    //==============================================================================//
    // Historical lookups                                                           //
    //==============================================================================//
    function test_uiScalingFactorAt_beforeFirstUpdate() public view {
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, block.timestamp), NEUTRAL);
        assertEq(token.uiMultiplierAt(block.timestamp), NEUTRAL);
    }

    function test_uiScalingFactorAt_betweenScheduledUpdates() public {
        uint256 t0 = block.timestamp;
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 days);
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 2 days);

        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, t0), NEUTRAL);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, tYield), DOUBLE);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Supply, tYield + 1 hours), NEUTRAL);

        _warpToEffective(tYield + 1 hours);
        assertEq(token.uiMultiplierAt(tYield), DOUBLE);
    }

    function test_uiMultiplierAt_timeline() public {
        uint256 t0 = block.timestamp;
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 days);
        uint256 tSupply = _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 2 days);

        assertEq(token.uiMultiplierAt(t0), NEUTRAL);
        assertEq(token.uiMultiplierAt(tYield), DOUBLE);
        assertEq(token.uiMultiplierAt(tSupply), 4e18);
    }

    function test_history_appendsAndOverwritesPending() public {
        uint256 t0 = block.timestamp;
        uint256 tFirst = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 days);
        assertEq(token.scalingHistoryLength(MultiplierClass.Yield), 2);

        IERC8056Composite.ScalingCheckpoint memory first = token.scalingCheckpointAt(MultiplierClass.Yield, 1);
        assertEq(first.effectiveAt, tFirst);
        assertEq(first.cumulativeMultiplier, DOUBLE);

        _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 2 days);
        assertEq(token.scalingHistoryLength(MultiplierClass.Yield), 2);

        _warpToEffective(t0 + 2 days + 1 hours);
        _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 days);
        assertEq(token.scalingHistoryLength(MultiplierClass.Yield), 3);
    }

    //==============================================================================//
    // Conversion overloads                                                         //
    //==============================================================================//
    function test_toUIAmountAt_compositeHistory() public {
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 days);
        _warpToEffective(tYield);
        assertEq(token.toUIAmountAt(RAW_STAKE, tYield - 1), RAW_STAKE);
        assertEq(token.toUIAmountAt(RAW_STAKE, tYield), 200 ether);
    }

    function test_toUIAmount_withScalingClass() public {
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.toUIAmount(RAW_STAKE, MultiplierClass.Supply), 200 ether);
        assertEq(token.toUIAmount(RAW_STAKE, MultiplierClass.Yield), RAW_STAKE);
        assertEq(token.toUIAmount(RAW_STAKE), 200 ether);
    }

    function test_toUIAmountAt_withScalingClass() public {
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, 1.5e18, 1 days);
        assertEq(token.toUIAmountAt(RAW_STAKE, MultiplierClass.Yield, tYield - 1), RAW_STAKE);
        assertEq(token.toUIAmountAt(RAW_STAKE, MultiplierClass.Yield, tYield), 150 ether);
        assertEq(token.toUIAmountAt(RAW_STAKE, MultiplierClass.Supply, tYield), RAW_STAKE);
    }

    //==============================================================================//
    // Supply class                                                                 //
    //==============================================================================//
    function test_supply_reverseSplitResetsFactor() public {
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), DOUBLE);

        _scheduleMultiplier(MultiplierClass.Supply, HALF, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), HALF);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
    }

    function test_supply_doesNotAffectYieldFactor() public {
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), DOUBLE);
    }

    //==============================================================================//
    // Yield class                                                                  //
    //==============================================================================//
    function test_yield_accretionDoublesUIBalance() public {
        _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(MultiplierClass.Yield), DOUBLE);
        assertEq(token.balanceOfUI(holder), 200 ether);
        assertEq(token.balanceOf(holder), RAW_STAKE);
    }

    function test_yield_accretionAfterSupply_usesSeparateClasses() public {
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        _scheduleMultiplier(MultiplierClass.Yield, 1.05e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(MultiplierClass.Supply), DOUBLE);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), 1.05e18);
        assertEq(token.uiMultiplier(), 2.1e18);
        assertEq(token.balanceOfUI(holder), 210 ether);
    }

    function test_yield_growthSinceStake() public {
        uint256 yieldAtStake = NEUTRAL;
        _scheduleMultiplier(MultiplierClass.Yield, 1.5e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        _scheduleMultiplier(MultiplierClass.Yield, 3e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(UIScalingMath.yieldGrowthSinceStake(yieldAtStake, token.uiScalingFactor(MultiplierClass.Yield)), 3e18);
    }

    //==============================================================================//
    // Other class                                                                  //
    //==============================================================================//
    function test_other_composesIntoMultiplier() public {
        _scheduleMultiplier(MultiplierClass.Other, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(MultiplierClass.Other), DOUBLE);
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), NEUTRAL);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(token.uiMultiplier(), DOUBLE);
        assertEq(token.balanceOfUI(holder), 200 ether);
    }

    function test_other_multipliesSupplyAndYield() public {
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        _scheduleMultiplier(MultiplierClass.Yield, 1.5e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);
        _scheduleMultiplier(MultiplierClass.Other, 3e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactor(MultiplierClass.Supply), DOUBLE);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), 1.5e18);
        assertEq(token.uiScalingFactor(MultiplierClass.Other), 3e18);
        assertEq(token.uiMultiplier(), 9e18);
        assertEq(token.balanceOfUI(holder), 900 ether);
    }

    function test_other_doesNotTickYieldNonce() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Other, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 0);
    }

    //==============================================================================//
    // Capital / yield leg math                                                     //
    //==============================================================================//
    function test_capitalRaw_yieldAccretionReducesPrincipal() public {
        uint256 yieldAtStake = NEUTRAL;
        _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        uint256 yieldNow = token.uiScalingFactor(MultiplierClass.Yield);
        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, yieldAtStake, yieldNow);
        uint256 yieldLeg = UIScalingMath.yieldLegRaw(RAW_STAKE, capital);

        assertEq(capital, 50 ether);
        assertEq(yieldLeg, 50 ether);
        assertEq(UIScalingMath.toUIAmount(capital, token.uiMultiplier()), RAW_STAKE);
    }

    function test_capitalRaw_supplyDoesNotReducePrincipal() public {
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        uint256 capital = UIScalingMath.capitalRaw(RAW_STAKE, NEUTRAL, token.uiScalingFactor(MultiplierClass.Yield));
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
        uint256 yieldAtStake = local.uiScalingFactor(MultiplierClass.Yield);

        if (yieldFirst) {
            vm.prank(owner);
            local.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
            vm.prank(owner);
            local.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
        } else {
            vm.prank(owner);
            local.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
            vm.prank(owner);
            local.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 hours, "", "", "");
            _warpToEffective(block.timestamp + 1 hours);
        }

        capitalRawAmount =
            UIScalingMath.capitalRaw(RAW_STAKE, yieldAtStake, local.uiScalingFactor(MultiplierClass.Yield));
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
        uint256 yieldAtStake = local.uiScalingFactorAt(MultiplierClass.Yield, stakeTime);
        assertEq(yieldAtStake, NEUTRAL);

        _warpToEffective(stakeTime + 90 days);
        vm.prank(owner);
        local.setUIMultiplier(MultiplierClass.Yield, 1.5e18, block.timestamp + 1 hours, "", "", "");
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(local.uiScalingFactorAt(MultiplierClass.Yield, stakeTime), NEUTRAL);
        assertEq(local.uiScalingFactorAt(MultiplierClass.Yield, block.timestamp), 1.5e18);
        assertEq(
            UIScalingMath.yieldGrowthSinceStake(yieldAtStake, local.uiScalingFactor(MultiplierClass.Yield)), 1.5e18
        );
    }

    function test_yearLock_intermediateHistory() public {
        uint256 start = block.timestamp;
        uint256 tYield = start + 90 days;
        uint256 tSupply = tYield + 90 days;

        _warpToEffective(tYield);
        _scheduleMultiplier(MultiplierClass.Yield, 1.5e18, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        _warpToEffective(tSupply);
        _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        _warpToEffective(block.timestamp + 1 hours);

        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, tYield), NEUTRAL);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, block.timestamp), 1.5e18);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Supply, tSupply), NEUTRAL);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Supply, block.timestamp), DOUBLE);
        assertEq(token.uiMultiplierAt(block.timestamp), 3e18);
    }

    struct ScalingAction {
        MultiplierClass scalingClass;
        uint256 newMultiplier;
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
        actions[0] = ScalingAction(MultiplierClass.Yield, 1.5e18, 90);
        actions[1] = ScalingAction(MultiplierClass.Supply, DOUBLE, 180);
        actions[2] = ScalingAction(MultiplierClass.Supply, NEUTRAL, 270);
        actions[3] = ScalingAction(MultiplierClass.Yield, 3e18, 330);
    }

    function _yearLockOrderingB() private pure returns (ScalingAction[] memory actions) {
        actions = new ScalingAction[](4);
        actions[0] = ScalingAction(MultiplierClass.Supply, DOUBLE, 60);
        actions[1] = ScalingAction(MultiplierClass.Yield, 1.5e18, 120);
        actions[2] = ScalingAction(MultiplierClass.Yield, 3e18, 240);
        actions[3] = ScalingAction(MultiplierClass.Supply, NEUTRAL, 360);
    }

    function _runYearLockScenario(ScalingAction[] memory actions) private returns (YearLockSnapshot memory snapshot) {
        ERC8056Composite local = new ERC8056Composite("Year", "YR", owner);
        uint256 yieldAtStake = local.uiScalingFactor(MultiplierClass.Yield);
        uint256 start = block.timestamp;

        for (uint256 i = 0; i < actions.length; i++) {
            _warpToEffective(start + actions[i].dayOffset * 1 days);
            vm.prank(owner);
            local.setUIMultiplier(
                actions[i].scalingClass, actions[i].newMultiplier, block.timestamp + 1 hours, "", "", ""
            );
            _warpToEffective(block.timestamp + 1 hours);
        }

        snapshot.finalYieldFactor = local.uiScalingFactor(MultiplierClass.Yield);
        snapshot.finalSupplyFactor = local.uiScalingFactor(MultiplierClass.Supply);
        snapshot.finalCompositeFactor = local.uiMultiplier();
        snapshot.capitalRaw = UIScalingMath.capitalRaw(RAW_STAKE, yieldAtStake, snapshot.finalYieldFactor);
        snapshot.yieldLegRaw = UIScalingMath.yieldLegRaw(RAW_STAKE, snapshot.capitalRaw);
    }

    //==============================================================================//
    // Scheduling & reverts                                                         //
    //==============================================================================//
    function test_schedule_pendingVisibleBeforeEffective() public {
        uint256 effectiveAt = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 days);
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Yield));
        assertEq(token.newUIMultiplier(MultiplierClass.Yield), DOUBLE);
        assertEq(token.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(token.newUIMultiplier(), DOUBLE);
        assertEq(token.effectiveAt(), effectiveAt);
    }

    function test_schedule_emitsScalingFactorUpdated() public {
        vm.expectEmit(true, true, true, true);
        emit IERC8056Composite.UIScalingFactorUpdated(
            MultiplierClass.Yield,
            DOUBLE,
            DOUBLE,
            block.timestamp + 1 hours,
            0, // nonce 0: not yet effective
            IERC8056Composite.Announcement({id: "", description: "", uri: ""})
        );
        _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 hours);
    }

    function test_revert_zeroMultiplier() public {
        vm.prank(owner);
        vm.expectRevert("ERC8056: factor must be positive");
        token.setUIMultiplier(MultiplierClass.Yield, 0, block.timestamp + 1, "", "", "");
    }

    function test_revert_effectiveAtNotFuture() public {
        vm.prank(owner);
        vm.expectRevert("ERC8056: effective time must be future");
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp, "", "", "");
    }

    //==============================================================================//
    // Yield nonce (event-based expiry)                                             //
    //==============================================================================//
    function test_getClassNonce_zeroInitially() public view {
        assertEq(token.getClassNonce(MultiplierClass.Yield), 0);
    }

    function test_getClassNonce_ticksOnlyWhenEffective() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        assertEq(token.getClassNonce(MultiplierClass.Yield), 0); // pending: not counted
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 1);
    }

    function test_getClassNonce_supplyUpdatesDoNotTick() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 0);
    }

    function test_getClassNonce_countsEffectiveEvents() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 11e17, block.timestamp + 1 days, "", "", "");
        vm.warp(block.timestamp + 1 days); // nonce 1
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 12e17, block.timestamp + 2 days, "", "", "");
        vm.warp(block.timestamp + 1 days); // second update still pending
        assertEq(token.getClassNonce(MultiplierClass.Yield), 1);
        vm.warp(block.timestamp + 1 days);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 2);
    }

    function test_getClassNonce_reschedule_keepsSingleEvent() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 15e17, block.timestamp + 2 days, "", "", "");
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 15e17, block.timestamp + 4 days, "", "", ""); // delayed: pending popped + re-pushed
        vm.warp(block.timestamp + 2 days); // old date passes
        assertEq(token.getClassNonce(MultiplierClass.Yield), 0);
        vm.warp(block.timestamp + 2 days); // new date
        assertEq(token.getClassNonce(MultiplierClass.Yield), 1);
    }

    function test_classEventAtNonce_returnsTimestampAndMultiplier() public {
        uint256 t1 = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 15e17, t1, "", "", "");
        vm.warp(t1);

        IERC8056Composite.ClassScalingEvent memory ev = token.classEventAtNonce(MultiplierClass.Yield, 1);
        assertEq(ev.timestamp, t1);
        assertEq(ev.cumulativeMultiplier, 15e17);
    }

    function test_classEventAtNonce_notRecorded_reverts() public {
        vm.expectRevert(ERC8056Composite.EventNotRecorded.selector);
        token.classEventAtNonce(MultiplierClass.Yield, 1);
    }

    function _scheduleScalingFactor(MultiplierClass clazz, uint256 factor, uint256 effectiveAt) internal {
        vm.prank(owner);
        token.setUIMultiplier(clazz, factor, effectiveAt, "", "", "");
    }

    //==============================================================================//
    // Binary search correctness                                                    //
    //==============================================================================//
    function test_binarySearch_beforeFirstCheckpoint() public view {
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, 0), NEUTRAL);
    }

    function test_binarySearch_betweenCheckpoints() public {
        uint256 t1 = _scheduleMultiplier(MultiplierClass.Yield, 1.5e18, 1 hours);
        vm.warp(t1); // make first effective
        uint256 t2 = _scheduleMultiplier(MultiplierClass.Yield, 2e18, 2 hours);

        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, t1 - 1), NEUTRAL);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, t1), 1.5e18);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, t2 - 1), 1.5e18);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Yield, t2), 2e18);
    }

    function test_binarySearch_exactTimestamp() public {
        uint256 t1 = block.timestamp + 1 hours;
        _scheduleScalingFactor(MultiplierClass.Supply, DOUBLE, t1);

        assertEq(token.uiScalingFactorAt(MultiplierClass.Supply, t1), DOUBLE);
        assertEq(token.uiScalingFactorAt(MultiplierClass.Supply, t1 - 1), NEUTRAL);
    }

    function test_binarySearch_multipleClasses() public {
        _scheduleScalingFactor(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 hours);
        _scheduleScalingFactor(MultiplierClass.Yield, 1.5e18, block.timestamp + 2 hours);
        _scheduleScalingFactor(MultiplierClass.Other, 3e18, block.timestamp + 3 hours);

        uint256 ts = block.timestamp + 4 hours;
        assertEq(token.uiMultiplierAt(MultiplierClass.Supply, ts), DOUBLE);
        assertEq(token.uiMultiplierAt(MultiplierClass.Yield, ts), 1.5e18);
        assertEq(token.uiMultiplierAt(MultiplierClass.Other, ts), 3e18);
        assertEq(token.uiMultiplierAt(ts), DOUBLE * 1.5e18 / 1e18 * 3e18 / 1e18);
    }

    function test_getClassNonce_allClasses() public {
        assertEq(token.getClassNonce(MultiplierClass.Supply), 0);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 0);
        assertEq(token.getClassNonce(MultiplierClass.Other), 0);

        _scheduleScalingFactor(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 hours);
        _scheduleScalingFactor(MultiplierClass.Yield, 1.5e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        assertEq(token.getClassNonce(MultiplierClass.Supply), 1);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 1);
        assertEq(token.getClassNonce(MultiplierClass.Other), 0);
    }

    function test_classEventAtNonce_supply() public {
        uint256 t1 = block.timestamp + 1 hours;
        _scheduleScalingFactor(MultiplierClass.Supply, DOUBLE, t1);
        vm.warp(t1 + 1);

        IERC8056Composite.ClassScalingEvent memory ev = token.classEventAtNonce(MultiplierClass.Supply, 1);
        assertEq(ev.timestamp, t1);
        assertEq(ev.cumulativeMultiplier, DOUBLE);
    }

    function test_uiMultiplierAtNonce_composite() public {
        uint256 t1 = block.timestamp + 1 hours;
        _scheduleScalingFactor(MultiplierClass.Supply, DOUBLE, t1);
        vm.warp(t1 + 1);

        assertEq(token.uiMultiplierAtNonce(MultiplierClass.Supply, 1), DOUBLE);
    }

    function test_classEventAtNonce_pendingNotVisible_reverts() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.expectRevert(ERC8056Composite.EventNotEffective.selector);
        token.classEventAtNonce(MultiplierClass.Yield, 1);
    }

    function test_UiMultiplierAtNonce_DivergentHistories_DoesNotRevert() public {
        // two Yield events (nonce 2), one Supply event (nonce 1), Other none
        _scheduleScalingFactor(MultiplierClass.Yield, 15e17, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours); // Yield nonce 1 effective
        _scheduleScalingFactor(MultiplierClass.Yield, 12e17, block.timestamp + 1 hours);
        _scheduleScalingFactor(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours); // Yield nonce 2 + Supply nonce 1 effective

        // all calls succeed without revert despite divergent per-class histories
        uint256 m1 = token.uiMultiplierAtNonce(1);
        assertGt(m1, 0);
        uint256 m2 = token.uiMultiplierAtNonce(2);
        assertGt(m2, 0);
        assertEq(token.uiMultiplierAtNonce(99), token.uiMultiplier());
    }

    function test_UiMultiplierAtNonce_ZeroReturnsNeutralComposite() public view {
        assertEq(token.uiMultiplierAtNonce(0), NEUTRAL);
    }

    function test_GetClassNonce_GasIndependentOfHistoryLength() public {
        for (uint256 i = 0; i < 50; i++) {
            _scheduleScalingFactor(MultiplierClass.Yield, 11e17, block.timestamp + 1 hours);
            vm.warp(block.timestamp + 2 hours);
        }
        assertEq(token.getClassNonce(MultiplierClass.Yield), 50);

        uint256 start = gasleft();
        token.getClassNonce(MultiplierClass.Yield);
        uint256 used = start - gasleft();

        emit log_named_uint("getClassNonce gas with 50 activated events", used);
        assertLt(used, 15000);
    }

    // ---- Cancel tests ----

    function test_cancelRestoresActiveFactor() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");

        assertEq(token.newUIMultiplier(MultiplierClass.Yield), DOUBLE);
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Yield));

        vm.prank(owner);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);

        assertEq(token.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(token.newUIMultiplier(MultiplierClass.Yield), NEUTRAL);
        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Yield));
        assertEq(token.effectiveAt(MultiplierClass.Yield), 0);
    }

    function test_cancelPopsCheckpoint() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");

        uint256 lenBefore = token.scalingHistoryLength(MultiplierClass.Yield);

        vm.prank(owner);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);

        assertEq(token.scalingHistoryLength(MultiplierClass.Yield), lenBefore - 1);
    }

    function test_cancelEmitsEvents() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");

        vm.expectEmit(true, true, true, true);
        emit IERC8056Composite.UIScalingFactorCancelled(MultiplierClass.Yield, DOUBLE, NEUTRAL, block.timestamp);

        vm.expectEmit(false, true, true, false);
        emit IERC8056Cancel.UIMultiplierCancelled(DOUBLE, NEUTRAL, block.timestamp);

        vm.prank(owner);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);
    }

    function test_revertWhenCancelNothingPending() public {
        vm.prank(owner);
        vm.expectRevert(ERC8056.NothingToCancel.selector);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);
    }

    function test_revertWhenCancelAlreadyEffective() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");

        vm.warp(block.timestamp + 1 days);

        vm.prank(owner);
        vm.expectRevert(ERC8056.NothingToCancel.selector);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);
    }

    function test_cancelOnlyAffectsTargetClass() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 days, "", "", "");

        vm.prank(owner);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);

        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Yield));
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Supply));
    }

    function test_cancelThenReschedule() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");

        vm.prank(owner);
        token.cancelPendingUIMultiplier(MultiplierClass.Yield);

        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 3 * NEUTRAL, block.timestamp + 2 days, "", "", "");

        assertEq(token.newUIMultiplier(MultiplierClass.Yield), 3 * NEUTRAL);
        assertEq(token.effectiveAt(MultiplierClass.Yield), block.timestamp + 2 days);
    }

    function test_cancelViaBaseSelector_CancelsAllPendingClasses() public {
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 1 days, "", "", "");
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 days, "", "", "");
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Supply));
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Yield));

        vm.prank(owner);
        token.cancelPendingUIMultiplier(); // no-arg cancels every pending class

        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Supply));
        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Yield));
    }

    function test_cancelViaBaseSelector_RevertsWhenNothingPending() public {
        vm.prank(owner);
        vm.expectRevert(ERC8056.NothingToCancel.selector);
        token.cancelPendingUIMultiplier();
    }

    //==============================================================================//
    // Legacy setter delegation + composite view parity (H3/M4)                     //
    //==============================================================================//

    /// @dev Documented deviation: the legacy 2-arg `setUIMultiplier(uint256,uint256)`
    ///      targets the Supply class instead of silently writing dead base storage.
    function test_LegacySetter_RoutesToSupplyClass() public {
        uint256 t = block.timestamp + 10;
        vm.prank(owner);
        token.setUIMultiplier(15e17, t); // legacy 2-arg signature
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Supply));
        assertEq(token.newUIMultiplier(MultiplierClass.Supply), 15e17);

        vm.warp(t);
        assertEq(token.uiScalingFactor(MultiplierClass.Supply), 15e17);
        // composite reflects it: Supply 15e17 * Yield 1e18 * Other 1e18 / 1e36
        assertEq(token.uiMultiplier(), 15e17);
        assertEq(token.balanceOfUI(holder), 150 ether);
    }

    /// @dev Documented deviation: composite `newUIMultiplier()` only counts classes
    ///      with a live pending announcement; already-activated classes contribute
    ///      their current active factor (vanilla intuition of "the upcoming update").
    function test_NewUIMultiplier_Composite_IgnoresStalePendings() public {
        uint256 tYield = block.timestamp + 100;
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, 2e18, tYield, "", "", "");

        vm.warp(tYield + 1); // Yield announcement activated: no longer pending
        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Yield));

        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, 1.5e18, block.timestamp + 200, "", "", "");
        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Yield));

        // 1.5e18 * activeYield(2e18) * 1e18 / 1e36 = 3e18; no stale Yield pending counted
        assertEq(token.newUIMultiplier(), 3e18);
        // current multiplier still excludes the pending Supply factor
        assertEq(token.uiMultiplier(), 2e18);
    }

    /// @dev Vanilla idiom restored byte-for-byte: `effectiveAt() != 0 ⇔ an update
    ///      is incoming`. Once every announcement lands or is cancelled, the view
    ///      drops back to 0 even though real events remain in history.
    function test_EffectiveAt_Composite_SentinelRestoredWhenIdle() public {
        assertEq(token.effectiveAt(), 0); // genesis-only history

        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, DOUBLE, 1 hours);
        assertEq(token.effectiveAt(), tYield); // earliest (only) pending

        vm.warp(tYield); // event activates, nothing left pending
        assertFalse(token.hasPendingUIMultiplier(MultiplierClass.Yield));
        assertEq(token.effectiveAt(), 0);

        vm.warp(tYield + 30 days);
        assertEq(token.effectiveAt(), 0); // stays 0 while nothing is pending
    }

    /// @dev With live pendings on multiple classes, `effectiveAt()` surfaces the
    ///      earliest timestamp (the moment anything changes).
    function test_EffectiveAt_Composite_MultiClassPendingSurfacesEarliest() public {
        uint256 tLater = block.timestamp + 10 hours;
        uint256 tEarlier = block.timestamp + 2 hours;
        vm.startPrank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, tLater, "", "", "");
        token.setUIMultiplier(MultiplierClass.Other, 3 * NEUTRAL, tEarlier, "", "", "");
        vm.stopPrank();

        assertEq(token.effectiveAt(), tEarlier);

        vm.warp(tEarlier); // Other lands, Yield still pending
        assertEq(token.effectiveAt(), tLater);

        vm.warp(tLater); // everything landed
        assertEq(token.effectiveAt(), 0);
        assertEq(token.uiMultiplier(), 6e18);
    }

    /// @dev Idle-state parity: with nothing pending anywhere, `newUIMultiplier()`
    ///      must equal the ACTIVE composite (vanilla clients pricing off it see
    ///      today's denomination), not any projection of past announcements.
    function test_NewUIMultiplier_Composite_IdleReturnsActiveComposite() public {
        uint256 tYield = _scheduleMultiplier(MultiplierClass.Yield, 3 * NEUTRAL, 1 hours);
        vm.warp(tYield + 1); // lands; still a second stale-era announcement below

        uint256 tSupply = _scheduleMultiplier(MultiplierClass.Supply, DOUBLE, 1 hours);
        vm.warp(tSupply); // lands; final state Y=3x, S=2x, nothing pending

        assertTrue(!token.hasPendingUIMultiplier(MultiplierClass.Yield));
        assertTrue(!token.hasPendingUIMultiplier(MultiplierClass.Supply));
        assertEq(token.uiMultiplier(), 6e18);
        assertEq(token.newUIMultiplier(), 6e18);
        assertEq(token.effectiveAt(), 0);
    }

    //==============================================================================//
    // Issuer notice period (L3)                                                   //
    //==============================================================================//

    function test_noticePeriod_defaultZero_allowsImmediateSchedule() public {
        assertEq(token.minNoticePeriod(), 0);
        uint256 effectiveAt = block.timestamp + 1;
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, effectiveAt, "", "", "");
        assertTrue(token.hasPendingUIMultiplier(MultiplierClass.Yield));
    }

    function test_noticePeriod_enforced_afterRaise() public {
        vm.prank(owner);
        token.setMinNoticePeriod(1 days);
        assertEq(token.minNoticePeriod(), 1 days);

        // too-soon announcement rejected even though it lands in the future
        vm.prank(owner);
        vm.expectRevert(ERC8056Composite.NoticePeriodTooShort.selector);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 1 hours, "", "", "");

        // compliant announcement accepted (boundary inclusive)
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Yield, DOUBLE, effectiveAt, "", "", "");
        assertEq(token.effectiveAt(MultiplierClass.Yield), effectiveAt);
    }

    function test_noticePeriod_loweringBackToZero_restoresVanillaBehavior() public {
        vm.startPrank(owner);
        token.setMinNoticePeriod(30 days);
        token.setMinNoticePeriod(0);
        token.setUIMultiplier(MultiplierClass.Other, DOUBLE, block.timestamp + 1, "", "", "");
        vm.stopPrank();
    }

    function test_noticePeriod_setter_isOwnerOnly_andEmitsEvent() public {
        vm.prank(holder);
        vm.expectRevert();
        token.setMinNoticePeriod(1 days);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC8056Composite.MinimumNoticePeriodSet(0, 2 hours);
        token.setMinNoticePeriod(2 hours);
    }

    function test_noticePeriod_setter_rejectsAbsurdValues() public {
        vm.prank(owner);
        vm.expectRevert(ERC8056Composite.NoticePeriodTooLong.selector);
        token.setMinNoticePeriod(3651 days);

        vm.prank(owner);
        token.setMinNoticePeriod(3650 days); // cap inclusive
    }

    //==============================================================================//
    // Lazy genesis: upgrade from vanilla ERC8056 proxy                             //
    //==============================================================================//

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_UpgradeFromVanilla_ThenSchedule_Works() public {
        // 1. deploy vanilla ERC8056 behind ERC1967Proxy (as issuer would in prod)
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        // vanilla has no initializer: replicate its constructor-initialized owner
        // storage in the proxy (slot 5 = Ownable._owner per ERC8056 layout)
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        vm.prank(owner);
        upgraded.mint(holder, RAW_STAKE);

        // 2. upgrade implementation slot to a fresh ERC8056Composite
        //    (constructor runs on the impl only, proxy storage untouched)
        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));

        // genesis reads on the upgraded proxy must be neutral
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(upgraded.uiMultiplier(), NEUTRAL);
        assertEq(upgraded.newUIMultiplier(MultiplierClass.Yield), NEUTRAL);
        assertEq(upgraded.getClassNonce(MultiplierClass.Yield), 0);

        // 3. first schedule must NOT revert with ZeroFactor
        uint256 effectiveAt = block.timestamp + 10;
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Yield, DOUBLE, effectiveAt, "", "", "");

        assertEq(upgraded.newUIMultiplier(MultiplierClass.Yield), DOUBLE);
        assertTrue(upgraded.hasPendingUIMultiplier(MultiplierClass.Yield));

        vm.warp(effectiveAt + 1);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), DOUBLE);
        assertEq(upgraded.getClassNonce(MultiplierClass.Yield), 1);
        assertEq(upgraded.uiMultiplier(), DOUBLE);
        // other classes lazily genesis at 1e18
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Supply), NEUTRAL);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Other), NEUTRAL);
        assertEq(upgraded.balanceOfUI(holder), 200 ether);

        // 4. second schedule + cancel cycle works on the bootstrapped state
        effectiveAt = block.timestamp + 10;
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Yield, 4 * NEUTRAL, effectiveAt, "", "", "");

        vm.prank(owner);
        upgraded.cancelPendingUIMultiplier(MultiplierClass.Yield);

        assertFalse(upgraded.hasPendingUIMultiplier(MultiplierClass.Yield));
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), DOUBLE);
        assertEq(upgraded.uiMultiplier(), DOUBLE);

        // cancelled schedule stays cancelled past its would-be effective time
        vm.warp(effectiveAt + 1);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), DOUBLE);
        assertEq(upgraded.uiMultiplier(), DOUBLE);

        // a fresh schedule still activates normally
        effectiveAt = block.timestamp + 10;
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Yield, 4 * NEUTRAL, effectiveAt, "", "", "");
        vm.warp(effectiveAt + 1);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), 4 * NEUTRAL);
        assertEq(upgraded.uiMultiplier(), 4 * NEUTRAL);
    }

    /// @dev Regression: on a freshly-upgraded proxy (empty checkpoint history),
    ///      nonce 0 must resolve to a synthetic neutral genesis event instead of
    ///      reverting `EventNotRecorded` — otherwise degenerate wrapper windows
    ///      (0,0) brick funds.
    function test_UpgradeFromVanilla_ClassEventAtNonceZero_SyntheticGenesis() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        assertEq(upgraded.scalingHistoryLength(MultiplierClass.Yield), 0);

        IERC8056Composite.ClassScalingEvent memory ev = upgraded.classEventAtNonce(MultiplierClass.Yield, 0);
        assertEq(ev.timestamp, 0);
        assertEq(ev.cumulativeMultiplier, NEUTRAL);
        assertEq(ev.multiplierRatio, 0);

        // per-class nonce-0 read also stays neutral instead of reverting
        assertEq(upgraded.uiMultiplierAtNonce(MultiplierClass.Yield, 0), NEUTRAL);
        // non-zero nonces still revert on empty history
        vm.expectRevert(ERC8056Composite.EventNotRecorded.selector);
        upgraded.classEventAtNonce(MultiplierClass.Yield, 1);
    }

    /// @dev M1: between the beacon/proxy swap and the first schedule, composite
    ///      reads must reflect the inherited vanilla multiplier from the dead base
    ///      slots instead of returning neutral — otherwise third-party UI
    ///      accounting silently halves/doubles during the migration window.
    function test_UpgradeFromVanilla_PreBootstrap_ReadsInheritVanillaMultiplier() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        // Vanilla live multiplier of 3x, no pending update (see C-M3 test layout).
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        vm.store(address(proxy), bytes32(uint256(6)), bytes32(uint256(3 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(7)), bytes32(uint256(3 * NEUTRAL)));

        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        // Pre-bootstrap: vanilla denomination must survive immediately.
        assertEq(upgraded.uiMultiplier(), 3 * NEUTRAL);
        assertEq(upgraded.newUIMultiplier(), 3 * NEUTRAL);
        assertEq(upgraded.effectiveAt(), 0);

        vm.prank(owner);
        upgraded.mint(holder, RAW_STAKE);
        assertEq(upgraded.balanceOfUI(holder), 300 ether);
        assertEq(upgraded.totalSupplyUI(), 300 ether);
        assertEq(upgraded.toUIAmount(RAW_STAKE), 3 * RAW_STAKE);
        assertEq(upgraded.fromUIAmount(300 ether), RAW_STAKE);

        // Class factor views compose coherently during the window: Supply carries
        // the inherited vanilla denomination; other classes stay neutral.
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Supply), 3 * NEUTRAL);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(upgraded.scalingHistoryLength(MultiplierClass.Yield), 0);
        assertEq(upgraded.getClassNonce(MultiplierClass.Yield), 0);
    }

    /// @dev M1 variant: a vanilla token upgraded while a live PENDING announcement
    ///      sits in the base slots keeps observing it through composite reads
    ///      until the first schedule lands (vanilla value/semantics preserved).
    function test_UpgradeFromVanilla_PreBootstrap_VanillaPendingObservable() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        uint256 ts = block.timestamp;
        uint256 pendEff = ts + 30 days;
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        vm.store(address(proxy), bytes32(uint256(6)), bytes32(uint256(2 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(7)), bytes32(uint256(3 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(8)), bytes32(uint256(pendEff)));

        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        // Active 2x now; pending 3x visible at its future effective time.
        assertEq(upgraded.uiMultiplier(), 2 * NEUTRAL);
        assertEq(upgraded.newUIMultiplier(), 3 * NEUTRAL);
        assertEq(upgraded.effectiveAt(), pendEff);

        vm.warp(pendEff + 1);
        assertEq(upgraded.uiMultiplier(), 3 * NEUTRAL);

        // First schedule behaves as before and takes over the bookkeeping.
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 10, "", "", "");
        vm.warp(block.timestamp + 11);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Supply), DOUBLE);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(upgraded.uiMultiplier(), DOUBLE);
    }

    /// @dev M1 safety edge: a proxy upgraded but never initialized in vanilla
    ///      (zero multiplier slots) still reads neutral instead of a 0x factor.
    function test_UpgradeFromVanilla_PreBootstrap_UninitializedStaysNeutral() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        assertEq(upgraded.uiMultiplier(), NEUTRAL);
        assertEq(upgraded.balanceOfUI(holder), RAW_STAKE - RAW_STAKE + 0); // holder unminted
        assertEq(upgraded.toUIAmount(RAW_STAKE), RAW_STAKE);
    }

    /// @dev Direct deploys are seeded by the constructor and never see the
    ///      inheritance path; ensure overrides leave their behavior untouched.
    function test_DirectDeploy_PostConstructorReadsNeutral() public view {
        assertEq(token.uiMultiplier(), NEUTRAL);
        assertEq(token.newUIMultiplier(), NEUTRAL);
        assertEq(token.effectiveAt(), 0);
        assertEq(token.totalSupplyUI(), RAW_STAKE);
    }

    /// @dev C-M3: a non-neutral vanilla multiplier must survive the upgrade as the
    ///      Supply-class genesis factor, so the pre-upgrade UI denomination is kept.
    function test_UpgradeFromVanilla_NonNeutralMultiplier_CarriedToSupply() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        // Faithfully initialize the proxy's vanilla state (constructor ran via proxy
        // in production): owner (slot 5) + live multiplier 3e18 (slot 6) + neutral
        // pending (slot 7). Slots per `forge inspect ERC8056 storage-layout`.
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        vm.store(address(proxy), bytes32(uint256(6)), bytes32(uint256(3 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(7)), bytes32(uint256(3 * NEUTRAL)));

        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        uint256 effectiveAt = block.timestamp + 10;
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Yield, DOUBLE, effectiveAt, "", "", "");
        vm.warp(effectiveAt + 1);

        // Supply inherited the 3x vanilla multiplier; Yield = 2x; Other neutral.
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Supply), 3 * NEUTRAL);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), DOUBLE);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Other), NEUTRAL);
        assertEq(upgraded.uiMultiplier(), 6 * NEUTRAL);
    }

    /// @dev Regression: the composite-at-nonce composition mixes factors from
    ///      divergent eras; extreme combinations saturate at type(uint256).max in
    ///      the VIEW rather than panicking or reverting, while every individual
    ///      schedule still passes the schedule-time overflow guard.
    function test_UiMultiplierAtNonce_SaturatesInsteadOfReverting() public {
        // era 1: Supply = 1e38
        _scheduleScalingFactor(MultiplierClass.Supply, 1e38, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        // era 2: markdown Supply to 1
        _scheduleScalingFactor(MultiplierClass.Supply, 1, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        // grow Yield to 1e58: safe at schedule time (Supply is marked down to 1),
        // but era-1 Supply (1e38) x era-3 Yield (1e58) overflows the composite
        _scheduleScalingFactor(MultiplierClass.Yield, 1e58, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        assertEq(token.getClassNonce(MultiplierClass.Supply), 2);
        assertEq(token.getClassNonce(MultiplierClass.Yield), 1);

        // era 1: Supply 1e38 x Yield 1e58 x Other 1e18 overflows -> saturated
        assertEq(token.uiMultiplierAtNonce(1), type(uint256).max);
        // era 2 (current): Supply 1 -> composite exactly representable (1e40)
        assertEq(token.uiMultiplierAtNonce(2), 1e40);
        assertEq(token.uiMultiplierAtNonce(99), token.uiMultiplier());
        // live path unaffected: active Supply is 1, so composite is exact
        assertEq(token.uiMultiplier(), 1e40);
    }

    //==============================================================================//
    // Schedule-time composite overflow guard                                       //
    //==============================================================================//
    function test_Schedule_CompositeOverflowRevertsCustomErrorNotPanic() public {
        uint256 big = 1e38;
        vm.startPrank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, big, block.timestamp + 1 days, "", "", "");
        token.setUIMultiplier(MultiplierClass.Yield, big, block.timestamp + 2 days, "", "", "");
        // pending composite ~1e58; scheduling Other = 2e37 makes the next composite
        // ~2e77 > 2^256, which the corrected guard must reject with a clear error.
        vm.expectRevert(ERC8056Composite.CompositeOverflow.selector);
        token.setUIMultiplier(MultiplierClass.Other, 2e37, block.timestamp + 3 days, "", "", "");
        vm.stopPrank();
    }

    /// @dev The corrected (1e18-scaled) guard must NOT reject valid extreme schedules
    ///      that stay safely below 2^256: Supply=1e20, Other=1e20, Yield=1e60 -> ~1e64.
    function test_Schedule_ValidExtremeCompositeAccepted() public {
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.startPrank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, 1e20, effectiveAt, "", "", "");
        token.setUIMultiplier(MultiplierClass.Other, 1e20, effectiveAt, "", "", "");
        // Must succeed (no revert): this previously failed under the off-by-1e18 guard.
        token.setUIMultiplier(MultiplierClass.Yield, 1e60, effectiveAt, "", "", "");
        vm.stopPrank();
        assertEq(token.newUIMultiplier(MultiplierClass.Yield), 1e60);
    }

    function test_Schedule_OverflowGuardDoesNotBlockReasonableSchedules() public {
        uint256 effectiveAt = block.timestamp + 1 days;
        vm.startPrank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, 10e18, effectiveAt, "", "", "");
        token.setUIMultiplier(MultiplierClass.Yield, 10e18, effectiveAt, "", "", "");
        vm.stopPrank();
        assertEq(token.newUIMultiplier(), 100e18);
    }

    function test_fuzz_Conversion_RoundTrip(uint256 x, uint256 factor) public pure {
        x = bound(x, 0, 1e30);
        // factor <= MULTIPLIER_DECIMALS guarantees a <= 1 wei round-trip loss:
        // raw = floor(x*D/f), back = floor(raw*f/D); combined error < f/D <= 1
        factor = bound(factor, 1, NEUTRAL);
        uint256 raw = UIScalingMath.fromUIAmount(x, factor);
        uint256 back = UIScalingMath.toUIAmount(raw, factor);
        assertLe(back, x);
        assertLe(x - back, 1);
    }

    function test_fuzz_TokenConversion_RoundTrip(uint256 x) public {
        x = bound(x, 0, 1e24);
        vm.prank(owner);
        token.setUIMultiplier(MultiplierClass.Supply, HALF, block.timestamp + 1 hours, "", "", "");
        vm.warp(block.timestamp + 2 hours);
        assertEq(token.uiMultiplier(), HALF);

        uint256 raw = token.fromUIAmount(x);
        uint256 back = token.toUIAmount(raw);
        assertLe(back, x);
        assertLe(x - back, 1);
    }

    //==============================================================================//
    // Seamless retrocompat: bootstrap guard (R-guard)                              //
    //==============================================================================//

    function _upgradeVanillaProxyWithPending()
        internal
        returns (ERC1967Proxy proxy, ERC8056Composite upgraded, uint256 pendEff)
    {
        proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        uint256 ts = block.timestamp;
        pendEff = ts + 30 days;
        // vanilla layout: slot 5 owner, 6 _uiMultiplier, 7 _newUIMultiplier, 8 _effectiveAt
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        vm.store(address(proxy), bytes32(uint256(6)), bytes32(uint256(2 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(7)), bytes32(uint256(3 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(8)), bytes32(uint256(pendEff)));

        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        upgraded = ERC8056Composite(address(proxy));
    }

    /// @dev A live vanilla pending must never be silently abandoned by the lazy
    ///      genesis: the first classed schedule reverts until the issuer lands
    ///      or cancels it.
    function test_UpgradeFromVanilla_LivePending_FirstClassedScheduleReverts() public {
        (, ERC8056Composite upgraded, uint256 pendEff) = _upgradeVanillaProxyWithPending();

        assertEq(upgraded.scalingHistoryLength(MultiplierClass.Supply), 0); // unbootstrapped

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC8056Composite.VanillaPendingUpdate.selector, pendEff));
        upgraded.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 10, "", "", "");

        // class-scoped setter is equally guarded
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC8056Composite.VanillaPendingUpdate.selector, pendEff));
        upgraded.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 10, "", "", "");
    }

    /// @dev Resolution path 1: letting the vanilla update land naturally unblocks
    ///      the first classed schedule.
    function test_UpgradeFromVanilla_LandedPending_FirstClassedScheduleSucceeds() public {
        (, ERC8056Composite upgraded, uint256 pendEff) = _upgradeVanillaProxyWithPending();

        vm.warp(pendEff + 1); // vanilla announcement activates; pending no longer live
        assertEq(upgraded.uiMultiplier(), 3 * NEUTRAL);

        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Yield, DOUBLE, block.timestamp + 10, "", "", "");
        assertTrue(upgraded.hasPendingUIMultiplier(MultiplierClass.Yield));
    }

    /// @dev Resolution path 2: cancelling via the legacy entrypoint unblocks the
    ///      first classed schedule. The cancel itself must NOT be guarded.
    function test_UpgradeFromVanilla_CancelledPending_FirstClassedScheduleSucceeds() public {
        (, ERC8056Composite upgraded,) = _upgradeVanillaProxyWithPending();

        vm.prank(owner);
        upgraded.cancelPendingUIMultiplier(); // legacy cancel resolves the conflict
        assertEq(upgraded.uiMultiplier(), 2 * NEUTRAL);

        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Supply, DOUBLE, block.timestamp + 10, "", "", "");
        assertTrue(upgraded.hasPendingUIMultiplier(MultiplierClass.Supply));
    }

    //==============================================================================//
    // Seamless retrocompat: migration-window per-class coherence (R-cohere)        //
    //==============================================================================//

    /// @dev During the migration window the per-class factor views must compose
    ///      to exactly `uiMultiplier()` — the Supply factor carries the inherited
    ///      vanilla denomination instead of reading a misleading neutral.
    function test_UpgradeFromVanilla_PreBootstrap_PerClassViewsCoherentWithComposite() public {
        vm.warp(10 days); // give the window an interior for historical reads
        ERC1967Proxy proxy = new ERC1967Proxy(address(new ERC8056("v", "V", owner)), "");
        vm.store(address(proxy), bytes32(uint256(5)), bytes32(uint256(uint160(owner))));
        vm.store(address(proxy), bytes32(uint256(6)), bytes32(uint256(3 * NEUTRAL)));
        vm.store(address(proxy), bytes32(uint256(7)), bytes32(uint256(3 * NEUTRAL)));
        address compositeImpl = address(new ERC8056Composite("v", "V", owner));
        vm.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(compositeImpl))));
        ERC8056Composite upgraded = ERC8056Composite(address(proxy));

        assertEq(upgraded.uiMultiplier(), 3 * NEUTRAL);

        // Supply factor reports the inherited denomination; others stay neutral.
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Supply), 3 * NEUTRAL);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Yield), NEUTRAL);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Other), NEUTRAL);

        // Product of factors == composite, at the live timestamp...
        uint256 product = UIScalingMath.composeUiMultiplier(
            upgraded.uiScalingFactorAt(MultiplierClass.Supply, block.timestamp),
            upgraded.uiScalingFactorAt(MultiplierClass.Yield, block.timestamp),
            upgraded.uiScalingFactorAt(MultiplierClass.Other, block.timestamp)
        );
        assertEq(product, upgraded.uiMultiplier());

        // ...and at an arbitrary historical timestamp via the paired views.
        uint256 past = block.timestamp - 1 days;
        assertEq(
            UIScalingMath.composeUiMultiplier(
                upgraded.uiMultiplierAt(MultiplierClass.Supply, past),
                upgraded.uiMultiplierAt(MultiplierClass.Yield, past),
                upgraded.uiMultiplierAt(MultiplierClass.Other, past)
            ),
            upgraded.uiMultiplierAt(past)
        );

        // Post-bootstrap everything switches over in lockstep.
        uint256 tSupply = block.timestamp + 10;
        vm.prank(owner);
        upgraded.setUIMultiplier(MultiplierClass.Supply, DOUBLE, tSupply, "", "", "");
        vm.warp(tSupply + 1);
        assertEq(upgraded.uiScalingFactor(MultiplierClass.Supply), DOUBLE);
        assertEq(
            UIScalingMath.composeUiMultiplier(
                upgraded.uiScalingFactor(MultiplierClass.Supply),
                upgraded.uiScalingFactor(MultiplierClass.Yield),
                upgraded.uiScalingFactor(MultiplierClass.Other)
            ),
            upgraded.uiMultiplier()
        );
    }
}
