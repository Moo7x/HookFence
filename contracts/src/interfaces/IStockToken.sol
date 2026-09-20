// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStockToken
/// @notice The subset of the Robinhood Stock Token surface that HookFence relies on.
/// @dev Stock Tokens are standard 18-decimal ERC-20s that additionally implement
///      ERC-8056 (Scaled UI Amount Extension) plus an advisory `oraclePaused` flag.
///      Verified live against AAPL (0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9) on
///      Robinhood Chain mainnet (chainId 4663) on 2026-09-20; see docs/ARCHITECTURE.md.
///
///      Source: https://docs.robinhood.com/chain/building-with-stock-tokens
///              https://docs.robinhood.com/chain/oracles-and-price-feeds
interface IStockToken {
    /// @notice Current corporate-action multiplier, 18 decimals (1e18 == 1.0).
    /// @dev underlying shares = rawAmount * uiMultiplier() / 1e18.
    ///      The Chainlink feed price ALREADY includes this multiplier. Applying it
    ///      again to a feed-derived value double-counts. See StockTokenReferencePolicy.
    function uiMultiplier() external view returns (uint256);

    /// @notice The multiplier scheduled to take effect at `effectiveAt()`.
    /// @dev Before any update is scheduled this tracks the current multiplier.
    function newUIMultiplier() external view returns (uint256);

    /// @notice Timestamp at which `newUIMultiplier()` becomes the active multiplier.
    function effectiveAt() external view returns (uint256);

    /// @notice Advisory flag set while a corporate action is being processed.
    /// @dev Robinhood documents this as advisory and NOT enforced on-chain: a paused
    ///      oracle may still return a value. Staleness remains the primary guard.
    function oraclePaused() external view returns (bool);

    // --- ERC-20 subset ------------------------------------------------------
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}
