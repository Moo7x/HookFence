// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockStockToken
/// @notice TEST FIXTURE. A controllable stand-in for a Robinhood Stock Token.
///
/// @dev This is NOT a Robinhood Stock Token and must never be presented as one.
///      It reproduces the surface that was read from the live AAPL token
///      (0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9) on Robinhood Chain mainnet on
///      2026-09-20, so that policy logic exercised here is the same logic that runs
///      against the real asset:
///
///        decimals()        -> 18
///        uiMultiplier()    -> 1000566080061092436   (~1.000566, dividends reinvested)
///        newUIMultiplier() -> same when nothing is scheduled
///        effectiveAt()     -> timestamp for the pending multiplier
///        oraclePaused()    -> false in steady state
///
///      ERC-8056 semantics: the multiplier scales the *effective* amount. Raw
///      balanceOf and totalSupply are untouched - Stock Tokens are not rebasing.
contract MockStockToken is ERC20 {
    /// @dev Matches the live AAPL multiplier read on 2026-09-20.
    uint256 public constant INITIAL_MULTIPLIER = 1_000_566_080_061_092_436;

    uint256 private _uiMultiplier;
    uint256 private _newUIMultiplier;
    uint256 private _effectiveAt;
    bool private _oraclePaused;

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event TransferWithScaledUI(address indexed from, address indexed to, uint256 value, uint256 uiValue);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _uiMultiplier = INITIAL_MULTIPLIER;
        _newUIMultiplier = INITIAL_MULTIPLIER;
    }

    // --- ERC-8056 -----------------------------------------------------------

    /// @notice Current multiplier, advancing automatically at `effectiveAt`.
    /// @dev This time dependence is deliberate and matches the ERC-8056 reference
    ///      implementation. An earlier version of this mock only changed the
    ///      multiplier when a test called a setter, which meant the mock could never
    ///      produce the state where a scheduled change has just fired. That hid a
    ///      real bug in the policy's corporate-action window - `newUIMultiplier()`
    ///      and `uiMultiplier()` become equal *at* `effectiveAt`, not after some
    ///      later settlement step. A fixture that cannot reach a state cannot test
    ///      it, so the mock now reproduces the reference behaviour.
    function uiMultiplier() public view returns (uint256) {
        if (_effectiveAt != 0 && block.timestamp >= _effectiveAt) {
            return _newUIMultiplier;
        }
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

    function balanceOfUI(address account) external view returns (uint256) {
        return (balanceOf(account) * uiMultiplier()) / 1e18;
    }

    function totalSupplyUI() external view returns (uint256) {
        return (totalSupply() * uiMultiplier()) / 1e18;
    }

    // --- Test controls ------------------------------------------------------

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Apply a corporate action immediately (e.g. a completed split).
    /// @dev Clears any schedule so `uiMultiplier()` returns `m` unconditionally.
    function setUIMultiplier(uint256 m) external {
        uint256 old = _uiMultiplier;
        _uiMultiplier = m;
        _newUIMultiplier = m;
        _effectiveAt = 0;
        emit UIMultiplierUpdated(old, m, block.timestamp);
    }

    /// @notice Schedule a corporate action ahead of time.
    /// @dev Mirrors the real token: newUIMultiplier() diverges from uiMultiplier()
    ///      and effectiveAt() carries the switchover time.
    function scheduleMultiplier(uint256 pending, uint256 effectiveAt_) external {
        _newUIMultiplier = pending;
        _effectiveAt = effectiveAt_;
        emit UIMultiplierUpdated(_uiMultiplier, pending, effectiveAt_);
    }

    /// @notice Toggle the advisory oracle pause flag.
    function setOraclePaused(bool paused) external {
        _oraclePaused = paused;
    }
}
