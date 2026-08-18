// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Optional extension interface for EIP-8056: On-chain UI balance queries.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * Interface ID: 0xd890fd71
 */
interface IScaledUIAmountBalances {
    /**
     * @dev Returns the UI-adjusted balance of an account.
     */
    function balanceOfUI(address account) external view returns (uint256);

    /**
     * @dev Returns the UI-adjusted total supply.
     */
    function totalSupplyUI() external view returns (uint256);
}
