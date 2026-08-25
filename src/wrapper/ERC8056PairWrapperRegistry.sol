// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8056Composite} from "../extensions/interfaces/IERC8056Composite.sol";
import {IERC8056PairWrapper} from "./interfaces/IERC8056PairWrapper.sol";
import {IERC8056PairWrapperRegistry} from "./interfaces/IERC8056PairWrapperRegistry.sol";
import {ERC8056PairWrapper} from "./ERC8056PairWrapper.sol";

/**
 * @title ERC8056PairWrapperRegistry
 * @notice Immutable per-asset singleton registry. deployOrGet deploys and caches the
 *         canonical ERC8056PairWrapper for each underlying; subsequent calls for the
 *         same underlying are idempotent and return the cached address.
 */
contract ERC8056PairWrapperRegistry is IERC8056PairWrapperRegistry {
    /// @dev Thrown when `scaledUnderlying` does not implement IERC8056Composite (ERC-165).
    error UnsupportedExtension();

    /// @dev Thrown when `scaledUnderlying` is a different contract than `underlying`.
    error ExtensionMismatch();
    mapping(address => IERC8056PairWrapper) internal _wrappers;
    IERC8056PairWrapper[] internal _wrapperList;
    mapping(address => IERC20) internal _underlyingOf;

    /// @inheritdoc IERC8056PairWrapperRegistry
    function wrapperFor(IERC20 underlying) public view returns (IERC8056PairWrapper) {
        return _wrappers[address(underlying)];
    }

    /// @inheritdoc IERC8056PairWrapperRegistry
    function deployOrGet(
        IERC20 underlying,
        IERC8056Composite scaledUnderlying,
        string calldata name,
        string calldata symbol
    ) public returns (IERC8056PairWrapper) {
        IERC8056PairWrapper existing = _wrappers[address(underlying)];
        if (address(existing) != address(0)) return existing;

        // The canonical wrapper must be the one true extension: the underlying RWA
        // token IS the class-decomposed extension (an ERC8056Composite). Binding
        // the two prevents a third party from front-running deployOrGet and binding
        // a wrapper that prices redemptions off a different (untrusted) extension.
        if (address(scaledUnderlying) != address(underlying)) revert ExtensionMismatch();
        if (!_supportsComposite(address(scaledUnderlying))) revert UnsupportedExtension();

        ERC8056PairWrapper wrapper = new ERC8056PairWrapper(underlying, scaledUnderlying, name, symbol);
        IERC8056PairWrapper canonical = IERC8056PairWrapper(address(wrapper));

        _wrappers[address(underlying)] = canonical;
        _underlyingOf[address(canonical)] = underlying;
        _wrapperList.push(canonical);

        emit PairWrapperDeployed(underlying, scaledUnderlying, canonical);
        return canonical;
    }

    /// @inheritdoc IERC8056PairWrapperRegistry
    function wrapperCount() public view returns (uint256) {
        return _wrapperList.length;
    }

    /// @inheritdoc IERC8056PairWrapperRegistry
    function wrapperAt(uint256 index) public view returns (IERC8056PairWrapper) {
        return _wrapperList[index];
    }

    /// @inheritdoc IERC8056PairWrapperRegistry
    function underlyingOf(IERC8056PairWrapper wrapper) public view returns (IERC20) {
        return _underlyingOf[address(wrapper)];
    }

    /// @dev ERC-165 check that `candidate` implements IERC8056Composite. The generic
    ///      `catch` also swallows revert-and-empty-return cases (code-less address) and
    ///      non-decodable return data, so only a genuine `true` passes.
    function _supportsComposite(address candidate) internal view returns (bool) {
        try IERC165(candidate).supportsInterface(type(IERC8056Composite).interfaceId) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
