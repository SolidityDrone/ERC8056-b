// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC8056TokenClasses} from "./interfaces/IERC8056TokenClasses.sol";
import {UIScalingClass} from "./interfaces/UIScalingClass.sol";
import {UIScalingMath} from "./libraries/UIScalingMath.sol";
import {CapitalToken} from "./tokens/CapitalToken.sol";
import {YieldToken} from "./tokens/YieldToken.sol";

/**
 * @title ERC8056PairWrapper
 * @notice Window-coupon wrapper: splits raw RWA into Capital / Yield ERC-20 pairs,
 *         one pair per (startNonce, targetNonce) yield-event window.
 *
 *   wrap(raw, lockNonces) at current nonce N -> pair (N, N + lockNonces); mints
 *   `raw` Capital + `raw` Yield of that window (1:1 raw).
 *
 *   Claims are FROZEN at the target nonce, from historical checkpoints only:
 *     Y_s = yieldEventAt(start).multiplier   Y_t = yieldEventAt(target).multiplier
 *     yield coupon per token = max(1 - Y_s/Y_t, 0)   (0 when Y_t <= Y_s: principal protected)
 *     capital share per token = 1 - coupon
 *   The current multiplier is NEVER read; later dividends price nothing for a
 *   pair whose window has ended, so unwrapping months later pays the same split.
 *
 *   Redemption rules:
 *     - unwrap(amount, s, t)       - burn both legs, receive exactly `amount`, ANYTIME.
 *     - unwrapYield(amount, s, t)  - solo yield leg, only when yieldNonce() >= t.
 *     - unwrapCapital(amount, s, t)- solo capital leg, only when yieldNonce() >= t.
 *
 *   coupon + share = 1, so every pair's total claim equals its deposit and the
 *   shared vault stays solvent by construction.
 */
contract ERC8056PairWrapper {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error Locked();
    error PairNotFound();

    struct Pair {
        CapitalToken capital;
        YieldToken yield;
    }

    IERC20 public immutable underlying;
    IERC8056TokenClasses public immutable scaledUnderlying;
    string public assetName;
    string public assetSymbol;

    uint256 public rawLocked;

    /// @dev One Capital/Yield pair per (start, target) window; created lazily.
    mapping(uint256 => mapping(uint256 => Pair)) internal _pairs;
    uint256[] internal _pairStarts;
    uint256[] internal _pairTargets;

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

    constructor(
        IERC20 underlying_,
        IERC8056TokenClasses scaledUnderlying_,
        string memory assetName_,
        string memory assetSymbol_
    ) {
        underlying = underlying_;
        scaledUnderlying = scaledUnderlying_;
        assetName = assetName_;
        assetSymbol = assetSymbol_;
    }

    // ------------------------------------------------------------------
    // Wrap
    // ------------------------------------------------------------------
    /// @notice Lock `rawAmount` underlying into the window (currentNonce, currentNonce + lockNonces).
    /// @dev `lockNonces = 0` creates a degenerate window with coupon 0 (capital = full).
    function wrap(uint256 rawAmount, uint256 lockNonces) external returns (uint256 startNonce, uint256 targetNonce) {
        if (rawAmount == 0) revert InvalidAmount();

        startNonce = scaledUnderlying.yieldNonce();
        targetNonce = startNonce + lockNonces;

        Pair storage pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) {
            string memory suffix = string.concat(Strings.toString(startNonce), "-", Strings.toString(targetNonce));
            pair.capital =
                new CapitalToken(string.concat("Capital-", suffix), string.concat("Cap", suffix), address(this));
            pair.yield = new YieldToken(string.concat("Yield-", suffix), string.concat("Yld", suffix), address(this));
            _pairStarts.push(startNonce);
            _pairTargets.push(targetNonce);
        }

        underlying.safeTransferFrom(msg.sender, address(this), rawAmount);
        rawLocked += rawAmount;
        pair.capital.mint(msg.sender, rawAmount);
        pair.yield.mint(msg.sender, rawAmount);

        emit Wrapped(msg.sender, rawAmount, startNonce, targetNonce);
    }

    // ------------------------------------------------------------------
    // Unwrap (equal-leg, anytime, exact)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` of BOTH legs of window (start, target); receive exactly `amount`.
    /// @dev The leg split in the event follows the frozen shares once the target is
    ///      effective; before that the whole amount is reported as capital.
    function unwrap(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(startNonce, targetNonce);

        (uint256 capitalRawOut, uint256 yieldLegRawOut) = _previewUnwrap(amount, startNonce, targetNonce);

        pair.capital.burn(msg.sender, amount);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= amount;

        underlying.safeTransfer(msg.sender, amount);

        emit Unwrapped(msg.sender, startNonce, targetNonce, amount, capitalRawOut, yieldLegRawOut);
    }

    // ------------------------------------------------------------------
    // Unwrap (solo legs, nonce-gated, frozen payouts)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` yield tokens of window (start, target) for `amount * coupon` raw.
    /// @dev Only after `yieldNonce() >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(startNonce, targetNonce);
        if (scaledUnderlying.yieldNonce() < targetNonce) revert Locked();

        uint256 coupon = _couponOf(startNonce, targetNonce);
        uint256 rawOut = Math.mulDiv(amount, coupon, UIScalingMath.MULTIPLIER_DECIMALS);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapYield(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    /// @notice Burn `amount` capital tokens of window (start, target) for `amount * (1 - coupon)` raw.
    /// @dev Only after `yieldNonce() >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(startNonce, targetNonce);
        if (scaledUnderlying.yieldNonce() < targetNonce) revert Locked();

        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        uint256 rawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
        pair.capital.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapCapital(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    /// @dev Current yield nonce (effective dividend count) - delegated to the extension.
    function currentNonce() public view returns (uint256) {
        return scaledUnderlying.yieldNonce();
    }

    function pairCount() public view returns (uint256) {
        return _pairStarts.length;
    }

    function pairAt(uint256 index) public view returns (uint256 start, uint256 target) {
        return (_pairStarts[index], _pairTargets[index]);
    }

    /// @dev Pair whose tokens unlock at window (start, target); zero addresses if never created.
    function pairs(uint256 startNonce, uint256 targetNonce) public view returns (Pair memory) {
        return _pairs[startNonce][targetNonce];
    }

    /// @dev Total capital supply across all windows.
    function capitalSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].capital.totalSupply();
        }
        return total;
    }

    /// @dev Total yield supply across all windows.
    function yieldSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].yield.totalSupply();
        }
        return total;
    }

    function capitalSupplyOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        Pair storage pair = _pairs[startNonce][targetNonce];
        return address(pair.capital) == address(0) ? 0 : pair.capital.totalSupply();
    }

    function yieldSupplyOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        Pair storage pair = _pairs[startNonce][targetNonce];
        return address(pair.yield) == address(0) ? 0 : pair.yield.totalSupply();
    }

    /// @dev Frozen yield coupon of window (start, target): max(1 - Y_s/Y_t, 0), 1e18 fixed point.
    ///      Reverts EventNotEffective before the target nonce is effective.
    function couponOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        _requirePair(startNonce, targetNonce);
        return _couponOf(startNonce, targetNonce);
    }

    /// @dev Frozen capital share of window (start, target): 1e18 - coupon.
    function capitalShareOf(uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        return UIScalingMath.MULTIPLIER_DECIMALS - couponOf(startNonce, targetNonce);
    }

    /// @notice Preview underlying returned for burning `amount` of both legs of window (start, target).
    /// @dev Returns (amount, 0) before the target is effective (split undefined); the total is
    ///      always exactly `amount`.
    function previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        Pair storage pair = _requirePair(startNonce, targetNonce);
        return _previewUnwrap(amount, startNonce, targetNonce);
    }

    /// @notice Preview solo yield redemption of `amount` yield tokens of window (start, target).
    /// @dev Reverts EventNotEffective/EventNotRecorded until the target is effective.
    function previewUnwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce) public view returns (uint256) {
        _requirePair(startNonce, targetNonce);
        return Math.mulDiv(amount, _couponOf(startNonce, targetNonce), UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @notice Preview solo capital redemption of `amount` capital tokens of window (start, target).
    /// @dev Reverts EventNotEffective/EventNotRecorded until the target is effective.
    function previewUnwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        returns (uint256)
    {
        _requirePair(startNonce, targetNonce);
        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        return Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @dev Composite-UI display of `capitalAmount` capital tokens. Supply events (splits)
    ///      scale the display only; the raw claim is untouched.
    function previewCapitalUI(uint256 capitalAmount) public view returns (uint256) {
        uint256 supplyFactorNow = scaledUnderlying.uiScalingFactor(UIScalingClass.Supply);
        return Math.mulDiv(capitalAmount, supplyFactorNow, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------
    function _couponOf(uint256 startNonce, uint256 targetNonce) internal view returns (uint256) {
        uint256 yStart = scaledUnderlying.yieldEventAt(startNonce).multiplier;
        uint256 yTarget = scaledUnderlying.yieldEventAt(targetNonce).multiplier;
        if (yTarget <= yStart) return 0;
        return Math.mulDiv(yTarget - yStart, UIScalingMath.MULTIPLIER_DECIMALS, yTarget);
    }

    function _previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        internal
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        if (scaledUnderlying.yieldNonce() >= targetNonce) {
            uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
            capitalRawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
            yieldLegRawOut = amount - capitalRawOut;
        } else {
            capitalRawOut = amount;
            yieldLegRawOut = 0;
        }
    }

    function _requirePair(uint256 startNonce, uint256 targetNonce) internal view returns (Pair storage pair) {
        pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) revert PairNotFound();
    }
}
