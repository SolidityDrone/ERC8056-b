// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Core interface for EIP-8056 Scaled UI Amount Extension.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * Interface ID: 0xa60bf13d
 */
interface IERC8056 {
    /**
     * @dev Emitted when the UI multiplier is updated or initialized.
     * @param oldMultiplier The previous multiplier value. A value of 0 indicates
     * initialization (no prior multiplier exists).
     * @param newMultiplier The new multiplier value scheduled to take effect
     * @param effectiveAtTimestamp The timestamp when the new multiplier becomes active
     */
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    /**
     * @dev OPTIONAL. Emitted during a token transfer with the UI-adjusted amount.
     * @param from Sender address (zero address for mints)
     * @param to Recipient address (zero address for burns)
     * @param amount Raw token amount transferred
     * @param uiAmount UI-adjusted amount at the time of transfer
     */
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);

    /**
     * @dev Returns the current UI multiplier.
     * Multiplier is represented with 18 decimals (1e18 = 1.0).
     */
    function uiMultiplier() external view returns (uint256);
}
