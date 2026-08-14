// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev UI scaling decomposition for EIP-8056.
 *
 * - `Supply`: off-chain supply / denomination events (splits, reverse splits,
 *   ADR ratio changes, unit redenomination). Same economics, different count.
 * - `Yield`: off-chain accretion (dividend reinvestment, DRIP, distributions,
 *   pro-rata buyback benefit). Backing pool grew pro-rata.
 *
 * Composite `uiMultiplier()` = Supply * Yield (18-decimal fixed point each).
 * Mint/burn handles redemption and supply changes on-chain; these classes only
 * adjust the UI display layer.
 */
enum UIScalingClass {
    Supply,
    Yield
}
