// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title YieldToken
 * @notice Fungible ERC-20 receipt for the yield leg of a ERC8056PairWrapper pair.
 *
 * One yield token of a window is a claim on that window's frozen coupon
 * (`max(1 - Y_start/Y_target, 0)`), priced from historical checkpoints only and
 * payable once `yieldNonce() >= target`. All yield tokens of the same
 * (start, target) window are fungible with each other.
 *
 * Minted and burned only by the owning wrapper.
 */
contract YieldToken is ERC20 {
    address public immutable minter;

    error Unauthorized();

    constructor(string memory name_, string memory symbol_, address minter_) ERC20(name_, symbol_) {
        minter = minter_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert Unauthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) revert Unauthorized();
        _burn(from, amount);
    }
}
