// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IScaledUIAmountClasses} from "./interfaces/IScaledUIAmountClasses.sol";
import {UIScalingClass} from "./interfaces/UIScalingClass.sol";
import {UIScalingMath} from "./libraries/UIScalingMath.sol";
import {CapitalToken} from "./tokens/CapitalToken.sol";
import {YieldToken} from "./tokens/YieldToken.sol";

/**
 * @title ScaledPairWrapper
 * @notice Event-based expiry wrapper: splits raw RWA into Capital / Yield ERC-20
 *         pairs, one pair per unlock nonce (yield event). Locks are measured in
 *         dividends, not time, so delayed dividends never expire.
 *
 *   wrap(raw, lockNonces) → unlockNonce = yieldNonce() + lockNonces; mints `raw`
 *   Capital + `raw` Yield of the pair unlocking at unlockNonce (1:1 raw).
 *
 *   capital claim (raw) = capitalSupply / max(yieldFactor, 1.0)   → 1 Capital token = 1 Yield-UI unit
 *   yield pool  (raw)   = rawLocked − capital claim               → 1 Yield token = pool / yieldSupply
 *
 *   Global invariant preserved by every operation:
 *     rawLocked = capitalSupply / Y + yieldSupply × (1 − 1/Y),  Y = max(yieldFactor, 1.0)
 *   ⇒ per-token yield value = 1 − 1/Y is uniform across ALL expiry pairs, and
 *     equal-leg unwrap of any pair redeems exactly `amount` raw at any time.
 *
 *   Redemption rules:
 *     - unwrap(amount, n)          — burn both legs of pair n, ANYTIME, exact raw.
 *     - unwrapYield(amount, n)     — solo yield leg, only when yieldNonce() >= n.
 *     - unwrapCapital(amount, n)   — solo capital leg, only when yieldNonce() >= n.
 *   Raw stays pooled while locks are outstanding, so pair unwraps always have liquidity.
 *
 *   The nonce lives in the ERC-8056 extension (effective Yield checkpoints);
 *   this contract only reads it via `yieldNonce()`.
 */
contract ScaledPairWrapper {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error InsolventPool();
    error Locked();
    error PairNotFound();

    struct Pair {
        CapitalToken capital;
        YieldToken yield;
    }

    IERC20 public immutable underlying;
    IScaledUIAmountClasses public immutable scaledUnderlying;
    string public assetName;
    string public assetSymbol;

    uint256 public rawLocked;

    /// @dev One Capital/Yield pair per unlock nonce; created lazily on first wrap.
    mapping(uint256 => Pair) internal _pairs;
    uint256[] internal _pairNonces;

    event Wrapped(address indexed user, uint256 rawAmount, uint256 unlockNonce);
    event Unwrapped(
        address indexed user,
        uint256 unlockNonce,
        uint256 amount,
        uint256 capitalRawOut,
        uint256 yieldLegRawOut
    );
    event UnwrapYield(address indexed user, uint256 unlockNonce, uint256 amount, uint256 rawOut);
    event UnwrapCapital(address indexed user, uint256 unlockNonce, uint256 amount, uint256 rawOut);

    constructor(
        IERC20 underlying_,
        IScaledUIAmountClasses scaledUnderlying_,
        string memory assetName_,
        string memory assetSymbol_
    ) {
        underlying = underlying_;
        scaledUnderlying = scaledUnderlying_;
        assetName = assetName_;
        assetSymbol = assetSymbol_;
    }

    // ─── Wrap ──────────────────────────────────────────────────────────────

    /// @notice Lock `rawAmount` underlying and mint 1:1 Capital + Yield of the pair
    ///         unlocking at `yieldNonce() + lockNonces`.
    /// @dev `lockNonces = 0` allows immediate solo redemption (pair of the current nonce).
    function wrap(uint256 rawAmount, uint256 lockNonces) external returns (uint256 unlockNonce) {
        if (rawAmount == 0) revert InvalidAmount();

        unlockNonce = scaledUnderlying.yieldNonce() + lockNonces;
        Pair storage pair = _pairs[unlockNonce];
        if (address(pair.capital) == address(0)) {
            string memory suffix = Strings.toString(unlockNonce);
            pair.capital = new CapitalToken(
                string.concat("Capital-", suffix),
                string.concat("Cap", suffix),
                address(this)
            );
            pair.yield = new YieldToken(
                string.concat("Yield-", suffix),
                string.concat("Yld", suffix),
                address(this)
            );
            _pairNonces.push(unlockNonce);
        }

        underlying.safeTransferFrom(msg.sender, address(this), rawAmount);
        rawLocked += rawAmount;
        pair.capital.mint(msg.sender, rawAmount);
        pair.yield.mint(msg.sender, rawAmount);

        emit Wrapped(msg.sender, rawAmount, unlockNonce);
    }

    // ─── Unwrap (equal-leg, anytime) ───────────────────────────────────────

    /// @notice Burn `amount` of BOTH legs of the pair unlocking at `unlockNonce`.
    /// @dev Always allowed — the base guarantee. Exact: amount/Y + amount×(1−1/Y) = amount.
    function unwrap(uint256 amount, uint256 unlockNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(unlockNonce);

        (uint256 capitalRawOut, uint256 yieldLegRawOut) = _previewUnwrap(pair, amount);

        pair.capital.burn(msg.sender, amount);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= capitalRawOut + yieldLegRawOut;

        underlying.safeTransfer(msg.sender, capitalRawOut + yieldLegRawOut);

        emit Unwrapped(msg.sender, unlockNonce, amount, capitalRawOut, yieldLegRawOut);
    }

    // ─── Unwrap (solo legs, nonce-gated) ───────────────────────────────────

    /// @notice Burn `amount` yield tokens of pair `unlockNonce` and receive raw —
    ///         only after `yieldNonce() >= unlockNonce`.
    function unwrapYield(uint256 amount, uint256 unlockNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(unlockNonce);
        if (scaledUnderlying.yieldNonce() < unlockNonce) revert Locked();
        uint256 supply = yieldSupply();
        if (supply == 0) revert InsolventPool();

        uint256 rawOut = Math.mulDiv(amount, poolYieldRaw(), supply);
        pair.yield.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapYield(msg.sender, unlockNonce, amount, rawOut);
    }

    /// @notice Burn `amount` capital tokens of pair `unlockNonce` and receive raw —
    ///         only after `yieldNonce() >= unlockNonce`.
    function unwrapCapital(uint256 amount, uint256 unlockNonce) external {
        if (amount == 0) revert InvalidAmount();
        Pair storage pair = _requirePair(unlockNonce);
        if (scaledUnderlying.yieldNonce() < unlockNonce) revert Locked();

        uint256 rawOut = capitalRawValue(amount);
        pair.capital.burn(msg.sender, amount);
        rawLocked -= rawOut;

        underlying.safeTransfer(msg.sender, rawOut);

        emit UnwrapCapital(msg.sender, unlockNonce, amount, rawOut);
    }

    // ─── Views ─────────────────────────────────────────────────────────────

    /// @dev Current yield nonce (effective dividend count) — delegated to the extension.
    function currentNonce() public view returns (uint256) {
        return scaledUnderlying.yieldNonce();
    }

    function pairCount() public view returns (uint256) {
        return _pairNonces.length;
    }

    function pairNonceAt(uint256 index) public view returns (uint256) {
        return _pairNonces[index];
    }

    /// @dev Pair whose tokens unlock at `unlockNonce` (zero addresses if never created).
    function pairs(uint256 unlockNonce) public view returns (Pair memory) {
        return _pairs[unlockNonce];
    }

    /// @dev Total capital supply across all pairs.
    function capitalSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairNonces.length; i++) {
            total += _pairs[_pairNonces[i]].capital.totalSupply();
        }
        return total;
    }

    /// @dev Total yield supply across all pairs.
    function yieldSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairNonces.length; i++) {
            total += _pairs[_pairNonces[i]].yield.totalSupply();
        }
        return total;
    }

    function capitalSupplyOf(uint256 unlockNonce) public view returns (uint256) {
        Pair storage pair = _pairs[unlockNonce];
        return address(pair.capital) == address(0) ? 0 : pair.capital.totalSupply();
    }

    function yieldSupplyOf(uint256 unlockNonce) public view returns (uint256) {
        Pair storage pair = _pairs[unlockNonce];
        return address(pair.yield) == address(0) ? 0 : pair.yield.totalSupply();
    }

    /// @dev Raw value of `capitalAmount` capital tokens at the current Yield factor.
    ///      Uniform across all pairs; 1 token = 1/Y raw while Y >= 1 (floored at 1:1 below).
    function capitalRawValue(uint256 capitalAmount) public view returns (uint256) {
        return Math.mulDiv(
            capitalAmount,
            UIScalingMath.MULTIPLIER_DECIMALS,
            _yieldFactorFloored()
        );
    }

    /// @dev Raw units currently attributable to the yield pool (0 when Y < 1).
    function poolYieldRaw() public view returns (uint256) {
        uint256 capitalClaim = Math.mulDiv(
            capitalSupply(),
            UIScalingMath.MULTIPLIER_DECIMALS,
            _yieldFactorFloored()
        );
        if (capitalClaim > rawLocked) revert InsolventPool();
        return rawLocked - capitalClaim;
    }

    /// @dev Raw value of one yield token (18-decimal fixed point) — uniform across ALL pairs.
    function yieldPerTokenRaw() public view returns (uint256) {
        uint256 supply = yieldSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(poolYieldRaw(), UIScalingMath.MULTIPLIER_DECIMALS, supply);
    }

    /// @notice Preview underlying returned for burning `amount` of both paired receipts of pair `unlockNonce`.
    function previewUnwrap(uint256 amount, uint256 unlockNonce)
        public
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        Pair storage pair = _requirePair(unlockNonce);
        return _previewUnwrap(pair, amount);
    }

    /// @notice Preview solo yield redemption of `amount` yield tokens of pair `unlockNonce`.
    function previewUnwrapYield(uint256 amount, uint256 unlockNonce) public view returns (uint256) {
        _requirePair(unlockNonce);
        uint256 supply = yieldSupply();
        if (supply == 0) revert InsolventPool();
        return Math.mulDiv(amount, poolYieldRaw(), supply);
    }

    /// @notice Preview solo capital redemption of `amount` capital tokens of pair `unlockNonce`.
    function previewUnwrapCapital(uint256 amount, uint256 unlockNonce) public view returns (uint256) {
        _requirePair(unlockNonce);
        return capitalRawValue(amount);
    }

    /// @dev Composite-UI display of `capitalAmount` capital tokens. Supply events (splits)
    ///      scale the display only; the raw claim `capitalRawValue` is untouched.
    function previewCapitalUI(uint256 capitalAmount) public view returns (uint256) {
        uint256 supplyFactorNow = scaledUnderlying.uiScalingFactor(UIScalingClass.Supply);
        return Math.mulDiv(capitalAmount, supplyFactorNow, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    // ─── Internals ─────────────────────────────────────────────────────────

    function _previewUnwrap(Pair storage pair, uint256 amount)
        internal
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        uint256 supply = pair.yield.totalSupply();
        if (supply == 0 && amount > 0) revert InsolventPool();
        capitalRawOut = capitalRawValue(amount);
        yieldLegRawOut = supply == 0 ? 0 : Math.mulDiv(amount, poolYieldRaw(), yieldSupply());
    }

    function _requirePair(uint256 unlockNonce) internal view returns (Pair storage pair) {
        pair = _pairs[unlockNonce];
        if (address(pair.capital) == address(0)) revert PairNotFound();
    }

    /// @dev Yield factor floored at 1.0: the capital claim `1/Y` never exceeds 1:1 raw,
    ///      so factor markdowns (Y < 1) shrink the yield pool to zero instead of
    ///      freezing the pool or penalizing holders.
    function _yieldFactorFloored() internal view returns (uint256) {
        return Math.max(
            scaledUnderlying.uiScalingFactor(UIScalingClass.Yield),
            UIScalingMath.MULTIPLIER_DECIMALS
        );
    }
}