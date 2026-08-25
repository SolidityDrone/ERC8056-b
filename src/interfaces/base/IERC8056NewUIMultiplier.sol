// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Required extension interface for EIP-8056: Pending Multiplier.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * Interface ID: 0x4bd27648
 */
interface IERC8056NewUIMultiplier {
    /**
     * @dev Emitted when a pending UI multiplier update is cancelled.
     * @param previousMultiplier The multiplier that was pending and is now discarded
     * @param restoredMultiplier The multiplier restored as the current effective value
     * @param cancelledAtTimestamp The block.timestamp when the cancellation occurred
     */
    event UIMultiplierCancelled(uint256 previousMultiplier, uint256 restoredMultiplier, uint256 cancelledAtTimestamp);

    /**
     * @dev Returns the pending UI multiplier scheduled to take effect at {effectiveAt}.
     * Multiplier is represented with 18 decimals (1e18 = 1.0).
     */
    function newUIMultiplier() external view returns (uint256);

    /**
     * @dev Returns the timestamp at which the pending multiplier becomes effective.
     */
    function effectiveAt() external view returns (uint256);

    /**
     * @dev Cancels a pending multiplier update, restoring the current effective multiplier.
     * Reverts if no pending update exists.
     */
    function cancelPendingUIMultiplier() external;
}
