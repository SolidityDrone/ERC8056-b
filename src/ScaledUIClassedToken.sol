// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IScaledUIAmount} from "./interfaces/IScaledUIAmount.sol";
import {IScaledUIAmountConversion} from "./interfaces/IScaledUIAmountConversion.sol";
import {IScaledUIAmountBalances} from "./interfaces/IScaledUIAmountBalances.sol";
import {IScaledUIAmountNewUIMultiplier} from "./interfaces/IScaledUIAmountNewUIMultiplier.sol";
import {IScaledUIAmountClasses} from "./interfaces/IScaledUIAmountClasses.sol";
import {UIScalingClass} from "./interfaces/UIScalingClass.sol";
import {UIScalingMath} from "./libraries/UIScalingMath.sol";

/**
 * @title ScaledUIClassedToken
 * @notice EIP-8056 with Supply / Yield decomposed scaling, scheduling, and history.
 */
contract ScaledUIClassedToken is
    ERC20,
    ERC165,
    IScaledUIAmount,
    IScaledUIAmountConversion,
    IScaledUIAmountBalances,
    IScaledUIAmountNewUIMultiplier,
    IScaledUIAmountClasses,
    Ownable
{
    struct ClassScalingState {
        uint256 activeFactor;
        uint256 pendingFactor;
        uint256 effectiveAt;
    }

    error EventNotRecorded();
    error EventNotEffective();

    mapping(UIScalingClass => ClassScalingState) private _classScaling;
    mapping(UIScalingClass => ScalingCheckpoint[]) private _checkpoints;

    constructor(string memory name_, string memory symbol_, address initialOwner)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            UIScalingClass scalingClass = UIScalingClass(i);
            _classScaling[scalingClass] = ClassScalingState({
                activeFactor: UIScalingMath.MULTIPLIER_DECIMALS,
                pendingFactor: UIScalingMath.MULTIPLIER_DECIMALS,
                effectiveAt: type(uint256).max
            });
            _checkpoints[scalingClass].push(ScalingCheckpoint(0, UIScalingMath.MULTIPLIER_DECIMALS));
        }
        emit UIMultiplierUpdated(0, UIScalingMath.MULTIPLIER_DECIMALS, block.timestamp);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IScaledUIAmount).interfaceId ||
            interfaceId == type(IScaledUIAmountConversion).interfaceId ||
            interfaceId == type(IScaledUIAmountBalances).interfaceId ||
            interfaceId == type(IScaledUIAmountNewUIMultiplier).interfaceId ||
            interfaceId == type(IScaledUIAmountClasses).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    //==============================================================================//
    // Class reads                                                                  //
    //==============================================================================//
    function uiScalingFactor(UIScalingClass scalingClass) public view override returns (uint256) {
        return uiScalingFactorAt(scalingClass, block.timestamp);
    }

    function uiScalingFactorAt(UIScalingClass scalingClass, uint256 timestamp)
        public
        view
        override
        returns (uint256)
    {
        _validateScalingClass(scalingClass);
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];
        uint256 factor = UIScalingMath.MULTIPLIER_DECIMALS;
        for (uint256 i = 0; i < history.length; i++) {
            if (history[i].effectiveAt <= timestamp) {
                factor = history[i].cumulativeFactor;
            } else {
                break;
            }
        }
        return factor;
    }

    function uiMultiplierAt(uint256 timestamp) public view override returns (uint256) {
        return UIScalingMath.composeSupplyYield(
            uiScalingFactorAt(UIScalingClass.Supply, timestamp),
            uiScalingFactorAt(UIScalingClass.Yield, timestamp)
        );
    }

    function pendingUIScalingFactor(UIScalingClass scalingClass) public view override returns (uint256) {
        return _classScaling[scalingClass].pendingFactor;
    }

    function scalingFactorEffectiveAt(UIScalingClass scalingClass) public view override returns (uint256) {
        if (!hasPendingScalingFactor(scalingClass)) return 0;
        return _classScaling[scalingClass].effectiveAt;
    }

    function hasPendingScalingFactor(UIScalingClass scalingClass) public view override returns (bool) {
        ClassScalingState storage state = _classScaling[scalingClass];
        return block.timestamp < state.effectiveAt && state.effectiveAt != type(uint256).max;
    }

    function scalingHistoryLength(UIScalingClass scalingClass) external view override returns (uint256) {
        return _checkpoints[scalingClass].length;
    }

    function scalingCheckpointAt(UIScalingClass scalingClass, uint256 index)
        external
        view
        override
        returns (ScalingCheckpoint memory)
    {
        return _checkpoints[scalingClass][index];
    }

    /// @dev Number of effective Yield events. Derived from the Yield checkpoint
    ///      history: genesis (index 0) is not an event and pending updates
    ///      (effectiveAt in the future) are excluded, so the nonce only ticks
    ///      when a dividend actually lands.
    function yieldNonce() public view override returns (uint256) {
        ScalingCheckpoint[] storage history = _checkpoints[UIScalingClass.Yield];
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

    /// @dev Yield event with 1-based `nonce`: `{timestamp, multiplier}` of the
    ///      nonce-th effective Yield update. Pending updates are not visible.
    function yieldEventAt(uint256 nonce) external view override returns (YieldEvent memory) {
        ScalingCheckpoint[] storage history = _checkpoints[UIScalingClass.Yield];
        uint256 index = nonce; // genesis checkpoint occupies index 0; event nonce 1 is index 1
        if (index >= history.length) revert EventNotRecorded();
        if (history[index].effectiveAt > block.timestamp) revert EventNotEffective();
        return YieldEvent(history[index].effectiveAt, history[index].cumulativeFactor);
    }

    //==============================================================================//
    // Class writes (enum required - no generic update)                             //
    //==============================================================================//
    function setUIScalingFactor(
        UIScalingClass scalingClass,
        uint256 newFactor,
        uint256 effectiveAtTimestamp
    ) public override onlyOwner {
        _setScalingFactor(scalingClass, newFactor, effectiveAtTimestamp);
    }

    function applyUIScalingDelta(
        UIScalingClass scalingClass,
        uint256 factorDelta,
        uint256 effectiveAtTimestamp
    ) external override onlyOwner {
        require(factorDelta > 0, "ERC8056: delta must be positive");
        uint256 currentFactor = _currentFactorForDelta(scalingClass);
        uint256 newFactor = Math.mulDiv(currentFactor, factorDelta, UIScalingMath.MULTIPLIER_DECIMALS);
        _setScalingFactor(scalingClass, newFactor, effectiveAtTimestamp);
    }

    function _setScalingFactor(
        UIScalingClass scalingClass,
        uint256 newFactor,
        uint256 effectiveAtTimestamp
    ) internal {
        _validateScalingClass(scalingClass);
        require(newFactor > 0, "ERC8056: factor must be positive");
        require(effectiveAtTimestamp > block.timestamp, "ERC8056: effective time must be future");

        ClassScalingState storage state = _classScaling[scalingClass];
        ScalingCheckpoint[] storage history = _checkpoints[scalingClass];

        uint256 oldComposite = uiMultiplier();
        uint256 oldFactor = uiScalingFactor(scalingClass);

        if (hasPendingScalingFactor(scalingClass)) {
            history.pop();
        } else if (block.timestamp >= state.effectiveAt) {
            state.activeFactor = state.pendingFactor;
        }

        state.pendingFactor = newFactor;
        state.effectiveAt = effectiveAtTimestamp;
        history.push(ScalingCheckpoint(effectiveAtTimestamp, newFactor));

        emit UIScalingFactorUpdated(scalingClass, oldFactor, newFactor, effectiveAtTimestamp);
        emit UIMultiplierUpdated(oldComposite, _compositeFromPending(), effectiveAtTimestamp);
    }

    //==============================================================================//
    // ERC-8056 composite                                                           //
    //==============================================================================//
    function uiMultiplier() public view override returns (uint256) {
        return uiMultiplierAt(block.timestamp);
    }

    function newUIMultiplier() public view override returns (uint256) {
        return _compositeFromPending();
    }

    function effectiveAt() public view override returns (uint256) {
        uint256 earliest = type(uint256).max;
        bool found;
        for (uint256 i = 0; i < UIScalingMath.SCALING_CLASS_COUNT; i++) {
            UIScalingClass scalingClass = UIScalingClass(i);
            if (hasPendingScalingFactor(scalingClass)) {
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

    function toUIAmount(uint256 rawAmount, UIScalingClass scalingClass) public view returns (uint256) {
        return UIScalingMath.toUIAmount(rawAmount, uiScalingFactor(scalingClass));
    }

    function toUIAmountAt(uint256 rawAmount, uint256 timestamp) public view returns (uint256) {
        return UIScalingMath.toUIAmount(rawAmount, uiMultiplierAt(timestamp));
    }

    function toUIAmountAt(uint256 rawAmount, UIScalingClass scalingClass, uint256 timestamp)
        public
        view
        returns (uint256)
    {
        return UIScalingMath.toUIAmount(rawAmount, uiScalingFactorAt(scalingClass, timestamp));
    }

    function fromUIAmount(uint256 uiAmount) public view override returns (uint256) {
        return UIScalingMath.fromUIAmount(uiAmount, uiMultiplier());
    }

    function fromUIAmount(uint256 uiAmount, UIScalingClass scalingClass) public view returns (uint256) {
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
        return UIScalingMath.composeSupplyYield(
            _factorForComposite(UIScalingClass.Supply, true),
            _factorForComposite(UIScalingClass.Yield, true)
        );
    }

    function _factorForComposite(UIScalingClass scalingClass, bool usePending) internal view returns (uint256) {
        ClassScalingState storage state = _classScaling[scalingClass];
        if (!usePending) {
            return block.timestamp >= state.effectiveAt ? state.pendingFactor : state.activeFactor;
        }
        return state.pendingFactor;
    }

    function _currentFactorForDelta(UIScalingClass scalingClass) internal view returns (uint256) {
        if (hasPendingScalingFactor(scalingClass)) {
            return pendingUIScalingFactor(scalingClass);
        }
        return uiScalingFactor(scalingClass);
    }

    function _validateScalingClass(UIScalingClass scalingClass) internal pure {
        require(uint256(scalingClass) < UIScalingMath.SCALING_CLASS_COUNT, "ERC8056: unknown scaling class");
    }
}
