// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockConfigurableToken
/// @notice TEST FIXTURE. A Stock-Token-shaped ERC-20 with arbitrary decimals.
///
/// @dev `MockStockToken` is deliberately pinned to the real surface (18 decimals,
///      the live AAPL multiplier) so the main harness cannot drift from mainnet.
///      This one exists only for the pricing specification tests, where the point
///      is to exercise decimal combinations that do NOT occur on Robinhood Chain
///      today — because the policy reads `decimals()` from the token rather than
///      hardcoding 18, and that behaviour needs proving.
contract MockConfigurableToken is ERC20 {
    uint8 private immutable _decimals;

    uint256 private _uiMultiplier = 1e18;
    uint256 private _newUIMultiplier = 1e18;
    uint256 private _effectiveAt;
    bool private _oraclePaused;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // --- ERC-8056 surface ---------------------------------------------------

    function uiMultiplier() public view returns (uint256) {
        if (_effectiveAt != 0 && block.timestamp >= _effectiveAt) return _newUIMultiplier;
        return _uiMultiplier;
    }

    function newUIMultiplier() external view returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() external view returns (uint256) {
        return _effectiveAt;
    }

    function oraclePaused() external view returns (bool) {
        return _oraclePaused;
    }

    // --- Test controls ------------------------------------------------------

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setUIMultiplier(uint256 m) external {
        _uiMultiplier = m;
        _newUIMultiplier = m;
        _effectiveAt = 0;
    }

    function setOraclePaused(bool paused) external {
        _oraclePaused = paused;
    }
}
