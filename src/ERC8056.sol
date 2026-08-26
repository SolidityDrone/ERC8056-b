// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC8056} from "./interfaces/base/IERC8056.sol";
import {IERC8056Conversion} from "./interfaces/base/IERC8056Conversion.sol";
import {IERC8056Balances} from "./interfaces/base/IERC8056Balances.sol";
import {IERC8056NewUIMultiplier} from "./interfaces/base/IERC8056NewUIMultiplier.sol";
import {IERC8056Cancel} from "./interfaces/base/IERC8056Cancel.sol";

/**
 * @title ERC8056
 * @notice Reference implementation from EIP-8056.
 * @dev See https://eips.ethereum.org/EIPS/eip-8056
 */
contract ERC8056 is
    ERC20,
    ERC165,
    IERC8056,
    IERC8056Conversion,
    IERC8056Balances,
    IERC8056NewUIMultiplier,
    IERC8056Cancel,
    Ownable
{
    uint256 private constant MULTIPLIER_DECIMALS = 1e18;
    uint256 private _uiMultiplier = MULTIPLIER_DECIMALS;
    uint256 private _newUIMultiplier = MULTIPLIER_DECIMALS;
    uint256 private _effectiveAt;

    error ZeroMultiplier();
    error EffectiveAtNotInFuture();
    error NothingToCancel();

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
            || interfaceId == type(IERC8056NewUIMultiplier).interfaceId
            || interfaceId == type(IERC8056Cancel).interfaceId || super.supportsInterface(interfaceId);
    }

    function uiMultiplier() public view virtual override returns (uint256) {
        if (block.timestamp >= _effectiveAt) {
            return _newUIMultiplier;
        }
        return _uiMultiplier;
    }

    function newUIMultiplier() public view virtual override returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() public view virtual override returns (uint256) {
        return _effectiveAt;
    }

    /// @dev Vanilla multiplier as of an explicit timestamp, mirroring {uiMultiplier}
    ///      semantics. Exposed internally so storage-compatible extensions that
    ///      inherit these slots (see ERC8056Composite) can keep serving the vanilla
    ///      denomination during their migration window.
    function _vanillaMultiplierAt(uint256 timestamp) internal view returns (uint256) {
        return timestamp >= _effectiveAt ? _newUIMultiplier : _uiMultiplier;
    }

    function _vanillaNewMultiplier() internal view returns (uint256) {
        return _newUIMultiplier;
    }

    function _vanillaEffectiveAt() internal view returns (uint256) {
        return _effectiveAt;
    }

    function setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) external virtual onlyOwner {
        if (newMultiplier == 0) revert ZeroMultiplier();
        if (effectiveAtTimestamp <= block.timestamp) revert EffectiveAtNotInFuture();

        uint256 previousMultiplier;
        if (block.timestamp >= _effectiveAt) {
            _uiMultiplier = _newUIMultiplier;
            previousMultiplier = _newUIMultiplier;
        } else {
            previousMultiplier = _uiMultiplier;
        }
        _newUIMultiplier = newMultiplier;
        _effectiveAt = effectiveAtTimestamp;
        emit UIMultiplierUpdated(previousMultiplier, newMultiplier, effectiveAtTimestamp);
    }

    function cancelPendingUIMultiplier() external virtual override(IERC8056Cancel) onlyOwner {
        _cancelVanillaPending();
    }

    /// @dev Shared vanilla cancellation so storage-compatible extensions can
    ///      serve exact vanilla cancel semantics on the inherited slots during
    ///      their migration window (see ERC8056Composite).
    function _cancelVanillaPending() internal virtual {
        if (_effectiveAt == 0 || block.timestamp >= _effectiveAt) revert NothingToCancel();

        uint256 pendingMultiplier = _newUIMultiplier;
        _newUIMultiplier = _uiMultiplier;
        _effectiveAt = 0;
        emit UIMultiplierCancelled(pendingMultiplier, _uiMultiplier, block.timestamp);
    }

    function toUIAmount(uint256 rawAmount) public view virtual override returns (uint256) {
        return Math.mulDiv(rawAmount, uiMultiplier(), MULTIPLIER_DECIMALS);
    }

    function fromUIAmount(uint256 uiAmount) public view virtual override returns (uint256) {
        return Math.mulDiv(uiAmount, MULTIPLIER_DECIMALS, uiMultiplier());
    }

    function balanceOfUI(address account) public view virtual override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    function totalSupplyUI() public view virtual override returns (uint256) {
        return toUIAmount(totalSupply());
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        super._update(from, to, amount);
        uint256 uiAmount = toUIAmount(amount);
        emit TransferWithUIAmount(from, to, amount, uiAmount);
    }
}
