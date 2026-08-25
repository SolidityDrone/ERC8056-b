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
 *      _effectiveAt) are preserved but unused; all scaling logic uses the
 *      class-based storage appended after the base layout.
 */
contract ERC8056Composite is IERC8056Cancel, ERC8056, IERC8056Composite {
    struct ClassScalingState {
        uint256 activeFactor;
        uint256 pendingFactor;
        uint256 effectiveAt;
    }

    error EventNotRecorded();
    error EventNotEffective();
    error CompositeOverflow();

    mapping(MultiplierClass => ClassScalingState) private _classScaling;
    mapping(MultiplierClass => ScalingCheckpoint[]) private _checkpoints;
    mapping(MultiplierClass => uint256[]) private _checkpointTimestamps;

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
        uint256[] storage timestamps = _checkpointTimestamps[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
        uint256 idx = Arrays.lowerBound(timestamps, timestamp);
        if (idx < history.length && timestamps[idx] == timestamp) {
            return history[idx].cumulativeMultiplier;
        }
        return idx > 0 ? history[idx - 1].cumulativeMultiplier : UIScalingMath.MULTIPLIER_DECIMALS;
    }

    function uiMultiplierAt(uint256 timestamp) public view override returns (uint256) {
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

    /// @notice Legacy 2-arg setter from ERC-8056: targets the Supply class.
    /// @dev Delegates to the Supply class instead of writing the base contract's
    ///      dead single-multiplier storage (which vanilla reads would never see).
    function setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) public override(ERC8056) onlyOwner {
        _setMultiplier(MultiplierClass.Supply, newMultiplier, effectiveAtTimestamp, "", "", "");
    }

    function cancelPendingUIMultiplier() public override(IERC8056Cancel, ERC8056) onlyOwner {
        revert("ERC8056: use class-based cancel");
    }

    function cancelPendingUIMultiplier(MultiplierClass scalingClass) public override(IERC8056Composite) onlyOwner {
        _validateScalingClass(scalingClass);
        if (!hasPendingUIMultiplier(scalingClass)) revert NothingToCancel();

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

        ClassScalingState storage state = _classScaling[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];

        uint256 oldComposite = uiMultiplier();
        uint256 oldMultiplier = uiScalingFactor(scalingClass);

        // Schedule-time guard: reject announcements whose pending composite
        // would overflow once this class's factor lands. Division-based
        // detection avoids arithmetic panics inside a state-changing call.
        // Factors are guaranteed > 0 (genesis is 1e18 and schedules require
        // positivity), so `withoutClass` cannot revert.
        uint256 pending = _compositeFromPending();
        uint256 withoutClass = Math.mulDiv(pending, UIScalingMath.MULTIPLIER_DECIMALS, _pendingFactor(scalingClass));
        if (withoutClass > type(uint256).max / newMultiplier) revert CompositeOverflow();

        if (hasPendingUIMultiplier(scalingClass)) {
            history.pop();
            _checkpointTimestamps[scalingClass].pop();
        } else if (block.timestamp >= state.effectiveAt) {
            state.activeFactor = _pendingFactor(scalingClass);
        }

        if (history.length == 0) {
            // lazy genesis: upgraded vanilla proxies have no checkpoint history;
            // synthesize the genesis entry so indexing matches direct deploys
            history.push(ScalingCheckpoint(0, UIScalingMath.MULTIPLIER_DECIMALS, 0));
            _checkpointTimestamps[scalingClass].push(0);
        }

        state.pendingFactor = newMultiplier;
        state.effectiveAt = effectiveAtTimestamp;

        // `oldMultiplier` derives from checkpoint history and is always > 0:
        // genesis pushes 1e18 and every schedule requires newMultiplier > 0,
        // so no zero-branch is needed here.
        uint256 ratio = newMultiplier * UIScalingMath.MULTIPLIER_DECIMALS / oldMultiplier;
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
        emit UIMultiplierUpdated(oldComposite, _compositeFromPending(), effectiveAtTimestamp);
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

    /// @dev Deviation from vanilla ERC-8056: returns the product over classes of
    ///      the pending factor for classes with a live announcement and the active
    ///      factor otherwise — i.e. it describes the composite multiplier that
    ///      would result once every pending update lands, counting only live
    ///      announcements.
    function newUIMultiplier() public view override(ERC8056) returns (uint256) {
        return _compositeFromPending();
    }

    /// @dev Deviation from vanilla ERC-8056: returns the earliest pending
    ///      `effectiveAt` across classes; if no class has a live announcement,
    ///      returns the most recent effective event across classes (0 only when
    ///      nothing was ever scheduled) instead of resetting to 0.
    function effectiveAt() public view override(ERC8056) returns (uint256) {
        uint256 earliest = type(uint256).max;
        uint256 latestEvent;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            MultiplierClass scalingClass = MultiplierClass(i);
            if (hasPendingUIMultiplier(scalingClass)) {
                uint256 ts = _classScaling[scalingClass].effectiveAt;
                if (ts < earliest) earliest = ts;
            }
            ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
            if (history.length > 0) {
                uint256 lastTs = history[history.length - 1].effectiveAt;
                if (lastTs > latestEvent) latestEvent = lastTs;
            }
        }
        return earliest != type(uint256).max ? earliest : latestEvent;
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
