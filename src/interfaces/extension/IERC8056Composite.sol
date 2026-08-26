// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MultiplierClass} from "./IERC8056MultiplierClass.sol";

/**
 * @dev Extension interface for decomposed UI scaling (EIP-8056 improvement).
 *
 * All scaling updates MUST specify a {MultiplierClass}. There is no generic
 * monolithic multiplier update entrypoint. The composite {IERC8056-uiMultiplier}
 * is always derived as the product of every class factor (Supply × Yield × Other).
 */
interface IERC8056Composite {
    struct ScalingCheckpoint {
        uint256 effectiveAt;
        uint256 cumulativeMultiplier;
        uint256 multiplierRatio;
    }

    struct ClassScalingEvent {
        uint256 timestamp;
        uint256 cumulativeMultiplier;
        uint256 multiplierRatio;
    }

    struct Announcement {
        string id;
        string description;
        string uri;
    }

    event UIScalingFactorUpdated(
        MultiplierClass indexed scalingClass,
        uint256 newMultiplier,
        uint256 multiplierRatio,
        uint256 effectiveAtTimestamp,
        uint256 classNonce,
        Announcement announcement
    );

    /// @dev Emitted when a pending per-class scaling update is cancelled.
    event UIScalingFactorCancelled(
        MultiplierClass indexed scalingClass,
        uint256 previousMultiplier,
        uint256 restoredMultiplier,
        uint256 cancelledAtTimestamp
    );

    // ---- Per-class multiplier reads ----

    /// @dev Current cumulative multiplier for `scalingClass` (1e18 = 1.0x).
    function uiScalingFactor(MultiplierClass scalingClass) external view returns (uint256);

    /// @dev Cumulative multiplier for `scalingClass` as it was at `timestamp` (inclusive).
    ///      Uses binary search over checkpoint history.
    function uiScalingFactorAt(MultiplierClass scalingClass, uint256 timestamp) external view returns (uint256);

    // ---- Base 8056 overloads (retro-compatible naming) ----

    /// @dev Composite multiplier at `timestamp` = product of all class factors at that time.
    function uiMultiplierAt(uint256 timestamp) external view returns (uint256);

    /// @dev Cumulative multiplier for a single class at `timestamp`.
    ///      Overload of uiScalingFactorAt with consistent naming.
    function uiMultiplierAt(MultiplierClass scalingClass, uint256 timestamp) external view returns (uint256);

    /// @dev Current cumulative multiplier for a single class (alias for uiScalingFactor).
    function uiMultiplier(MultiplierClass scalingClass) external view returns (uint256);

    // ---- Nonce-based reads ----

    /// @dev Composite multiplier as of the era opened by the n-th event of any
    ///      class. Per class, the nonce is clamped to the class's current nonce,
    ///      so classes with fewer events contribute their latest factor. The
    ///      composition saturates at type(uint256).max rather than reverting,
    ///      even for extreme era-mixed factors or arbitrarily large nonces.
    function uiMultiplierAtNonce(uint256 nonce) external view returns (uint256);

    /// @dev Cumulative multiplier for a single class at a past nonce.
    ///      Nonce is 1-based (genesis is not an event).
    function uiMultiplierAtNonce(MultiplierClass scalingClass, uint256 nonce) external view returns (uint256);

    /// @dev Number of effective scaling events for `scalingClass` (derived count
    ///      from checkpoint history). Genesis (index 0) is not counted; only
    ///      effective checkpoints tick the nonce.
    function getClassNonce(MultiplierClass scalingClass) external view returns (uint256);

    /// @dev Scaling event for `scalingClass` at 1-based `nonce` (genesis is not an event;
    ///      nonce 0 returns the genesis checkpoint).
    ///      Returns `{timestamp, cumulativeMultiplier, multiplierRatio}`. If no
    ///      checkpoint history exists yet (freshly-upgraded proxy), nonce 0
    ///      returns a synthetic neutral genesis `{0, 1e18, 0}`. Reverts if not
    ///      recorded or not yet effective.
    function classEventAtNonce(MultiplierClass scalingClass, uint256 nonce)
        external
        view
        returns (ClassScalingEvent memory);

    // ---- Pending / history views ----

    /// @dev Pending cumulative multiplier scheduled for `scalingClass`.
    function newUIMultiplier(MultiplierClass scalingClass) external view returns (uint256);

    /// @dev When the pending multiplier for `scalingClass` becomes effective (0 if none).
    function effectiveAt(MultiplierClass scalingClass) external view returns (uint256);

    /// @dev True when `scalingClass` has a scheduled update not yet active.
    function hasPendingUIMultiplier(MultiplierClass scalingClass) external view returns (bool);

    /// @dev Number of historical checkpoints recorded for `scalingClass` (includes genesis).
    function scalingHistoryLength(MultiplierClass scalingClass) external view returns (uint256);

    /// @dev Returns checkpoint `index` for `scalingClass` (0 = genesis at effectiveAt 0).
    function scalingCheckpointAt(MultiplierClass scalingClass, uint256 index)
        external
        view
        returns (ScalingCheckpoint memory);

    // ---- State-changing: schedule updates ----

    function setUIMultiplier(
        MultiplierClass scalingClass,
        uint256 newMultiplier,
        uint256 effectiveAtTimestamp,
        string calldata id,
        string calldata description,
        string calldata uri
    ) external;

    // ---- State-changing: cancel pending ----

    /// @dev Cancels the pending scaling update for `scalingClass`, restoring the active factor.
    ///      Reverts if no pending update exists for the class.
    function cancelPendingUIMultiplier(MultiplierClass scalingClass) external;

    // ---- Issuer notice period (optional self-restraint) ----

    /// @dev Emitted when the issuer changes the minimum notice every future
    ///      announcement must provide between scheduling and its effective time.
    event MinimumNoticePeriodSet(uint256 previousPeriod, uint256 newPeriod);

    /// @dev Minimum delay an announcement MUST give between its schedule call
    ///      and its effective time. Defaults to 0 (vanilla-compatible). The
    ///      issuer may raise it to publicly bound its own power to reprice open
    ///      Yield windows with near-zero notice.
    function minNoticePeriod() external view returns (uint256);

    /// @dev Sets the minimum notice period. Reverts above a hard cap of 3650 days.
    function setMinNoticePeriod(uint256 seconds_) external;
}
