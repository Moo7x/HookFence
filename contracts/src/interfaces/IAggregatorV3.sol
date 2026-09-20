// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAggregatorV3
/// @notice Standard Chainlink push-feed interface, as documented for Robinhood Chain.
/// @dev Robinhood Chain Stock Token feeds and the USDG/USD feed both expose this and
///      both report 8 decimals with an 86400s heartbeat (verified 2026-09-20 against
///      the Chainlink reference-data-directory for robinhood-mainnet).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
