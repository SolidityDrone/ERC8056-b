// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC8056} from "./interfaces/base/IERC8056.sol";
import {IERC8056Conversion} from "./interfaces/base/IERC8056Conversion.sol";
import {IERC8056Balances} from "./interfaces/base/IERC8056Balances.sol";
import {IERC8056NewUIMultiplier} from "./interfaces/base/IERC8056NewUIMultiplier.sol";
import {IERC8056Cancel} from "./interfaces/base/IERC8056Cancel.sol";
import {IERC8056Composite} from "./interfaces/extension/IERC8056Composite.sol";
import {MultiplierClass} from "./interfaces/extension/IERC8056MultiplierClass.sol";
import {UIScalingMath} from "./libraries/UIScalingMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {ERC8056} from "./ERC8056.sol";

/**
 * @title ERC8056Composite
 * @notice EIP-8056 with Supply / Yield decomposed scaling, scheduling, and history.
 * @dev Inherits ERC8056 for storage-compatible beacon proxy upgrades.
 *      The base contract's storage slots (_uiMultiplier, _newUIMultiplier,
 *      _effectiveAt) are preserved: until the first schedule bootstraps class
 *      history they are actively served so an upgraded vanilla proxy keeps its
 *      display denomination; afterwards all scaling logic uses the class-based
 *      storage appended after the base layout.
 */
contract ERC8056Composite is IERC8056Cancel, ERC8056, IERC8056Composite {
    struct ClassScalingState {
        /// @dev Never read post-constructor (the active factor is always derived
        ///      from checkpoint history); the field is kept so the mapping's
        ///      storage layout stays compatible with already-deployed composites.
        uint256 activeFactor;
        uint256 pendingFactor;
        uint256 effectiveAt;
    }

    error EventNotRecorded();
    error EventNotEffective();
    error CompositeOverflow();
    error NoticePeriodTooShort();
    error NoticePeriodTooLong();
    /// @dev Retrocompat guard (S3): the first classed schedule refuses to run
    ///      while the inherited vanilla slots still hold an unlanded pending
    ///      update, so no announcement is ever silently dropped at bootstrap.
    ///      Resolution: let the vanilla update land, or call the legacy
    ///      {cancelPendingUIMultiplier}.
    error VanillaPendingUpdate(uint256 vanillaEffectiveAt);

    uint256 private constant MAX_NOTICE_PERIOD = 3650 days;

    mapping(MultiplierClass => ClassScalingState) private _classScaling;
    mapping(MultiplierClass => ScalingCheckpoint[]) private _checkpoints;
    mapping(MultiplierClass => uint256[]) private _checkpointTimestamps;

    /// @dev Minimum notice every announcement must provide. Appended at the end
    ///      of the layout so deployed composites can upgrade in place.
    uint256 private _minNoticePeriod;

    constructor(string memory name_, string memory symbol_, address initialOwner)
        ERC8056(name_, symbol_, initialOwner)
    {
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            MultiplierClass scalingClass = MultiplierClass(i);
            _classScaling[scalingClass] = ClassScalingState({
                activeFactor: UIScalingMath.MULTIPLIER_DECIMALS,
                pendingFactor: UIScalingMath.MULTIPLIER_DECIMALS,
                effectiveAt: type(uint256).max
            });
            _checkpoints[scalingClass].push(ScalingCheckpoint(0, UIScalingMath.MULTIPLIER_DECIMALS, 0));
            _checkpointTimestamps[scalingClass].push(0);
        }
        emit UIMultiplierUpdated(0, UIScalingMath.MULTIPLIER_DECIMALS, block.timestamp);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC8056Composite).interfaceId || super.supportsInterface(interfaceId);
    }

    //==============================================================================//
    // Class reads                                                                  //
    //==============================================================================//
    function uiScalingFactor(MultiplierClass scalingClass) public view override returns (uint256) {
        return uiScalingFactorAt(scalingClass, block.timestamp);
    }

    function uiScalingFactorAt(MultiplierClass scalingClass, uint256 timestamp) public view override returns (uint256) {
        _validateScalingClass(scalingClass);
        // Migration window: per-class factor views compose coherently with the
        // composite reads (S4). The Supply class carries the inherited vanilla
        // denomination; other classes stay neutral until genesis is seeded.
        if (!_isBootstrapped()) {
            return scalingClass == MultiplierClass.Supply
                ? _inheritedMultiplierAt(timestamp)
                : UIScalingMath.MULTIPLIER_DECIMALS;
        }
        uint256[] storage timestamps = _checkpointTimestamps[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
        uint256 idx = Arrays.lowerBound(timestamps, timestamp);
        if (idx < history.length && timestamps[idx] == timestamp) {
            return history[idx].cumulativeMultiplier;
        }
        return idx > 0 ? history[idx - 1].cumulativeMultiplier : UIScalingMath.MULTIPLIER_DECIMALS;
    }

    function uiMultiplierAt(uint256 timestamp) public view override returns (uint256) {
        // M1 migration window: a freshly-upgraded vanilla proxy holds its live
        // multiplier in the inherited base slots until the first schedule seeds
        // genesis. Serve those slots instead of a misleading neutral 1e18.
        if (!_isBootstrapped()) return _inheritedMultiplierAt(timestamp);
        return UIScalingMath.composeUiMultiplier(
            uiScalingFactorAt(MultiplierClass.Supply, timestamp),
            uiScalingFactorAt(MultiplierClass.Yield, timestamp),
            uiScalingFactorAt(MultiplierClass.Other, timestamp)
        );
    }

    function uiMultiplierAt(MultiplierClass scalingClass, uint256 timestamp) external view override returns (uint256) {
        return uiScalingFactorAt(scalingClass, timestamp);
    }

    function newUIMultiplier(MultiplierClass scalingClass) public view override returns (uint256) {
        return _pendingFactor(scalingClass);
    }

    function effectiveAt(MultiplierClass scalingClass) public view override returns (uint256) {
        if (!hasPendingUIMultiplier(scalingClass)) return 0;
        return _classScaling[scalingClass].effectiveAt;
    }

    function hasPendingUIMultiplier(MultiplierClass scalingClass) public view override returns (bool) {
        ClassScalingState storage state = _classScaling[scalingClass];
        return block.timestamp < state.effectiveAt && state.effectiveAt != type(uint256).max;
    }

    function scalingHistoryLength(MultiplierClass scalingClass) external view override returns (uint256) {
        return _checkpoints[scalingClass].length;
    }

    function scalingCheckpointAt(MultiplierClass scalingClass, uint256 index)
        external
        view
        override
        returns (ScalingCheckpoint memory)
    {
        return _checkpoints[scalingClass][index];
    }

    function getClassNonce(MultiplierClass scalingClass) public view override returns (uint256) {
        _validateScalingClass(scalingClass);
        uint256[] storage timestamps = _checkpointTimestamps[scalingClass];
        if (timestamps.length == 0) return 0;
        // Timestamps are strictly ascending (genesis at ts=0, pop-before-push,
        // future-only scheduling), so the count of entries <= block.timestamp
        // minus the genesis entry equals the effective-event nonce.
        return Arrays.upperBound(timestamps, block.timestamp) - 1;
    }

    function classEventAtNonce(MultiplierClass scalingClass, uint256 nonce)
        public
        view
        override
        returns (ClassScalingEvent memory)
    {
        _validateScalingClass(scalingClass);
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
        uint256 index = nonce;
        if (index >= history.length) {
            // Lazy genesis: a freshly-upgraded vanilla proxy has no checkpoint
            // history until its first schedule bootstraps genesis. Nonce 0 then
            // resolves to a synthetic neutral genesis event, matching direct
            // deploys (where index 0 IS genesis) and keeping degenerate wrapper
            // windows (0,0) readable instead of bricking funds.
            if (index == 0 && history.length == 0) {
                return ClassScalingEvent(0, UIScalingMath.MULTIPLIER_DECIMALS, 0);
            }
            revert EventNotRecorded();
        }
        if (history[index].effectiveAt > block.timestamp) revert EventNotEffective();
        return ClassScalingEvent(
            history[index].effectiveAt, history[index].cumulativeMultiplier, history[index].multiplierRatio
        );
    }

    //==============================================================================//
    // Class writes (enum required - no generic update)                             //
    //==============================================================================//
    function setUIMultiplier(
        MultiplierClass scalingClass,
        uint256 newMultiplier,
        uint256 effectiveAtTimestamp,
        string memory id,
        string memory description,
        string memory uri
    ) public override(IERC8056Composite) onlyOwner {
        _setMultiplier(scalingClass, newMultiplier, effectiveAtTimestamp, id, description, uri);
    }

    /// @notice LEGACY COMPAT HAZARD: targets the Supply class ONLY.
    ///     Vanilla-era tooling calling this expects `uiMultiplier()` to become
    ///     exactly `newMultiplier` after landing. That holds while Yield/Other
    ///     stay neutral (1e18), but once any Yield or Other announcement exists,
    ///     the composite reads `Supply × Yield × Other` and will differ from the
    ///     value passed here. Use the classed setter when classes are in play.
    /// @dev Delegates to the Supply class instead of writing the base contract's
    ///      dead single-multiplier storage (which vanilla reads would never see).
    function setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) public override(ERC8056) onlyOwner {
        _setMultiplier(MultiplierClass.Supply, newMultiplier, effectiveAtTimestamp, "", "", "");
    }

    /// @notice Cancels every class with a live pending announcement (vanilla
    ///         ERC-8056 cancel behavior, generalized to the decomposed classes).
    ///         Reverts when nothing is pending across any class.
    function cancelPendingUIMultiplier() public override(IERC8056Cancel, ERC8056) onlyOwner {
        // Migration window: a live vanilla pending is cancelled with exact
        // vanilla slot semantics (reverting NothingToCancel when idle), so
        // legacy resolution flows work unchanged pre-bootstrap (S3 path 2).
        if (!_isBootstrapped()) {
            ERC8056._cancelVanillaPending();
            return;
        }
        bool any;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            MultiplierClass c = MultiplierClass(i);
            if (hasPendingUIMultiplier(c)) {
                _cancelClass(c);
                any = true;
            }
        }
        if (!any) revert NothingToCancel();
    }

    function cancelPendingUIMultiplier(MultiplierClass scalingClass) public override(IERC8056Composite) onlyOwner {
        _validateScalingClass(scalingClass);
        if (!hasPendingUIMultiplier(scalingClass)) revert NothingToCancel();
        _cancelClass(scalingClass);
    }

    /// @dev Cancels the pending announcement for a single class, restoring its
    ///      active factor and removing the scheduled checkpoint. Shared by both
    ///      cancel entrypoints.
    function _cancelClass(MultiplierClass scalingClass) private {
        ClassScalingState storage state = _classScaling[scalingClass];
        uint256 pendingFactor = state.pendingFactor;

        uint256 activeFactor = _activeFactor(scalingClass);
        state.pendingFactor = activeFactor;
        state.effectiveAt = type(uint256).max;

        if (_checkpoints[scalingClass].length > 0) {
            _checkpoints[scalingClass].pop();
            _checkpointTimestamps[scalingClass].pop();
        }

        emit UIScalingFactorCancelled(scalingClass, pendingFactor, activeFactor, block.timestamp);
        emit UIMultiplierCancelled(pendingFactor, activeFactor, block.timestamp);
    }

    function _setMultiplier(
        MultiplierClass scalingClass,
        uint256 newMultiplier,
        uint256 effectiveAtTimestamp,
        string memory id,
        string memory description,
        string memory uri
    ) internal {
        _validateScalingClass(scalingClass);
        require(newMultiplier > 0, "ERC8056: factor must be positive");
        require(effectiveAtTimestamp > block.timestamp, "ERC8056: effective time must be future");
        if (effectiveAtTimestamp < block.timestamp + _minNoticePeriod) revert NoticePeriodTooShort();

        // Retrocompat guard (S3): never abandon a live vanilla pending update by
        // bootstrapping over it. Cancels stay unguarded — the legacy cancel is
        // one of the documented resolution paths.
        if (!_isBootstrapped() && _vanillaPendingIsLive()) {
            revert VanillaPendingUpdate(ERC8056._vanillaEffectiveAt());
        }

        ClassScalingState storage state = _classScaling[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];

        uint256 oldMultiplier = uiScalingFactor(scalingClass);
        _rejectCompositeOverflow(scalingClass, newMultiplier);

        if (hasPendingUIMultiplier(scalingClass)) {
            history.pop();
            _checkpointTimestamps[scalingClass].pop();
        }

        if (history.length == 0) {
            // Lazy genesis for a freshly-upgraded vanilla proxy (or the very first
            // schedule). Seed every class's genesis checkpoint. The Supply class
            // inherits the live vanilla multiplier from the base contract so the
            // pre-upgrade UI denomination is preserved; other classes start neutral.
            _lazyBootstrapAll(ERC8056.uiMultiplier());
        }

        state.pendingFactor = newMultiplier;
        state.effectiveAt = effectiveAtTimestamp;

        // `oldMultiplier` derives from checkpoint history and is always > 0
        // (genesis pushes 1e18 and every schedule requires newMultiplier > 0),
        // so mulDiv's internal 512-bit multiplication cannot overflow here.
        uint256 ratio = Math.mulDiv(newMultiplier, UIScalingMath.MULTIPLIER_DECIMALS, oldMultiplier);
        history.push(ScalingCheckpoint(effectiveAtTimestamp, newMultiplier, ratio));
        _checkpointTimestamps[scalingClass].push(effectiveAtTimestamp);
        uint256 nonce = getClassNonce(scalingClass);

        emit UIScalingFactorUpdated(
            scalingClass,
            newMultiplier,
            ratio,
            effectiveAtTimestamp,
            nonce,
            Announcement({id: id, description: description, uri: uri})
        );
        emit UIMultiplierUpdated(uiMultiplier(), _compositeFromPending(), effectiveAtTimestamp);
    }

    /// @dev Schedule-time guard: rejects announcements whose pending composite
    ///      would overflow once this class's factor lands. The current pending
    ///      composite is overflow-safe via sequential mulDiv. `otherComposite` is
    ///      the composite of every OTHER class's pending factor; multiplying it by
    ///      the new factor must stay below 2^256. Both intermediate products use
    //       saturating arithmetic so the guard itself can never panic.
    /// @dev Extracted from {_setMultiplier} to keep its stack shallow enough to
    ///      compile without via-IR (forge coverage runs the legacy pipeline).
    function _rejectCompositeOverflow(MultiplierClass scalingClass, uint256 newMultiplier) private view {
        uint256 pending = _compositeFromPending();
        uint256 otherComposite = _safeMulDiv(pending, UIScalingMath.MULTIPLIER_DECIMALS, _pendingFactor(scalingClass));
        // The composite after this class lands is `otherComposite * newMultiplier / 1e18`,
        // so reject when that exceeds 2^256. When otherComposite <= 1e18 the threshold
        // quotient would itself exceed 2^256, meaning no factor can overflow — cap it.
        uint256 threshold = otherComposite > UIScalingMath.MULTIPLIER_DECIMALS
            ? Math.mulDiv(type(uint256).max, UIScalingMath.MULTIPLIER_DECIMALS, otherComposite)
            : type(uint256).max;
        if (newMultiplier > threshold) revert CompositeOverflow();
    }

    /// @notice Issuer's self-imposed minimum notice for future announcements.
    /// @dev 0 by default, so vanilla immediate scheduling stays available. The
    ///      setter lets an issuer publicly bind itself before opening markets.
    function minNoticePeriod() public view returns (uint256) {
        return _minNoticePeriod;
    }

    function setMinNoticePeriod(uint256 seconds_) external onlyOwner {
        if (seconds_ > MAX_NOTICE_PERIOD) revert NoticePeriodTooLong();
        uint256 previous = _minNoticePeriod;
        _minNoticePeriod = seconds_;
        emit MinimumNoticePeriodSet(previous, seconds_);
    }

    //==============================================================================//
    // ERC-8056 overrides (composite replaces base single-class logic)              //
    //==============================================================================//
    function uiMultiplier() public view override(ERC8056) returns (uint256) {
        return uiMultiplierAt(block.timestamp);
    }

    function uiMultiplier(MultiplierClass scalingClass) external view override returns (uint256) {
        return uiScalingFactor(scalingClass);
    }

    function uiMultiplierAtNonce(uint256 nonce) external view override returns (uint256) {
        return _saturatingCompositeAtNonce(
            _clampedFactorAtNonce(MultiplierClass.Supply, nonce),
            _clampedFactorAtNonce(MultiplierClass.Yield, nonce),
            _clampedFactorAtNonce(MultiplierClass.Other, nonce)
        );
    }

    /// @dev Saturating `a * b` for the composite-at-nonce path ONLY (the live
    ///      `uiMultiplier()` path and `_setMultiplier` keep exact math): clamping
    ///      factors from divergent eras can mix extreme values whose product
    ///      overflows; here the composition saturates at type(uint256).max
    ///      instead of reverting.
    function _mulDivOrMax(uint256 a, uint256 b) private pure returns (uint256) {
        if (a > type(uint256).max / b) return type(uint256).max;
        return a * b;
    }

    /// @dev Saturating `(a * b) / c` used by the schedule-time overflow guard so
    ///      the guard itself can never panic: if `a * b` exceeds 2^256 the result
    ///      saturates to type(uint256).max rather than reverting.
    function _safeMulDiv(uint256 a, uint256 b, uint256 c) private pure returns (uint256) {
        if (a > type(uint256).max / b) return type(uint256).max;
        return Math.mulDiv(a * b, 1, c);
    }

    /// @dev True once any class holds checkpoint history. Direct deploys seed all
    ///      classes in the constructor; upgraded proxies stay false until the
    ///      first schedule seeds genesis via {_lazyBootstrapAll}. Checking Supply
    ///      alone is sufficient: genesis is seeded either by the constructor (all
    ///      classes) or lazily (all empty classes in one transaction).
    function _isBootstrapped() private view returns (bool) {
        return _checkpoints[MultiplierClass.Supply].length > 0;
    }

    /// @dev True when the inherited vanilla base slots hold an unlanded pending
    ///      announcement (see {VanillaPendingUpdate}).
    function _vanillaPendingIsLive() private view returns (bool) {
        uint256 eff = ERC8056._vanillaEffectiveAt();
        return eff != 0 && block.timestamp < eff;
    }

    /// @dev True when any class has a live pending announcement. Used to restore
    ///      the vanilla `effectiveAt() == 0 ⇔ nothing pending` sentinel idiom.
    function _hasAnyPending() private view returns (bool) {
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            if (hasPendingUIMultiplier(MultiplierClass(i))) return true;
        }
        return false;
    }

    /// @dev Vanilla multiplier read from the inherited base slots with the same
    ///      0→neutral coercion {_lazyBootstrapAll} applies, so a proxy that was
    ///      never initialized under the vanilla implementation reads neutral.
    function _inheritedMultiplierAt(uint256 timestamp) private view returns (uint256) {
        uint256 inherited = ERC8056._vanillaMultiplierAt(timestamp);
        return inherited == 0 ? UIScalingMath.MULTIPLIER_DECIMALS : inherited;
    }

    /// @dev Seeds genesis checkpoints for every class whose history is empty.
    ///      The Supply class inherits the live vanilla multiplier (read from the
    ///      base contract) so an upgraded vanilla token keeps its UI denomination;
    ///      other classes start neutral (1e18). Idempotent per-class.
    function _lazyBootstrapAll(uint256 inherited) private {
        // A 0 base multiplier is invalid (schedules require positivity) and only
        // occurs for an uninitialized proxy slot; treat it as neutral so a
        // half-initialized upgrade never seeds a 0 Supply factor.
        uint256 supplyGenesis = inherited == 0 ? UIScalingMath.MULTIPLIER_DECIMALS : inherited;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            MultiplierClass c = MultiplierClass(i);
            if (_checkpoints[c].length == 0) {
                uint256 genesis = (c == MultiplierClass.Supply) ? supplyGenesis : UIScalingMath.MULTIPLIER_DECIMALS;
                _checkpoints[c].push(ScalingCheckpoint(0, genesis, 0));
                _checkpointTimestamps[c].push(0);
            }
        }
    }

    /// @dev Saturating composite for {uiMultiplierAtNonce}: product of the class
    ///      factors over 1e18 fixed point, clamped to type(uint256).max.
    function _saturatingCompositeAtNonce(uint256 supplyFactor, uint256 yieldFactor, uint256 otherFactor)
        private
        pure
        returns (uint256)
    {
        uint256 decimals = UIScalingMath.MULTIPLIER_DECIMALS;
        uint256[3] memory factors = [supplyFactor, yieldFactor, otherFactor];
        uint256 result = decimals;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            result = _mulDivOrMax(result, factors[i]);
            if (result == type(uint256).max) return type(uint256).max;
            result /= decimals;
        }
        return result;
    }

    function uiMultiplierAtNonce(MultiplierClass scalingClass, uint256 nonce) public view override returns (uint256) {
        return classEventAtNonce(scalingClass, nonce).cumulativeMultiplier;
    }

    /// @dev Per-class factor for the composite-at-nonce view: clamps `nonce` to
    ///      the class's current nonce so classes with divergent (shorter)
    ///      histories contribute their latest factor instead of reverting.
    function _clampedFactorAtNonce(MultiplierClass scalingClass, uint256 nonce) internal view returns (uint256) {
        uint256 classNonce = getClassNonce(scalingClass);
        uint256 n = nonce > classNonce ? classNonce : nonce;
        return n == 0 ? UIScalingMath.MULTIPLIER_DECIMALS : classEventAtNonce(scalingClass, n).cumulativeMultiplier;
    }

    function newUIMultiplier() public view override(ERC8056) returns (uint256) {
        if (!_isBootstrapped()) {
            // Migration window: surface the vanilla token's own pending slot
            // (0 on an uninitialized proxy reads as neutral, mirroring the
            // 0-factor coercion in {_lazyBootstrapAll}).
            uint256 inheritedPending = ERC8056.newUIMultiplier();
            return inheritedPending == 0 ? UIScalingMath.MULTIPLIER_DECIMALS : inheritedPending;
        }
        // Vanilla parity (S2): with nothing pending anywhere, vanilla clients
        // pricing off this view must see the active composite — identical to
        // {uiMultiplier()} so no phantom update is implied.
        return _hasAnyPending() ? _compositeFromPending() : uiMultiplier();
    }

    /// @dev Vanilla idiom restored (S2): `effectiveAt() != 0 ⇔ an update is
    ///      incoming`. Returns the earliest pending effectiveAt across classes,
    ///      or 0 when no class has a live announcement.
    function effectiveAt() public view override(ERC8056) returns (uint256) {
        if (!_isBootstrapped()) return ERC8056.effectiveAt();
        if (!_hasAnyPending()) return 0;
        uint256 earliest = type(uint256).max;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            MultiplierClass scalingClass = MultiplierClass(i);
            if (hasPendingUIMultiplier(scalingClass)) {
                uint256 ts = _classScaling[scalingClass].effectiveAt;
                if (ts < earliest) earliest = ts;
            }
        }
        return earliest;
    }

    //==============================================================================//
    // Conversion                                                                   //
    //==============================================================================//
    function toUIAmount(uint256 rawAmount) public view override(ERC8056) returns (uint256) {
        return UIScalingMath.toUIAmount(rawAmount, uiMultiplier());
    }

    function toUIAmount(uint256 rawAmount, MultiplierClass scalingClass) public view returns (uint256) {
        return UIScalingMath.toUIAmount(rawAmount, uiScalingFactor(scalingClass));
    }

    function toUIAmountAt(uint256 rawAmount, uint256 timestamp) public view returns (uint256) {
        return UIScalingMath.toUIAmount(rawAmount, uiMultiplierAt(timestamp));
    }

    function toUIAmountAt(uint256 rawAmount, MultiplierClass scalingClass, uint256 timestamp)
        public
        view
        returns (uint256)
    {
        return UIScalingMath.toUIAmount(rawAmount, uiScalingFactorAt(scalingClass, timestamp));
    }

    function fromUIAmount(uint256 uiAmount) public view override(ERC8056) returns (uint256) {
        return UIScalingMath.fromUIAmount(uiAmount, uiMultiplier());
    }

    function fromUIAmount(uint256 uiAmount, MultiplierClass scalingClass) public view returns (uint256) {
        return UIScalingMath.fromUIAmount(uiAmount, uiScalingFactor(scalingClass));
    }

    function balanceOfUI(address account) public view override(ERC8056) returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    function totalSupplyUI() public view override(ERC8056) returns (uint256) {
        return toUIAmount(totalSupply());
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        ERC20._update(from, to, amount);
        emit TransferWithUIAmount(from, to, amount, toUIAmount(amount));
    }

    /// @dev Composite of the factor each class contributes to the next state:
    ///      pending where a live announcement exists, active otherwise.
    function _compositeFromPending() internal view returns (uint256) {
        return UIScalingMath.composeUiMultiplier(
            _liveOrActiveFactor(MultiplierClass.Supply),
            _liveOrActiveFactor(MultiplierClass.Yield),
            _liveOrActiveFactor(MultiplierClass.Other)
        );
    }

    function _liveOrActiveFactor(MultiplierClass scalingClass) internal view returns (uint256) {
        return hasPendingUIMultiplier(scalingClass) ? _pendingFactor(scalingClass) : _activeFactor(scalingClass);
    }

    /// @dev Currently effective factor for a class, derived from its checkpoint
    ///      history so it stays correct even when the cached `activeFactor`
    ///      storage is stale (e.g. right after an announcement activates without
    ///      a subsequent schedule on that class, or on lazily-bootstrapped
    ///      upgraded proxies).
    function _activeFactor(MultiplierClass c) internal view returns (uint256) {
        return uiScalingFactorAt(c, block.timestamp);
    }

    function _pendingFactor(MultiplierClass c) internal view returns (uint256 f) {
        f = _classScaling[c].pendingFactor;
        if (f == 0) f = UIScalingMath.MULTIPLIER_DECIMALS;
    }

    function _validateScalingClass(MultiplierClass scalingClass) internal pure {
        require(uint256(scalingClass) < UIScalingMath.SCALING_CLASS_COUNT, "ERC8056: unknown scaling class");
    }
}
