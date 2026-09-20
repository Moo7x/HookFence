// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockSequencerUptimeFeed
/// @notice TEST FIXTURE for Chainlink's L2 Sequencer Uptime Feed shape.
/// @dev Chainlink publishes no uptime feed for Robinhood Chain as of 2026-09-20,
///      so this exists to test the code path, not to stand in for a live feed.
///      answer == 0 means the sequencer is up; 1 means down.
contract MockSequencerUptimeFeed {
    uint8 public constant decimals = 0;
    int256 private _status;
    uint256 private _startedAt;

    constructor(int256 status, uint256 startedAt) {
        _status = status;
        _startedAt = startedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _status, _startedAt, _startedAt, 1);
    }

    function setStatus(int256 status, uint256 startedAt) external {
        _status = status;
        _startedAt = startedAt;
    }
}
