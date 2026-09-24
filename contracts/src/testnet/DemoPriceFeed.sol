// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title DemoPriceFeed
/// @notice A Chainlink-shaped price feed that only its owner and one named
///         updater can move. Stands in for a real feed on networks where none is
///         published — Robinhood Chain testnet, and the local demo chain.
///
/// @dev THIS IS NOT AN ORACLE. It reports whatever its updater last wrote. What
///      that is worth depends entirely on where the updater gets the number; on
///      testnet that is the same pool Jayo trades in (see PoolPriceReader), which
///      means this feed cannot tell anyone whether that pool is fairly priced.
///
///      The deployment it replaces used `MockAggregatorV3`, whose `setAnswer` was
///      open to every address. On a public network that let anyone rewrite the
///      reference price a user's floor is computed from, one block before their
///      trade. Here:
///
///        - `setAnswer` is restricted to the updater (or the owner);
///        - an answer must be positive, as the policy requires anyway;
///        - each update may move the price by at most `maxStepBps` from the last
///          one. A pool pushed far off its price between refreshes therefore
///          cannot be copied into the reference in one step; the refresh fails,
///          the feed goes stale after its heartbeat, and buying stops. Failing
///          closed is the intended outcome, not a malfunction;
///        - only the owner can bypass that bound, with `forceAnswer`, and every
///          bypass is its own event.
contract DemoPriceFeed is Ownable2Step, IAggregatorV3 {
    error NotUpdater(address caller);
    error AnswerNotPositive(int256 answer);
    error StepTooLarge(int256 previous, int256 next, uint16 maxStepBps);

    event UpdaterSet(address indexed updater);
    /// @dev Same signature as Chainlink's, so existing tooling reads it.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event AnswerForced(int256 previous, int256 current, uint256 indexed roundId);

    uint8 public immutable decimals;
    uint16 public immutable maxStepBps; // 0 = unbounded
    string public description;
    uint256 public constant version = 1;

    address public updater;

    uint80 private _round;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 initialAnswer, string memory description_, address owner_, uint16 maxStepBps_)
        Ownable(owner_)
    {
        if (initialAnswer <= 0) revert AnswerNotPositive(initialAnswer);
        decimals = decimals_;
        description = description_;
        maxStepBps = maxStepBps_;
        updater = owner_;
        _write(initialAnswer);
    }

    // --------------------------------------------------------------- writes

    function setUpdater(address updater_) external onlyOwner {
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setAnswer(int256 answer) external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater(msg.sender);
        if (answer <= 0) revert AnswerNotPositive(answer);
        if (maxStepBps != 0) {
            int256 prev = _answer;
            uint256 diff = uint256(answer > prev ? answer - prev : prev - answer);
            if (diff * 10_000 > uint256(prev) * maxStepBps) revert StepTooLarge(prev, answer, maxStepBps);
        }
        _write(answer);
    }

    /// @notice Owner-only escape hatch for a real move larger than the step bound.
    function forceAnswer(int256 answer) external onlyOwner {
        if (answer <= 0) revert AnswerNotPositive(answer);
        int256 prev = _answer;
        _write(answer);
        emit AnswerForced(prev, answer, _round);
    }

    function _write(int256 answer) private {
        unchecked { ++_round; }
        _answer = answer;
        _updatedAt = block.timestamp;
        emit AnswerUpdated(answer, _round, block.timestamp);
    }

    // ---------------------------------------------------------------- reads

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _updatedAt;
    }
}
