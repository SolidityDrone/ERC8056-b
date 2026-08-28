// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056CompositePairWrapper} from "../src/ERC8056CompositePairWrapper.sol";
import {ERC8056CompositePairWrapperHandler} from "./ERC8056CompositePairWrapperHandler.sol";
import {MultiplierClass} from "../src/interfaces/extension/IERC8056MultiplierClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Invariant suite for the embedded Capital/Yield wrapper.
///      Same ghost-variable invariants, but escrow = token.balanceOf(address(token))
///      (the token self-escrows; there is no separate wrapper vault).
contract ERC8056CompositePairWrapperInvariantTest is ScalingTestBase {
    ERC8056CompositePairWrapper internal token;
    ERC8056CompositePairWrapperHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        token = new ERC8056CompositePairWrapper("Stock", "STK", owner);
        handler = new ERC8056CompositePairWrapperHandler(token, owner);
        targetContract(address(handler));
    }

    /// @dev Upper bound of all outstanding claims. Effective pairs use the frozen
    ///      coupon; unexpired pairs claim at most one raw per unit (coupon in [0, 1e18]).
    function _totalClaims() internal view returns (uint256) {
        uint256 claims;
        uint256 count = token.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = token.pairAt(i);
            uint256 capSupply = token.capitalSupplyOf(start, target);
            uint256 yldSupply = token.yieldSupplyOf(start, target);
            if (token.currentNonce() >= target) {
                uint256 coupon = token.couponOf(start, target);
                claims += Math.mulDiv(yldSupply, coupon, 1e18);
                claims += Math.mulDiv(capSupply, 1e18 - coupon, 1e18);
            } else {
                // Equal-leg unwrap is the only redemption path before the target is
                // effective; it needs BOTH legs, so only min(cap, yld) units are
                // claimable (1 raw each). Exact, not an over-estimate.
                claims += capSupply > yldSupply ? yldSupply : capSupply;
            }
        }
        return claims;
    }

    function invariant_solvency_claimsNeverExceedPool() public view {
        assertLe(_totalClaims(), token.rawLocked(), "claims exceed pool");
    }

    function invariant_bookkeeping_balanceEqualsRawLocked() public view {
        assertEq(token.balanceOf(address(token)), token.rawLocked(), "escrow != rawLocked");
    }

    function invariant_ghosts_noClaimsBeyondDeposits() public view {
        // claims == remaining deposits exactly (coupon + share = 1); solo-leg floor
        // rounding leaves <1 wei per solo redemption, and _totalClaims floors each
        // leg by up to 1 wei. Allow that principled slack, not a magic constant.
        uint256 dust = handler.soloRedemptions() + token.pairCount() * 2;
        assertLe(_totalClaims(), handler.totalDeposited() - handler.totalRedeemed() + dust, "ghost drift");
    }

    function invariant_coupon_matchesHistory() public view {
        uint256 count = token.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = token.pairAt(i);
            if (token.currentNonce() < target) continue;
            uint256 yStart = token.classEventAtNonce(MultiplierClass.Yield, start).cumulativeMultiplier;
            uint256 yTarget = token.classEventAtNonce(MultiplierClass.Yield, target).cumulativeMultiplier;
            uint256 expected = yTarget > yStart ? Math.mulDiv(yTarget - yStart, 1e18, yTarget) : 0;
            assertEq(token.couponOf(start, target), expected, "coupon drifted from history");
        }
    }

    function invariant_noStuckRaw() public view {
        // Unclaimed raw is dust from floor rounding: each solo redemption leaves
        // <1 wei, and _totalClaims floors each leg by up to 1 wei. Bound by the
        // actual solo-redemption count plus the per-pair claim floor, not a magic
        // constant.
        uint256 dust = handler.soloRedemptions() + token.pairCount() * 2;
        assertLe(token.rawLocked() - _totalClaims(), dust, "unclaimed raw exceeds dust");
    }
}
