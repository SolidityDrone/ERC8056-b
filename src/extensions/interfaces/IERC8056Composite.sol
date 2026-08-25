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
interface IERC8056Composite {
    struct ScalingCheckpoint {
        uint256 effectiveAt;
        uint256 cumulativeFactor;
    }

    struct ClassScalingEvent {
        uint256 timestamp;
        uint256 cumulativeFactor;
    }

    struct Announcement {
        string id;
        string description;
        string uri;
    }

    event UIScalingFactorUpdated(
        UIScalingClass indexed scalingClass,
        uint256 newMultiplier,
        uint256 multiplierDelta,
        uint256 effectiveAtTimestamp,
        uint256 classNonce,
        Announcement announcement
    );

    // ---- Per-class multiplier reads ----

    /// @dev Current cumulative multiplier for `scalingClass` (1e18 = 1.0x).
    function uiScalingFactor(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev Cumulative multiplier for `scalingClass` as it was at `timestamp` (inclusive).
    ///      Uses binary search over checkpoint history.
    function uiScalingFactorAt(UIScalingClass scalingClass, uint256 timestamp) external view returns (uint256);

    // ---- Base 8056 overloads (retro-compatible naming) ----

    /// @dev Composite multiplier at `timestamp` = product of all class factors at that time.
    function uiMultiplierAt(uint256 timestamp) external view returns (uint256);

    /// @dev Cumulative multiplier for a single class at `timestamp`.
    ///      Overload of uiScalingFactorAt with consistent naming.
    function uiMultiplierAt(UIScalingClass scalingClass, uint256 timestamp) external view returns (uint256);

    /// @dev Current cumulative multiplier for a single class (alias for uiScalingFactor).
    function uiMultiplier(UIScalingClass scalingClass) external view returns (uint256);

    // ---- Nonce-based reads ----

    /// @dev Composite multiplier at a past nonce = product of all class factors at that nonce.
    ///      Nonce is 1-based (genesis is not an event).
    function uiMultiplierAtNonce(uint256 nonce) external view returns (uint256);

    /// @dev Cumulative multiplier for a single class at a past nonce.
    ///      Nonce is 1-based (genesis is not an event).
    function uiMultiplierAtNonce(UIScalingClass scalingClass, uint256 nonce) external view returns (uint256);

    /// @dev Number of effective scaling events for `scalingClass` (stored counter).
    ///      Genesis (index 0) is not counted; only effective checkpoints tick the nonce.
    function getClassNonce(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev Scaling event for `scalingClass` at 1-based `nonce` (genesis is not an event).
    ///      Returns `{timestamp, cumulativeMultiplier}`. Reverts if not recorded or not yet effective.
    function classEventAtNonce(UIScalingClass scalingClass, uint256 nonce)
        external
        view
        returns (ClassScalingEvent memory);

    // ---- Pending / history views ----

    /// @dev Pending cumulative multiplier scheduled for `scalingClass`.
    function newUIMultiplier(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev When the pending multiplier for `scalingClass` becomes effective (0 if none).
    function effectiveAt(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev True when `scalingClass` has a scheduled update not yet active.
    function hasPendingUIMultiplier(UIScalingClass scalingClass) external view returns (bool);

    /// @dev Number of historical checkpoints recorded for `scalingClass` (includes genesis).
    function scalingHistoryLength(UIScalingClass scalingClass) external view returns (uint256);

    /// @dev Returns checkpoint `index` for `scalingClass` (0 = genesis at effectiveAt 0).
    function scalingCheckpointAt(UIScalingClass scalingClass, uint256 index)
        external
        view
        returns (ScalingCheckpoint memory);

    // ---- State-changing: schedule updates ----

    function setUIMultiplier(
        UIScalingClass scalingClass,
        uint256 newMultiplier,
        uint256 effectiveAtTimestamp,
        string calldata id,
        string calldata description,
        string calldata uri
    ) external;

    /// @dev Schedule a relative delta: `newMultiplier = current * multiplierDelta / 1e18`.
    function applyUIMultiplierDelta(
        UIScalingClass scalingClass,
        uint256 multiplierDelta,
        uint256 effectiveAtTimestamp,
        string calldata id,
        string calldata description,
        string calldata uri
    ) external;
}
