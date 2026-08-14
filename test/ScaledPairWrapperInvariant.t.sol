// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ScaledPairWrapper} from "../src/ScaledPairWrapper.sol";
import {ScaledPairWrapperHandler} from "./ScaledPairWrapperHandler.sol";
import {ScaledUIClassedToken} from "../src/ScaledUIClassedToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ScaledPairWrapperInvariantTest is ScalingTestBase {
    ScaledUIClassedToken internal underlying;
    ScaledPairWrapper internal wrapper;
    ScaledPairWrapperHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        underlying = new ScaledUIClassedToken("Stock", "STK", owner);
        wrapper = new ScaledPairWrapper(IERC20(address(underlying)), underlying, "Tesla", "Tesla");
        handler = new ScaledPairWrapperHandler(underlying, wrapper, owner);
        targetContract(address(handler));
    }

    /// @dev Upper bound of all outstanding claims. Effective pairs use the frozen
    ///      coupon; unexpired pairs claim at most one raw per unit (coupon in [0, 1e18]).
    function _totalClaims() internal view returns (uint256) {
        uint256 claims;
        uint256 count = wrapper.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = wrapper.pairAt(i);
            uint256 capSupply = wrapper.capitalSupplyOf(start, target);
            uint256 yldSupply = wrapper.yieldSupplyOf(start, target);
            if (wrapper.currentNonce() >= target) {
                uint256 coupon = wrapper.couponOf(start, target);
                claims += Math.mulDiv(yldSupply, coupon, 1e18);
                claims += Math.mulDiv(capSupply, 1e18 - coupon, 1e18);
            } else {
                claims += capSupply > yldSupply ? capSupply : yldSupply;
            }
        }
        return claims;
    }

    function invariant_solvency_claimsNeverExceedPool() public view {
        assertLe(_totalClaims(), wrapper.rawLocked(), "claims exceed pool");
    }

    function invariant_bookkeeping_balanceEqualsRawLocked() public view {
        assertEq(underlying.balanceOf(address(wrapper)), wrapper.rawLocked(), "balance != rawLocked");
    }

    function invariant_ghosts_noClaimsBeyondDeposits() public view {
        // claims == remaining deposits exactly (coupon + share = 1); solo-leg floor
        // rounding can leave <=1 wei of dust per claimer per pair, so allow slack.
        uint256 dust = wrapper.pairCount() * 8; // handler has 8 actors
        assertLe(
            _totalClaims(),
            handler.totalDeposited() - handler.totalRedeemed() + dust,
            "ghost drift"
        );
    }

    function invariant_coupon_matchesHistory() public view {
        uint256 count = wrapper.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = wrapper.pairAt(i);
            if (wrapper.currentNonce() < target) continue;
            uint256 yStart = underlying.yieldEventAt(start).multiplier;
            uint256 yTarget = underlying.yieldEventAt(target).multiplier;
            uint256 expected = yTarget > yStart ? Math.mulDiv(yTarget - yStart, 1e18, yTarget) : 0;
            assertEq(wrapper.couponOf(start, target), expected, "coupon drifted from history");
        }
    }

    function invariant_noStuckRaw() public view {
        // Fully unwrapped pairs leave at most 1 wei of dust per claimer (handler: 8 actors).
        assertLe(wrapper.rawLocked() - _totalClaims(), wrapper.pairCount() * 8, "unclaimed raw exceeds dust");
    }
}
