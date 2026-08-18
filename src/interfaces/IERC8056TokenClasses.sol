// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UIScalingClass} from "./UIScalingClass.sol";

/**
 * @dev Extension interface for decomposed UI scaling (EIP-8056 improvement).
 *
 * All scaling updates MUST specify a {UIScalingClass}. There is no generic
 * monolithic multiplier update entrypoint. The composite {IERC8056-uiMultiplier}
 * is always derived as the product of every class factor (Supply × Yield × Other).
 */
interface IERC8056TokenClasses {
    struct ScalingCheckpoint {
        uint256 effectiveAt;
        uint256 cumulativeFactor;
    }

    struct YieldEvent {
        uint256 timestamp;
        uint256 multiplier;
    }

    event UIScalingFactorUpdated(
        UIScalingClass indexed scalingClass, uint256 oldFactor, uint256 newFactor, uint256 effectiveAtTimestamp
    );

    /// @dev Current cumulative factor for `scalingClass` (1e18 = 1.0x).
    function uiScalingFactor(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev Cumulative factor for `scalingClass` as it was at `timestamp` (inclusive).
    function uiScalingFactorAt(UIScalingClass scalingClass, uint256 timestamp) external view returns (uint256);

    /// @dev Composite multiplier at `timestamp` = product of all class factors at that time.
    function uiMultiplierAt(uint256 timestamp) external view returns (uint256);

    /// @dev Pending cumulative factor scheduled for `scalingClass`.
    function pendingUIScalingFactor(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev When the pending factor for `scalingClass` becomes effective (0 if none).
    function scalingFactorEffectiveAt(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev True when `scalingClass` has a scheduled update not yet active.
    function hasPendingScalingFactor(UIScalingClass scalingClass) external view returns (bool);

    /// @dev Number of historical checkpoints recorded for `scalingClass` (includes genesis).
    function scalingHistoryLength(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev Returns checkpoint `index` for `scalingClass` (0 = genesis at effectiveAt 0).
    function scalingCheckpointAt(UIScalingClass scalingClass, uint256 index)
        external
        view
        returns (ScalingCheckpoint memory);

    /// @dev Yield events that have become effective so far (the "nonce"). 0 before the first dividend.
    function yieldNonce() external view returns (uint256);

    /// @dev Yield event with 1-based `nonce` (genesis is not an event).
    ///      Reverts if the event is not recorded or not yet effective.
    function yieldEventAt(uint256 nonce) external view returns (YieldEvent memory);

    /**
     * @dev Schedule an absolute cumulative factor for `scalingClass`.
     *
     * Supply example: 2-for-1 split sets factor from 1e18 to 2e18.
     * Yield example: reinvestment sets factor from 1e18 to 1.05e18.
     */
    function setUIScalingFactor(UIScalingClass scalingClass, uint256 newFactor, uint256 effectiveAtTimestamp) external;

    /// @dev Schedule a relative delta: `newFactor = current * factorDelta / 1e18`.
    function applyUIScalingDelta(UIScalingClass scalingClass, uint256 factorDelta, uint256 effectiveAtTimestamp)
        external;
}
