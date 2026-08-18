// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title YieldToken
 * @notice Fungible ERC-20 receipt for the yield leg of a ScaledPairWrapper pair.
 *
 * One yield token is a claim on `poolYieldRaw / yieldSupply` raw units of the bucket's
 * accrued yield pool. All yield tokens of a bucket share one uniform value, so tokens
 * from stakes made at different factors are fungible.
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
