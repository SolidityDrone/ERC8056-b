// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Optional extension interface for EIP-8056: On-chain amount conversion.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * Interface ID: 0x57854fc3
 */
interface IERC8056Conversion {
    /**
     * @dev Converts a raw token amount to its UI representation.
     */
    function toUIAmount(uint256 rawAmount) external view returns (uint256);

    /**
     * @dev Converts a UI amount back to its raw token amount.
     */
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}
