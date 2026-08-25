// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC8056Composite} from "../extensions/interfaces/IERC8056Composite.sol";
import {IERC8056PairWrapper} from "./interfaces/IERC8056PairWrapper.sol";
import {MultiplierClass} from "../extensions/interfaces/IERC8056MultiplierClass.sol";
import {UIScalingMath} from "../libraries/UIScalingMath.sol";
import {LegToken} from "./LegToken.sol";

/**
 * @title ERC8056PairWrapper
 * @notice Window-coupon wrapper: splits raw RWA into Capital / Yield ERC-20 pairs,
 *         one pair per (startNonce, targetNonce) yield-event window.
 *
 *   wrap(raw, lockNonces) at current nonce N -> pair (N, N + lockNonces); mints
 *   `raw` Capital + `raw` Yield of that window (1:1 raw).
 *
 *   Claims are FROZEN at the target nonce, from historical checkpoints only:
 *     Y_s = classEventAtNonce(MultiplierClass.Yield, start).cumulativeMultiplier   Y_t = classEventAtNonce(MultiplierClass.Yield, target).cumulativeMultiplier
 *     yield coupon per token = max(1 - Y_s/Y_t, 0)   (0 when Y_t <= Y_s: principal protected)
 *     capital share per token = 1 - coupon
 *   The current multiplier is NEVER read; later dividends price nothing for a
 *   pair whose window has ended, so unwrapping months later pays the same split.
 *
 *   Redemption rules:
 *     - unwrap(amount, s, t)       - burn both legs, receive exactly `amount`, ANYTIME.
 *     - unwrapYield(amount, s, t)  - solo yield leg, only when getClassNonce(MultiplierClass.Yield) >= t.
 *     - unwrapCapital(amount, s, t)- solo capital leg, only when getClassNonce(MultiplierClass.Yield) >= t.
 *
 *  coupon + share = 1, so every pair's total claim equals its deposit and the
 *  shared vault stays solvent by construction.
 *
 *  Implements {IERC8056PairWrapper}; see that interface for the stable
 *  integration surface protocols code against.
 */
contract ERC8056PairWrapper is IERC8056PairWrapper {
    using SafeERC20 for IERC20;

    IERC20 public immutable override underlying;
    IERC8056Composite public immutable override scaledUnderlying;
    string public override assetName;
    string public override assetSymbol;

    uint256 public override rawLocked;

    /// @dev One Capital/Yield pair per (start, target) window; created lazily.
    ///      Stored as {IERC8056PairWrapper.Pair} (IERC20 legs); cast to concrete
    ///      token contracts where mint/burn is needed.
    mapping(uint256 => mapping(uint256 => IERC8056PairWrapper.Pair)) internal _pairs;
    uint256[] internal _pairStarts;
    uint256[] internal _pairTargets;

    constructor(
        IERC20 underlying_,
        IERC8056Composite scaledUnderlying_,
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

        startNonce = scaledUnderlying.getClassNonce(MultiplierClass.Yield);
        targetNonce = startNonce + lockNonces;

        IERC8056PairWrapper.Pair storage pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) {
            string memory suffix = string.concat(Strings.toString(startNonce), "-", Strings.toString(targetNonce));
            pair.capital = new LegToken(string.concat("Capital-", suffix), string.concat("Cap", suffix), address(this));
            pair.yield = new LegToken(string.concat("Yield-", suffix), string.concat("Yld", suffix), address(this));
            _pairStarts.push(startNonce);
            _pairTargets.push(targetNonce);
        }

        rawLocked += rawAmount;
        underlying.safeTransferFrom(msg.sender, address(this), rawAmount);
        _capitalLeg(pair).mint(msg.sender, rawAmount);
        _yieldLeg(pair).mint(msg.sender, rawAmount);

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
        IERC8056PairWrapper.Pair storage pair = _requirePair(startNonce, targetNonce);

        (uint256 capitalRawOut, uint256 yieldLegRawOut) = _previewUnwrap(amount, startNonce, targetNonce);

        _capitalLeg(pair).burn(msg.sender, amount);
        _yieldLeg(pair).burn(msg.sender, amount);
        rawLocked -= amount;

        underlying.safeTransfer(msg.sender, amount);

        emit Unwrapped(msg.sender, startNonce, targetNonce, amount, capitalRawOut, yieldLegRawOut);
    }

    // ------------------------------------------------------------------
    // Unwrap (solo legs, nonce-gated, frozen payouts)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` yield tokens of window (start, target) for `amount * coupon` raw.
    /// @dev Only after `getClassNonce(MultiplierClass.Yield) >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        IERC8056PairWrapper.Pair storage pair = _requirePair(startNonce, targetNonce);
        if (scaledUnderlying.getClassNonce(MultiplierClass.Yield) < targetNonce) revert Locked();

        uint256 coupon = _couponOf(startNonce, targetNonce);
        uint256 rawOut = Math.mulDiv(amount, coupon, UIScalingMath.MULTIPLIER_DECIMALS);
        _yieldLeg(pair).burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapYield(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    /// @notice Burn `amount` capital tokens of window (start, target) for `amount * (1 - coupon)` raw.
    /// @dev Only after `getClassNonce(MultiplierClass.Yield) >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce) external {
        if (amount == 0) revert InvalidAmount();
        IERC8056PairWrapper.Pair storage pair = _requirePair(startNonce, targetNonce);
        if (scaledUnderlying.getClassNonce(MultiplierClass.Yield) < targetNonce) revert Locked();

        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        uint256 rawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
        _capitalLeg(pair).burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapCapital(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    /// @dev Current yield nonce (effective dividend count) - delegated to the extension.
    function currentNonce() public view override returns (uint256) {
        return scaledUnderlying.getClassNonce(MultiplierClass.Yield);
    }

    function pairCount() public view override returns (uint256) {
        return _pairStarts.length;
    }

    function pairAt(uint256 index) public view override returns (uint256 start, uint256 target) {
        return (_pairStarts[index], _pairTargets[index]);
    }

    /// @dev True if window (start, target) was ever created.
    function hasPair(uint256 startNonce, uint256 targetNonce) public view override returns (bool) {
        return address(_pairs[startNonce][targetNonce].capital) != address(0);
    }

    /// @dev Pair whose tokens unlock at window (start, target); zero addresses if never created.
    function pairs(uint256 startNonce, uint256 targetNonce) public view override returns (Pair memory) {
        return _pairs[startNonce][targetNonce];
    }

    /// @dev Explicit capital leg of window (start, target); zero address if never created.
    function capitalToken(uint256 startNonce, uint256 targetNonce) public view override returns (IERC20) {
        return _pairs[startNonce][targetNonce].capital;
    }

    /// @dev Explicit yield leg of window (start, target); zero address if never created.
    function yieldToken(uint256 startNonce, uint256 targetNonce) public view override returns (IERC20) {
        return _pairs[startNonce][targetNonce].yield;
    }

    /// @dev Total capital supply across all windows.
    function capitalSupply() public view override returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].capital.totalSupply();
        }
        return total;
    }

    /// @dev Total yield supply across all windows.
    function yieldSupply() public view override returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].yield.totalSupply();
        }
        return total;
    }

    function capitalSupplyOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        IERC8056PairWrapper.Pair storage pair = _pairs[startNonce][targetNonce];
        return address(pair.capital) == address(0) ? 0 : pair.capital.totalSupply();
    }

    function yieldSupplyOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        IERC8056PairWrapper.Pair storage pair = _pairs[startNonce][targetNonce];
        return address(pair.yield) == address(0) ? 0 : pair.yield.totalSupply();
    }

    /// @dev Outstanding capital supply of window (start, target); equals the window's raw
    ///      backing before any solo yield redemption.
    function rawLockedOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        return capitalSupplyOf(startNonce, targetNonce);
    }

    /// @dev Frozen yield coupon of window (start, target): max(1 - Y_s/Y_t, 0), 1e18 fixed point.
    ///      Reverts EventNotEffective before the target nonce is effective.
    function couponOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        _requirePair(startNonce, targetNonce);
        return _couponOf(startNonce, targetNonce);
    }

    /// @dev Frozen capital share of window (start, target): 1e18 - coupon.
    function capitalShareOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        return UIScalingMath.MULTIPLIER_DECIMALS - couponOf(startNonce, targetNonce);
    }

    /// @notice Preview underlying returned for burning `amount` of both legs of window (start, target).
    /// @dev Returns (amount, 0) before the target is effective (split undefined); the total is
    ///      always exactly `amount`.
    function previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        override
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        _requirePair(startNonce, targetNonce);
        return _previewUnwrap(amount, startNonce, targetNonce);
    }

    /// @notice Preview solo yield redemption of `amount` yield tokens of window (start, target).
    /// @dev Reverts EventNotEffective/EventNotRecorded until the target is effective.
    function previewUnwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        override
        returns (uint256)
    {
        _requirePair(startNonce, targetNonce);
        return Math.mulDiv(amount, _couponOf(startNonce, targetNonce), UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @notice Preview solo capital redemption of `amount` capital tokens of window (start, target).
    /// @dev Reverts EventNotEffective/EventNotRecorded until the target is effective.
    function previewUnwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce)
        public
        view
        override
        returns (uint256)
    {
        _requirePair(startNonce, targetNonce);
        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        return Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @dev Composite-UI display of `capitalAmount` capital tokens. Supply events (splits)
    ///      scale the display only; the raw claim is untouched.
    function previewCapitalUI(uint256 capitalAmount) public view override returns (uint256) {
        uint256 supplyFactorNow = scaledUnderlying.uiScalingFactor(MultiplierClass.Supply);
        return Math.mulDiv(capitalAmount, supplyFactorNow, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------
    function _couponOf(uint256 startNonce, uint256 targetNonce) internal view returns (uint256) {
        uint256 yStart = scaledUnderlying.classEventAtNonce(MultiplierClass.Yield, startNonce).cumulativeMultiplier;
        uint256 yTarget = scaledUnderlying.classEventAtNonce(MultiplierClass.Yield, targetNonce).cumulativeMultiplier;
        if (yTarget <= yStart) return 0;
        return Math.mulDiv(yTarget - yStart, UIScalingMath.MULTIPLIER_DECIMALS, yTarget);
    }

    function _previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        internal
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        if (scaledUnderlying.getClassNonce(MultiplierClass.Yield) >= targetNonce) {
            uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
            capitalRawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
            yieldLegRawOut = amount - capitalRawOut;
        } else {
            capitalRawOut = amount;
            yieldLegRawOut = 0;
        }
    }

    function _requirePair(uint256 startNonce, uint256 targetNonce)
        internal
        view
        returns (IERC8056PairWrapper.Pair storage pair)
    {
        pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) revert PairNotFound();
    }

    /// @dev Concrete capital leg of a stored pair (for mint/burn).
    function _capitalLeg(IERC8056PairWrapper.Pair storage pair) internal view returns (LegToken) {
        return LegToken(address(pair.capital));
    }

    /// @dev Concrete yield leg of a stored pair (for mint/burn).
    function _yieldLeg(IERC8056PairWrapper.Pair storage pair) internal view returns (LegToken) {
        return LegToken(address(pair.yield));
    }
}
