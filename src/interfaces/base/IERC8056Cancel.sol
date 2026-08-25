// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Optional cancel extension for EIP-8056: Pending Multiplier.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 */
interface IERC8056Cancel {
    /**
     * @dev Emitted when a pending UI multiplier update is cancelled.
     * @param previousMultiplier The multiplier that was pending and is now discarded
     * @param restoredMultiplier The multiplier restored as the current effective value
     * @param cancelledAtTimestamp The block.timestamp when the cancellation occurred
     */
    event UIMultiplierCancelled(uint256 previousMultiplier, uint256 restoredMultiplier, uint256 cancelledAtTimestamp);

    /**
     * @dev Cancels a pending multiplier update, restoring the current effective multiplier.
     * Reverts if no pending update exists.
     */
    function cancelPendingUIMultiplier() external;
}
