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
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
        uint256 nonce;
        for (uint256 i = 1; i < history.length; i++) {            if (history[i].effectiveAt <= block.timestamp) {
                nonce++;
            } else {
                break;
            }
        }
        return nonce;
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
        if (index >= history.length) revert EventNotRecorded();
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
        string calldata id,
        string calldata description,
        string calldata uri
    ) public override(IERC8056Composite) onlyOwner {
        _setMultiplier(scalingClass, newMultiplier, effectiveAtTimestamp, id, description, uri);
    }

    function cancelPendingUIMultiplier() public override(IERC8056Cancel, ERC8056) onlyOwner {
        revert("ERC8056: use class-based cancel");
    }

    function cancelPendingUIMultiplier(MultiplierClass scalingClass) public override(IERC8056Composite) onlyOwner {
        _validateScalingClass(scalingClass);
        if (!hasPendingUIMultiplier(scalingClass)) revert NothingToCancel();

        ClassScalingState storage state = _classScaling[scalingClass];
        uint256 pendingFactor = state.pendingFactor;

        state.pendingFactor = _activeFactor(scalingClass);
        state.effectiveAt = type(uint256).max;

        if (_checkpoints[scalingClass].length > 0) {
            _checkpoints[scalingClass].pop();
            _checkpointTimestamps[scalingClass].pop();
        }

        emit UIScalingFactorCancelled(scalingClass, pendingFactor, state.activeFactor, block.timestamp);
        emit UIMultiplierCancelled(pendingFactor, state.activeFactor, block.timestamp);
    }

    function _setMultiplier(
        MultiplierClass scalingClass,
        uint256 newMultiplier,
        uint256 effectiveAtTimestamp,
        string calldata id,
        string calldata description,
        string calldata uri
    ) internal {
        _validateScalingClass(scalingClass);
        require(newMultiplier > 0, "ERC8056: factor must be positive");
        require(effectiveAtTimestamp > block.timestamp, "ERC8056: effective time must be future");

        ClassScalingState storage state = _classScaling[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];

        uint256 oldComposite = uiMultiplier();
        uint256 oldMultiplier = uiScalingFactor(scalingClass);

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

        uint256 ratio =
            oldMultiplier == 0 ? newMultiplier : newMultiplier * UIScalingMath.MULTIPLIER_DECIMALS / oldMultiplier;
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
        return UIScalingMath.composeUiMultiplier(
            uiMultiplierAtNonce(MultiplierClass.Supply, nonce),
            uiMultiplierAtNonce(MultiplierClass.Yield, nonce),
            uiMultiplierAtNonce(MultiplierClass.Other, nonce)
        );
    }

    function uiMultiplierAtNonce(MultiplierClass scalingClass, uint256 nonce) public view override returns (uint256) {
        return classEventAtNonce(scalingClass, nonce).cumulativeMultiplier;
    }

    function newUIMultiplier() public view override(ERC8056) returns (uint256) {
        return _compositeFromPending();
    }

    function effectiveAt() public view override(ERC8056) returns (uint256) {
        uint256 earliest = type(uint256).max;
        bool found;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            MultiplierClass scalingClass = MultiplierClass(i);
            if (hasPendingUIMultiplier(scalingClass)) {
                uint256 ts = _classScaling[scalingClass].effectiveAt;
                if (ts < earliest) {
                    earliest = ts;
                    found = true;
                }
            }
        }
        return found ? earliest : 0;
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

    function _compositeFromPending() internal view returns (uint256) {
        return UIScalingMath.composeUiMultiplier(
            _factorForComposite(MultiplierClass.Supply),
            _factorForComposite(MultiplierClass.Yield),
            _factorForComposite(MultiplierClass.Other)
        );
    }

    function _factorForComposite(MultiplierClass scalingClass) internal view returns (uint256) {
        return _pendingFactor(scalingClass);
    }

    function _activeFactor(MultiplierClass c) internal view returns (uint256 f) {
        f = _classScaling[c].activeFactor;
        if (f == 0) f = UIScalingMath.MULTIPLIER_DECIMALS;
    }

    function _pendingFactor(MultiplierClass c) internal view returns (uint256 f) {
        f = _classScaling[c].pendingFactor;
        if (f == 0) f = UIScalingMath.MULTIPLIER_DECIMALS;
    }

    function _validateScalingClass(MultiplierClass scalingClass) internal pure {
        require(uint256(scalingClass) < UIScalingMath.SCALING_CLASS_COUNT, "ERC8056: unknown scaling class");
    }
}
