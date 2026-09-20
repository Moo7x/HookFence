// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockAggregatorV3
/// @notice TEST FIXTURE Chainlink push feed with fully controllable round data.
/// @dev Lets tests drive every failure mode the policy must reject: non-positive
///      answers, incomplete rounds, future timestamps and staleness.
contract MockAggregatorV3 {
    uint8 public decimals;
    string public description;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    constructor(uint8 decimals_, int256 initialAnswer, string memory description_) {
        decimals = decimals_;
        description = description_;
        _roundId = 1;
        _answer = initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    /// @notice Publish a fresh round at the current block timestamp.
    function setAnswer(int256 answer) external {
        _roundId += 1;
        _answeredInRound = _roundId;
        _answer = answer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    /// @notice Publish a round with an arbitrary updatedAt (stale or future-dated).
    function setAnswerAt(int256 answer, uint256 updatedAt) external {
        _roundId += 1;
        _answeredInRound = _roundId;
        _answer = answer;
        _startedAt = updatedAt;
        _updatedAt = updatedAt;
    }

    /// @notice Simulate a round that never completed (updatedAt == 0).
    function setIncompleteRound() external {
        _roundId += 1;
        _answeredInRound = _roundId;
        _updatedAt = 0;
        _startedAt = 0;
    }
}
