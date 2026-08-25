// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LegToken
 * @notice Fungible ERC-20 receipt for one leg (capital or yield) of an ERC8056PairWrapper pair.
 *
 * Each window mints exactly two LegToken instances via the wrapper: one
 * representing the capital leg (principal claim, `1 - coupon`) and one
 * representing the yield leg (coupon claim). Both legs are standard,
 * fungible ERC-20 tokens. Minted and burned only by the owning wrapper.
 */
contract LegToken is ERC20 {
    address public immutable minter;
    uint8 private immutable _decimals;

    error Unauthorized();

    constructor(string memory name_, string memory symbol_, address minter_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        minter = minter_;
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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
