// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC8056} from "../interfaces/IERC8056.sol";
import {IERC8056Conversion} from "../interfaces/IERC8056Conversion.sol";
import {IERC8056Balances} from "../interfaces/IERC8056Balances.sol";
import {IERC8056NewUIMultiplier} from "../interfaces/IERC8056NewUIMultiplier.sol";
import {IERC8056Composite} from "./interfaces/IERC8056Composite.sol";
import {MultiplierClass} from "./interfaces/MultiplierClass.sol";
import {UIScalingMath} from "../libraries/UIScalingMath.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";

/**
 * @title ERC8056Composite
 * @notice EIP-8056 with Supply / Yield decomposed scaling, scheduling, and history.
 */
contract ERC8056Composite is
    ERC20,
    ERC165,
    IERC8056,
    IERC8056Conversion,
    IERC8056Balances,
    IERC8056NewUIMultiplier,
    IERC8056Composite,
    Ownable
{
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
        ERC20(name_, symbol_)
        Ownable(initialOwner)
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

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC8056).interfaceId || interfaceId == type(IERC8056Conversion).interfaceId
            || interfaceId == type(IERC8056Balances).interfaceId
            || interfaceId == type(IERC8056NewUIMultiplier).interfaceId
            || interfaceId == type(IERC8056Composite).interfaceId || super.supportsInterface(interfaceId);
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
        // lowerBound returns first index where effectiveAt >= timestamp
        uint256 idx = Arrays.lowerBound(timestamps, timestamp);
        // If idx points to exact match, use it; otherwise go back one
        if (idx < history.length && timestamps[idx] == timestamp) {
            return history[idx].cumulativeMultiplier;
        }
        // idx is first index > timestamp, so idx-1 is last index <= timestamp
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
        return _classScaling[scalingClass].pendingFactor;
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
        for (uint256 i = 1; i < history.length; i++) {
            if (history[i].effectiveAt <= block.timestamp) {
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
        uint256 index = nonce; // genesis checkpoint occupies index 0; event nonce 1 is index 1
        if (index >= history.length) revert EventNotRecorded();
        if (history[index].effectiveAt > block.timestamp) revert EventNotEffective();
        return ClassScalingEvent(
            history[index].effectiveAt, history[index].cumulativeMultiplier, history[index].multiplierDelta
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
    ) public override onlyOwner {
        _setMultiplier(scalingClass, newMultiplier, effectiveAtTimestamp, id, description, uri);
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
            state.activeFactor = state.pendingFactor;
        }

        state.pendingFactor = newMultiplier;
        state.effectiveAt = effectiveAtTimestamp;

        uint256 delta =
            oldMultiplier == 0 ? newMultiplier : newMultiplier * UIScalingMath.MULTIPLIER_DECIMALS / oldMultiplier;
        history.push(ScalingCheckpoint(effectiveAtTimestamp, newMultiplier, delta));
        _checkpointTimestamps[scalingClass].push(effectiveAtTimestamp);
        uint256 nonce = getClassNonce(scalingClass);

        emit UIScalingFactorUpdated(
            scalingClass,
            newMultiplier,
            delta,
            effectiveAtTimestamp,
            nonce,
            Announcement({id: id, description: description, uri: uri})
        );
        emit UIMultiplierUpdated(oldComposite, _compositeFromPending(), effectiveAtTimestamp);
    }

    //==============================================================================//
    // ERC-8056 composite                                                           //
    //==============================================================================//
    function uiMultiplier() public view override returns (uint256) {
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

    function newUIMultiplier() public view override returns (uint256) {
        return _compositeFromPending();
    }

    function effectiveAt() public view override returns (uint256) {
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
    function toUIAmount(uint256 rawAmount) public view override returns (uint256) {
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

    function fromUIAmount(uint256 uiAmount) public view override returns (uint256) {
        return UIScalingMath.fromUIAmount(uiAmount, uiMultiplier());
    }

    function fromUIAmount(uint256 uiAmount, MultiplierClass scalingClass) public view returns (uint256) {
        return UIScalingMath.fromUIAmount(uiAmount, uiScalingFactor(scalingClass));
    }

    function balanceOfUI(address account) public view override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    function totalSupplyUI() public view override returns (uint256) {
        return toUIAmount(totalSupply());
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        super._update(from, to, amount);
        emit TransferWithUIAmount(from, to, amount, toUIAmount(amount));
    }

    function _compositeFromPending() internal view returns (uint256) {
        return UIScalingMath.composeUiMultiplier(
            _factorForComposite(MultiplierClass.Supply, true),
            _factorForComposite(MultiplierClass.Yield, true),
            _factorForComposite(MultiplierClass.Other, true)
        );
    }

    function _factorForComposite(MultiplierClass scalingClass, bool usePending) internal view returns (uint256) {
        ClassScalingState storage state = _classScaling[scalingClass];
        if (!usePending) {
            return block.timestamp >= state.effectiveAt ? state.pendingFactor : state.activeFactor;
        }
        return state.pendingFactor;
    }

    function _validateScalingClass(MultiplierClass scalingClass) internal pure {
        require(uint256(scalingClass) < UIScalingMath.SCALING_CLASS_COUNT, "ERC8056: unknown scaling class");
    }
}
