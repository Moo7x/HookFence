// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockPartialStockToken
/// @notice TEST FIXTURE. An equity token that implements ERC-8056 but not
///         `oraclePaused()`.
///
/// @dev This is not a hypothetical. The equity tokens deployed on Robinhood
///      Chain **testnet** (chainId 46630) behave exactly this way. Read on
///      2026-09-23 from TSLA `0xc9f9c86933092bbbfff3ccb4b105a4a94bf3bd4e` and
///      AMZN `0x5884ad2f920c162cfbbacc88c9c51aa75ec09e02`:
///
///        decimals()        -> 18
///        uiMultiplier()    -> 1000000000000000000
///        newUIMultiplier() -> 1000000000000000000
///        effectiveAt()     -> 0
///        totalSupplyUI()   -> 6191600000000000000000000
///        paused()          -> false        (ERC20Pausable, different meaning)
///        oraclePaused()    -> REVERTS      (not implemented)
///
///      A policy that calls `oraclePaused()` unconditionally cannot quote these
///      tokens at all. A policy that wraps the call in try/catch and treats a
///      revert as `false` is worse: it would read a genuinely paused mainnet
///      oracle as healthy if that token ever reverted for another reason.
///      `StockTokenReferencePolicy` therefore probes once at configuration and
///      records the answer.
contract MockPartialStockToken is ERC20 {
    uint256 private _uiMultiplier = 1e18;
    uint256 private _newUIMultiplier = 1e18;
    uint256 private _effectiveAt;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function uiMultiplier() external view returns (uint256) {
        if (_effectiveAt != 0 && block.timestamp >= _effectiveAt) return _newUIMultiplier;
        return _uiMultiplier;
    }

    function newUIMultiplier() external view returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() external view returns (uint256) {
        return _effectiveAt;
    }

    function totalSupplyUI() external view returns (uint256) {
        return (totalSupply() * _uiMultiplier) / 1e18;
    }

    function scheduleMultiplier(uint256 newMultiplier, uint256 at) external {
        _newUIMultiplier = newMultiplier;
        _effectiveAt = at;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Deliberately absent: oraclePaused(). Calls to it hit the fallback and
    // revert, which is what the testnet tokens do.
}

/// @title MockRetractingStockToken
/// @notice TEST FIXTURE. Answers `oraclePaused()` while being configured, then
///         stops answering it.
///
/// @dev Exists to pin the failure mode that matters: a capability the policy
///      recorded as present must not silently degrade to "unpaused" when the
///      token later refuses the call. The policy is required to revert with
///      `InstrumentStateUnavailable` instead.
contract MockRetractingStockToken is ERC20 {
    bool public answering = true;
    bool private _paused;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function newUIMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function effectiveAt() external pure returns (uint256) {
        return 0;
    }

    function oraclePaused() external view returns (bool) {
        require(answering, "gone");
        return _paused;
    }

    function stopAnswering() external {
        answering = false;
    }

    function setOraclePaused(bool v) external {
        _paused = v;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
