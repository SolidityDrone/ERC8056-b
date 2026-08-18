// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title CapitalToken
 * @notice Fungible ERC-20 receipt for the principal leg of a ERC8056PairWrapper pair.
 *
 * One capital token is a claim on one constant Yield-UI unit of principal: its raw
 * value is `1 / yieldFactor(now)` and its Yield-UI value is always 1, independent of
 * when it was minted. This makes tokens from stakes made at different factors fungible.
 *
 * Minted and burned only by the owning wrapper.
 */
contract CapitalToken is ERC20 {
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
