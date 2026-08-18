// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8056TokenClasses} from "./IERC8056TokenClasses.sol";

/**
 * @title IERC8056PairWrapper
 * @notice Singleton wrapper that splits raw RWA into per-window Capital / Yield
 *         ERC-20 pairs. Protocols (auctions, options, lending) integrate against
 *         this stable surface, not the concrete wrapper.
 *
 *   A "window" is keyed by (startNonce, targetNonce), created lazily on the first
 *   wrap. Each window has exactly one capital token and one yield token, both
 *   standard fungible ERC-20 receipts. One wrapper per underlying asset (see the
 *   registry / INTEGRATION doc).
 */
interface IERC8056PairWrapper {
    /// @dev Token pair for a single (start, target) window. Zero addresses if the
    ///      window was never created. `IERC20` keeps the interface free of concrete
    ///      token contracts; both legs are standard, fungible ERC-20 receipts.
    struct Pair {
        IERC20 capital;
        IERC20 yield;
    }

    // ------------------------------------------------------------------ events
    event Wrapped(address indexed user, uint256 rawAmount, uint256 startNonce, uint256 targetNonce);
    event Unwrapped(
        address indexed user,
        uint256 startNonce,
        uint256 targetNonce,
        uint256 amount,
        uint256 capitalRawOut,
        uint256 yieldLegRawOut
    );
    event UnwrapYield(address indexed user, uint256 startNonce, uint256 targetNonce, uint256 amount, uint256 rawOut);
    event UnwrapCapital(address indexed user, uint256 startNonce, uint256 targetNonce, uint256 amount, uint256 rawOut);

    // ------------------------------------------------------------------ errors
    error InvalidAmount();
    error Locked();
    error PairNotFound();

    // ------------------------------------------------------------------ immutables
    /// @dev Raw RWA token this wrapper locks.
    function underlying() external view returns (IERC20);

    /// @dev Class-decomposed extension the wrapper reads yield history from.
    function scaledUnderlying() external view returns (IERC8056TokenClasses);

    /// @dev Display name / symbol for the wrapped asset.
    function assetName() external view returns (string memory);
    function assetSymbol() external view returns (string memory);

    // ------------------------------------------------------------------ state
    /// @dev Total raw underlying locked across all windows.
    function rawLocked() external view returns (uint256);

    /// @dev Current yield nonce (effective dividend count); == scaledUnderlying.yieldNonce().
    function currentNonce() external view returns (uint256);

    // ------------------------------------------------------------------ window enumeration
    /// @dev Number of distinct (start, target) windows ever created.
    function pairCount() external view returns (uint256);

    /// @dev (start, target) window at 0-based index `index`.
    function pairAt(uint256 index) external view returns (uint256 start, uint256 target);

    /// @dev True if window (start, target) was ever created.
    function hasPair(uint256 startNonce, uint256 targetNonce) external view returns (bool);

    // ------------------------------------------------------------------ token addresses & supplies
    /// @dev Both legs of window (start, target); zero addresses if never created.
    function pairs(uint256 startNonce, uint256 targetNonce) external view returns (Pair memory);

    /// @dev Explicit leg getters so integrators don't destructure `pairs()`.
    function capitalToken(uint256 startNonce, uint256 targetNonce) external view returns (IERC20);
    function yieldToken(uint256 startNonce, uint256 targetNonce) external view returns (IERC20);

    /// @dev Per-window capital / yield supply (0 if never created).
    function capitalSupplyOf(uint256 startNonce, uint256 targetNonce) external view returns (uint256);
    function yieldSupplyOf(uint256 startNonce, uint256 targetNonce) external view returns (uint256);

    /// @dev Aggregate capital / yield supply across all windows.
    function capitalSupply() external view returns (uint256);
    function yieldSupply() external view returns (uint256);

    /// @dev Raw backing of a single window: the staked amount, equal to capitalSupplyOf
    ///      (and yieldSupplyOf, since each wrapped unit mints one capital and one yield).
    function rawLockedOf(uint256 startNonce, uint256 targetNonce) external view returns (uint256);

    // ------------------------------------------------------------------ pricing (frozen)
    /// @dev Frozen yield coupon of window (start, target): max(1 - Y_s/Y_t, 0), 1e18 fixed point.
    ///      Reverts PairNotFound; reverts EventNotEffective before the target is effective.
    function couponOf(uint256 startNonce, uint256 targetNonce) external view returns (uint256);

    /// @dev Frozen capital share of window (start, target): 1e18 - coupon.
    function capitalShareOf(uint256 startNonce, uint256 targetNonce) external view returns (uint256);

    // ------------------------------------------------------------------ previews
    /// @dev Underlying returned for burning `amount` of BOTH legs of window (start, target).
    function previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        external
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut);

    /// @dev Underlying returned for burning `amount` yield leg of window (start, target).
    function previewUnwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce) external view returns (uint256);

    /// @dev Underlying returned for burning `amount` capital leg of window (start, target).
    function previewUnwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce)
        external
        view
        returns (uint256);

    /// @dev Composite-UI display of `capitalAmount` capital tokens (Supply factor; DISPLAY ONLY,
    ///      never a redemption amount).
    function previewCapitalUI(uint256 capitalAmount) external view returns (uint256);

    // ------------------------------------------------------------------ state-changing
    /// @dev Lock `rawAmount` underlying into window (currentNonce, currentNonce + lockNonces);
    ///      mints 1:1 capital + yield. Returns the created window's nonces.
    function wrap(uint256 rawAmount, uint256 lockNonces) external returns (uint256 startNonce, uint256 targetNonce);

    /// @dev Burn both legs of window (start, target); receive exactly `amount`, anytime.
    function unwrap(uint256 amount, uint256 startNonce, uint256 targetNonce) external;

    /// @dev Burn `amount` yield leg of window (start, target) for `amount * coupon`.
    ///      Only after yieldNonce() >= targetNonce.
    function unwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce) external;

    /// @dev Burn `amount` capital leg of window (start, target) for `amount * (1 - coupon)`.
    ///      Only after yieldNonce() >= targetNonce.
    function unwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce) external;
}
