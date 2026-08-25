// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScalingTestBase} from "./ScalingTestBase.sol";
import {ERC8056PairWrapper} from "../src/wrapper/ERC8056PairWrapper.sol";
import {ERC8056PairWrapperHandler} from "./ERC8056PairWrapperHandler.sol";
import {ERC8056Composite} from "../src/extensions/ERC8056Composite.sol";
import {MultiplierClass} from "../src/extensions/interfaces/IERC8056MultiplierClass.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC8056PairWrapperInvariantTest is ScalingTestBase {
    ERC8056Composite internal underlying;
    ERC8056PairWrapper internal wrapper;
    ERC8056PairWrapperHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        underlying = new ERC8056Composite("Stock", "STK", owner);
        wrapper = new ERC8056PairWrapper(IERC20(address(underlying)), underlying, "Tesla", "Tesla");
        handler = new ERC8056PairWrapperHandler(underlying, wrapper, owner);
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
                // Equal-leg unwrap is the only redemption path before the target is
                // effective; it needs BOTH legs, so only min(cap, yld) units are
                // claimable (1 raw each). Exact, not an over-estimate.
                claims += capSupply > yldSupply ? yldSupply : capSupply;
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
        // rounding leaves <1 wei per solo redemption, and _totalClaims floors each
        // leg by up to 1 wei. Allow that principled slack, not a magic constant.
        uint256 dust = handler.soloRedemptions() + wrapper.pairCount() * 2;
        assertLe(_totalClaims(), handler.totalDeposited() - handler.totalRedeemed() + dust, "ghost drift");
    }

    function invariant_coupon_matchesHistory() public view {
        uint256 count = wrapper.pairCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 start, uint256 target) = wrapper.pairAt(i);
            if (wrapper.currentNonce() < target) continue;
            uint256 yStart = underlying.classEventAtNonce(MultiplierClass.Yield, start).cumulativeMultiplier;
            uint256 yTarget = underlying.classEventAtNonce(MultiplierClass.Yield, target).cumulativeMultiplier;
            uint256 expected = yTarget > yStart ? Math.mulDiv(yTarget - yStart, 1e18, yTarget) : 0;
            assertEq(wrapper.couponOf(start, target), expected, "coupon drifted from history");
        }
    }

    function invariant_noStuckRaw() public view {
        // Unclaimed raw is dust from floor rounding: each solo redemption leaves
        // <1 wei, and _totalClaims floors each leg by up to 1 wei. Bound by the
        // actual solo-redemption count plus the per-pair claim floor, not a magic
        // constant.
        uint256 dust = handler.soloRedemptions() + wrapper.pairCount() * 2;
        assertLe(wrapper.rawLocked() - _totalClaims(), dust, "unclaimed raw exceeds dust");
    }
}
