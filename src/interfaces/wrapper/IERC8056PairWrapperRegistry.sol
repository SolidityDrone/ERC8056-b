// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8056Composite} from "../extension/IERC8056Composite.sol";
import {IERC8056PairWrapper} from "./IERC8056PairWrapper.sol";

/**
 * @title IERC8056PairWrapperRegistry
 * @notice Canonical per-asset splitter discovery. Maps a raw RWA token to the ONE
 *         ERC8056PairWrapper that splits it into Capital / Yield pairs, so every
 *         protocol integrates against the same, deterministic wrapper per asset.
 *
 *   The registry enforces singleton semantics: the first deployOrGet for an
 *   underlying establishes its canonical wrapper; every later call returns the
 *   same address. Identity is keyed by `underlying` only. `scaledUnderlying`
 *   MUST be the same contract as `underlying` (the underlying RWA token is the
 *   class-decomposed extension), so a third party cannot bind an untrusted
 *   extension that would price the canonical wrapper's redemptions.
 */
interface IERC8056PairWrapperRegistry {
    /// @notice Canonical wrapper for `underlying`; zero address if never registered.
    function wrapperFor(IERC20 underlying) external view returns (IERC8056PairWrapper);

    /// @notice Canonical wrapper for `underlying`, deploying and caching it on first
    ///         call (idempotent thereafter).
    /// @param underlying       Raw RWA token (ERC-20); MUST equal `scaledUnderlying`.
    /// @param scaledUnderlying The ERC-8056 class-decomposed extension the wrapper reads
    ///                         yield history from. MUST be the same contract as `underlying`;
    ///                         validated via ERC-165.
    /// @param name             FALLBACK-ONLY display name: used only when `underlying`
    ///                         lacks ERC-20 metadata (name()/symbol() absent or reverting);
    ///                         otherwise ignored in favor of `underlying.name()`. This
    ///                         prevents the first caller from squatting misleading
    ///                         metadata on standard tokens.
    /// @param symbol           FALLBACK-ONLY display symbol (same rules as `name`).
    /// @dev Reverts ExtensionMismatch if `scaledUnderlying != underlying`;
    ///      reverts UnsupportedExtension if it does not report IERC8056Composite via ERC-165.
    function deployOrGet(
        IERC20 underlying,
        IERC8056Composite scaledUnderlying,
        string calldata name,
        string calldata symbol
    ) external returns (IERC8056PairWrapper);

    /// @notice Number of registered wrappers.
    function wrapperCount() external view returns (uint256);

    /// @notice Wrapper at `index` (enumerates all registered assets).
    function wrapperAt(uint256 index) external view returns (IERC8056PairWrapper);

    /// @notice The underlying token for a wrapper (reverse lookup).
    function underlyingOf(IERC8056PairWrapper wrapper) external view returns (IERC20);

    event PairWrapperDeployed(
        IERC20 indexed underlying, IERC8056Composite indexed scaledUnderlying, IERC8056PairWrapper wrapper
    );
}
