// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC8056PairWrapper} from "../interfaces/wrapper/IERC8056PairWrapper.sol";
import {IERC8056Composite} from "../interfaces/extension/IERC8056Composite.sol";
import {MultiplierClass} from "../interfaces/extension/IERC8056MultiplierClass.sol";
import {UIScalingMath} from "../libraries/UIScalingMath.sol";
import {LegToken} from "../wrapper/LegToken.sol";
import {ERC8056Composite} from "../ERC8056Composite.sol";

/**
 * @title ERC8056CompositePairWrapper
 * @notice The token-side variant of the Capital/Yield wrapper: the pair-splitting
 *         logic lives INSIDE the ERC-8056 composite token itself, advertised via
 *         ERC-165 (`IERC8056PairWrapper` interface ID), instead of a separate
 *         adapter + registry.
 *
 *   Integration model (vs. the standalone {ERC8056PairWrapper} on `main`):
 *   - One deployed contract is BOTH the stock token and the Capital/Yield
 *     factory: `underlying()` and `scaledUnderlying()` both return the token.
 *   - No registry, no approval ceremony. Discovery is `supportsInterface` on the
 *     token, which is possible because the issuer (Robinhood-style centralized
 *     authority that owns `uiMultiplier` anyway) ships the token with wrapping
 *     built in — the same trust anchor already required for the multiplier data.
 *   - `wrap` SELF-ESCROWS: the caller's raw balance is debited internally, so
 *     no `approve` transaction and no fee-on-transfer surface exist.
 *   - Legs remain separate ERC-20 {LegToken}s per (startNonce, targetNonce)
 *     window, deployed lazily by the first wrapper of that window (same frozen
 *     coupon semantics, dedup, and solvency model as the standalone wrapper).
 */
contract ERC8056CompositePairWrapper is ERC8056Composite, IERC8056PairWrapper, ReentrancyGuard {
    uint256 public override rawLocked;

    /// @dev One Capital/Yield pair per (start, target) window; created lazily.
    mapping(uint256 => mapping(uint256 => IERC8056PairWrapper.Pair)) internal _pairs;
    uint256[] internal _pairStarts;
    uint256[] internal _pairTargets;

    constructor(string memory name_, string memory symbol_, address initialOwner)
        ERC8056Composite(name_, symbol_, initialOwner)
    {}

    // ------------------------------------------------------------------
    // Immutables: the token IS the underlying and the scaled underlying
    // ------------------------------------------------------------------
    function underlying() external view override returns (IERC20) {
        return IERC20(address(this));
    }

    function scaledUnderlying() external view override returns (IERC8056Composite) {
        return IERC8056Composite(address(this));
    }

    /// @dev The wrapped asset's display metadata is the token's own.
    function assetName() external view override returns (string memory) {
        return name();
    }

    function assetSymbol() external view override returns (string memory) {
        return symbol();
    }

    // ------------------------------------------------------------------
    // Wrap (self-escrow: no approve, no external transfer)
    // ------------------------------------------------------------------
    /// @notice Lock `rawAmount` of your own token balance into the window
    ///         (currentNonce, currentNonce + lockNonces); mints 1:1 capital +
    ///         yield legs. No approval needed: the token escrows internally.
    /// @dev `lockNonces = 0` creates a degenerate window with coupon 0 (capital = full).
    function wrap(uint256 rawAmount, uint256 lockNonces)
        external
        nonReentrant
        returns (uint256 startNonce, uint256 targetNonce)
    {
        if (rawAmount == 0) revert InvalidAmount();

        // startNonce = 0 is safe: the composite lazily bootstraps a genesis
        // checkpoint at index 0, so classEventAtNonce(Yield, startNonce) always
        // resolves even for the very first window (no ZeroFactor brick).
        startNonce = getClassNonce(MultiplierClass.Yield);
        targetNonce = startNonce + lockNonces;

        IERC8056PairWrapper.Pair storage pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) {
            // The window is minted exactly once: the pair record stores the leg
            // addresses, so any later wrap into the same window joins it instead
            // of deploying a second pair.
            string memory suffix = string.concat(Strings.toString(startNonce), "-", Strings.toString(targetNonce));
            pair.capital = new LegToken(
                string.concat("Capital-", suffix), string.concat("Cap", suffix), address(this), decimals()
            );
            pair.yield =
                new LegToken(string.concat("Yield-", suffix), string.concat("Yld", suffix), address(this), decimals());
            _pairStarts.push(startNonce);
            _pairTargets.push(targetNonce);
        }

        rawLocked += rawAmount;
        // Self-escrow: debit the wrapper directly. No external call, no approval,
        // no fee-on-transfer surface (the token cannot fee on its own ledger).
        _update(msg.sender, address(this), rawAmount);

        _capitalLeg(pair).mint(msg.sender, rawAmount);
        _yieldLeg(pair).mint(msg.sender, rawAmount);

        emit Wrapped(msg.sender, rawAmount, startNonce, targetNonce);
    }

    // ------------------------------------------------------------------
    // Unwrap (equal-leg, anytime, exact)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` of BOTH legs of window (start, target); receive exactly `amount`.
    function unwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        external
        nonReentrant
        returns (uint256 rawOut)
    {
        if (amount == 0) revert InvalidAmount();
        IERC8056PairWrapper.Pair storage pair = _requirePair(startNonce, targetNonce);

        (uint256 capitalRawOut, uint256 yieldLegRawOut) = _previewUnwrap(amount, startNonce, targetNonce);

        _capitalLeg(pair).burn(msg.sender, amount);
        _yieldLeg(pair).burn(msg.sender, amount);
        rawLocked -= amount;

        _releaseEscrow(msg.sender, amount);
        rawOut = amount;

        emit Unwrapped(msg.sender, startNonce, targetNonce, amount, capitalRawOut, yieldLegRawOut);
    }

    // ------------------------------------------------------------------
    // Unwrap (solo legs, nonce-gated, frozen payouts)
    // ------------------------------------------------------------------
    /// @notice Burn `amount` yield tokens of window (start, target) for `amount * coupon` raw.
    /// @dev Only after `getClassNonce(MultiplierClass.Yield) >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapYield(uint256 amount, uint256 startNonce, uint256 targetNonce)
        external
        nonReentrant
        returns (uint256 rawOut)
    {
        if (amount == 0) revert InvalidAmount();
        IERC8056PairWrapper.Pair storage pair = _requirePair(startNonce, targetNonce);
        if (getClassNonce(MultiplierClass.Yield) < targetNonce) revert Locked();

        uint256 coupon = _couponOf(startNonce, targetNonce);
        rawOut = Math.mulDiv(amount, coupon, UIScalingMath.MULTIPLIER_DECIMALS);
        _yieldLeg(pair).burn(msg.sender, amount);
        rawLocked -= rawOut;

        _releaseEscrow(msg.sender, rawOut);

        emit UnwrapYield(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    /// @notice Burn `amount` capital tokens of window (start, target) for `amount * (1 - coupon)` raw.
    /// @dev Only after `getClassNonce(MultiplierClass.Yield) >= targetNonce`; payout is frozen at the target multiplier.
    function unwrapCapital(uint256 amount, uint256 startNonce, uint256 targetNonce)
        external
        nonReentrant
        returns (uint256 rawOut)
    {
        if (amount == 0) revert InvalidAmount();
        IERC8056PairWrapper.Pair storage pair = _requirePair(startNonce, targetNonce);
        if (getClassNonce(MultiplierClass.Yield) < targetNonce) revert Locked();

        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - _couponOf(startNonce, targetNonce);
        rawOut = Math.mulDiv(amount, share, UIScalingMath.MULTIPLIER_DECIMALS);
        _capitalLeg(pair).burn(msg.sender, amount);
        rawLocked -= rawOut;

        _releaseEscrow(msg.sender, rawOut);

        emit UnwrapCapital(msg.sender, startNonce, targetNonce, amount, rawOut);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    /// @dev Current yield nonce (effective dividend count) - this token's own class history.
    function currentNonce() public view override returns (uint256) {
        return getClassNonce(MultiplierClass.Yield);
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
    /// @dev OFF-CHAIN ONLY — loops over every created window; will exceed block gas
    ///      limits as window count grows. Never call from on-chain protocols.
    function capitalSupply() public view override returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _pairStarts.length; i++) {
            total += _pairs[_pairStarts[i]][_pairTargets[i]].capital.totalSupply();
        }
        return total;
    }

    /// @dev Total yield supply across all windows.
    /// @dev OFF-CHAIN ONLY — loops over every created window; will exceed block gas
    ///      limits as window count grows. Never call from on-chain protocols.
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

    /// @dev Outstanding capital supply of window (start, target).
    /// @dev DEPRECATED: misleading after solo redemptions — after an `unwrapYield` the
    ///      capital supply is unchanged while raw backing has decreased. Use {windowBackingOf}.
    function rawLockedOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        return capitalSupplyOf(startNonce, targetNonce);
    }

    /// @dev Remaining raw backing of window (start, target):
    ///      - Pre-maturity: min(capitalSupply, yieldSupply) (solo redemptions gated).
    ///      - Matured: capitalSupply * capitalShare + yieldSupply * coupon (frozen pricing).
    ///      0 for a nonexistent pair.
    function windowBackingOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        IERC8056PairWrapper.Pair storage pair = _pairs[startNonce][targetNonce];
        if (address(pair.capital) == address(0)) return 0;
        if (getClassNonce(MultiplierClass.Yield) < targetNonce) {
            uint256 cap = capitalSupplyOf(startNonce, targetNonce);
            uint256 yld = yieldSupplyOf(startNonce, targetNonce);
            return cap < yld ? cap : yld;
        }
        uint256 coupon = _couponOf(startNonce, targetNonce);
        uint256 share = UIScalingMath.MULTIPLIER_DECIMALS - coupon;
        return Math.mulDiv(pair.capital.totalSupply(), share, UIScalingMath.MULTIPLIER_DECIMALS)
            + Math.mulDiv(pair.yield.totalSupply(), coupon, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    /// @dev Frozen yield coupon of window (start, target): max(1 - Y_s/Y_t, 0), 1e18 fixed point.
    function couponOf(uint256 startNonce, uint256 targetNonce) public view override returns (uint256) {
        _requirePair(startNonce, targetNonce);
        return _couponOf(startNonce, targetNonce);
    }

    /// @dev True once the window reached nonce maturity; solo redemptions unlock.
    function isMatured(uint256 startNonce, uint256 targetNonce) public view override returns (bool) {
        _requirePair(startNonce, targetNonce);
        return getClassNonce(MultiplierClass.Yield) >= targetNonce;
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
        uint256 supplyFactorNow = uiScalingFactor(MultiplierClass.Supply);
        return Math.mulDiv(capitalAmount, supplyFactorNow, UIScalingMath.MULTIPLIER_DECIMALS);
    }

    // ------------------------------------------------------------------
    // ERC-165
    // ------------------------------------------------------------------
    /// @dev The wrapper surface is advertised by the token itself: one
    ///      `supportsInterface` call on the stock token reveals composite AND
    ///      pair-wrapper support — no registry lookup, no adapter probing.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC8056PairWrapper).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------
    /// @dev Release escrowed raw to `to`. Internal ledger move — no external
    ///      transfer, no fee-on-transfer surface (the token cannot fee on its
    ///      own `_update`), unlike the standalone wrapper's outbound guard.
    function _releaseEscrow(address to, uint256 amount) internal {
        _update(address(this), to, amount);
    }

    /// @dev Frozen yield coupon of window (start, target): max(1 - Y_s/Y_t, 0).
    ///      Returns 0 while the target nonce is not yet effective (principal-
    ///      protected immature pricing) or when Y_t <= Y_s.
    function _couponOf(uint256 startNonce, uint256 targetNonce) internal view returns (uint256) {
        if (targetNonce > getClassNonce(MultiplierClass.Yield)) return 0;
        uint256 yStart = classEventAtNonce(MultiplierClass.Yield, startNonce).cumulativeMultiplier;
        uint256 yTarget = classEventAtNonce(MultiplierClass.Yield, targetNonce).cumulativeMultiplier;
        if (yTarget <= yStart) return 0;
        return Math.mulDiv(yTarget - yStart, UIScalingMath.MULTIPLIER_DECIMALS, yTarget);
    }

    function _previewUnwrap(uint256 amount, uint256 startNonce, uint256 targetNonce)
        internal
        view
        returns (uint256 capitalRawOut, uint256 yieldLegRawOut)
    {
        if (getClassNonce(MultiplierClass.Yield) >= targetNonce) {
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
