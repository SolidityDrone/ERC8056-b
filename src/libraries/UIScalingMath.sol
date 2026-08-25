// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev Pure math for Supply / Yield decomposed UI scaling.
 *
 * Capital (principal) accounting uses the Yield class only. Supply events
 * redenominate share count without reallocating raw between capital and yield.
 */
library UIScalingMath {
    uint256 internal constant MULTIPLIER_DECIMALS = 1e18;
    uint256 internal constant SCALING_CLASS_COUNT = 3;

    error ZeroFactor();

    /// @dev Composite UI multiplier from all three classes: Supply * Yield * Other.
    function composeUiMultiplier(uint256 supplyFactor, uint256 yieldFactor, uint256 otherFactor)
        internal
        pure
        returns (uint256)
    {
        if (supplyFactor == 0 || yieldFactor == 0 || otherFactor == 0) revert ZeroFactor();
        uint256 result = MULTIPLIER_DECIMALS;
        result = Math.mulDiv(result, supplyFactor, MULTIPLIER_DECIMALS);
        result = Math.mulDiv(result, yieldFactor, MULTIPLIER_DECIMALS);
        result = Math.mulDiv(result, otherFactor, MULTIPLIER_DECIMALS);
        return result;
    }

    function toUIAmount(uint256 rawAmount, uint256 factor) internal pure returns (uint256) {
        return Math.mulDiv(rawAmount, factor, MULTIPLIER_DECIMALS);
    }

    function fromUIAmount(uint256 uiAmount, uint256 factor) internal pure returns (uint256) {
        if (factor == 0) revert ZeroFactor();
        return Math.mulDiv(uiAmount, MULTIPLIER_DECIMALS, factor);
    }

    /// @dev Raw principal leg. Only Yield accretion dilutes capital in raw terms.
    function capitalRaw(uint256 rawStaked, uint256 yieldFactorAtStake, uint256 yieldFactorCurrent)
        internal
        pure
        returns (uint256)
    {
        if (yieldFactorCurrent == 0) revert ZeroFactor();
        return Math.mulDiv(rawStaked, yieldFactorAtStake, yieldFactorCurrent);
    }

    /// @dev Raw yield leg (remainder after capital). Returns 0 when the yield
    ///      factor decreased since stake (principal protection).
    function yieldLegRaw(uint256 rawStaked, uint256 capitalRawAmount) internal pure returns (uint256) {
        return rawStaked > capitalRawAmount ? rawStaked - capitalRawAmount : 0;
    }

    /// @dev Yield-class growth since a stake snapshot (Supply excluded).
    function yieldGrowthSinceStake(uint256 yieldFactorAtStake, uint256 yieldFactorCurrent)
        internal
        pure
        returns (uint256)
    {
        if (yieldFactorAtStake == 0) revert ZeroFactor();
        return Math.mulDiv(yieldFactorCurrent, MULTIPLIER_DECIMALS, yieldFactorAtStake);
    }
}
