// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC8056} from "./extensions/interfaces/IERC8056.sol";
import {IERC8056Conversion} from "./extensions/interfaces/IERC8056Conversion.sol";
import {IERC8056Balances} from "./extensions/interfaces/IERC8056Balances.sol";
import {IERC8056NewUIMultiplier} from "./extensions/interfaces/IERC8056NewUIMultiplier.sol";

/**
 * @title ERC8056
 * @notice Reference implementation from EIP-8056.
 * @dev See https://eips.ethereum.org/EIPS/eip-8056
 */
contract ERC8056 is ERC20, ERC165, IERC8056, IERC8056Conversion, IERC8056Balances, IERC8056NewUIMultiplier, Ownable {
    uint256 private constant MULTIPLIER_DECIMALS = 1e18;
    uint256 private _uiMultiplier = MULTIPLIER_DECIMALS;
    uint256 private _newUIMultiplier = MULTIPLIER_DECIMALS;
    uint256 private _effectiveAt;

    constructor(string memory name_, string memory symbol_, address initialOwner)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC8056).interfaceId || interfaceId == type(IERC8056Conversion).interfaceId
            || interfaceId == type(IERC8056Balances).interfaceId
            || interfaceId == type(IERC8056NewUIMultiplier).interfaceId || super.supportsInterface(interfaceId);
    }

    function uiMultiplier() public view override returns (uint256) {
        if (block.timestamp >= _effectiveAt) {
            return _newUIMultiplier;
        }
        return _uiMultiplier;
    }

    function newUIMultiplier() public view override returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() public view override returns (uint256) {
        return _effectiveAt;
    }

    function setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) external onlyOwner {
        require(newMultiplier > 0, "Multiplier must be positive");
        require(effectiveAtTimestamp > block.timestamp, "Effective At must be in the future");

        if (block.timestamp > _effectiveAt) {
            uint256 oldMultiplier = _newUIMultiplier;
            _uiMultiplier = oldMultiplier;
            _newUIMultiplier = newMultiplier;
            _effectiveAt = effectiveAtTimestamp;
            emit UIMultiplierUpdated(oldMultiplier, newMultiplier, effectiveAtTimestamp);
        } else {
            uint256 oldMultiplier = _uiMultiplier;
            _newUIMultiplier = newMultiplier;
            _effectiveAt = effectiveAtTimestamp;
            emit UIMultiplierUpdated(oldMultiplier, newMultiplier, effectiveAtTimestamp);
        }
    }

    function toUIAmount(uint256 rawAmount) public view override returns (uint256) {
        if (block.timestamp >= _effectiveAt) {
            return (rawAmount * _newUIMultiplier) / MULTIPLIER_DECIMALS;
        }
        return (rawAmount * _uiMultiplier) / MULTIPLIER_DECIMALS;
    }

    function fromUIAmount(uint256 uiAmount) public view override returns (uint256) {
        if (block.timestamp >= _effectiveAt) {
            return (uiAmount * MULTIPLIER_DECIMALS) / _newUIMultiplier;
        }
        return (uiAmount * MULTIPLIER_DECIMALS) / _uiMultiplier;
    }

    function balanceOfUI(address account) public view override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    function totalSupplyUI() public view override returns (uint256) {
        return toUIAmount(totalSupply());
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        super._update(from, to, amount);
        uint256 uiAmount = toUIAmount(amount);
        emit TransferWithUIAmount(from, to, amount, uiAmount);
    }
}
