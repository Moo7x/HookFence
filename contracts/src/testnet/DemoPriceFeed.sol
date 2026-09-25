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
///
///      VERSION 2 adds two bounds, so the updater key can run unattended on a
///      schedule (a Cloudflare Worker) without that key being able to walk the
///      price anywhere it likes:
///
///        - `minUpdateInterval`: at most one update per interval. Without it, a
///          stolen updater key could apply the 10% step once per block;
///        - `maxDailyMoveBps`: no update may move the answer further than this from
///          the answer that stood at the start of the current 24-hour window.
///
///      With a 15-minute interval, a 10% step and a 25% daily band, the most a
///      stolen updater key can do is move a reference 25% in a day, one visible
///      event at a time, until the owner replaces the updater. The owner's
///      `forceAnswer` is exempt from all three bounds and resets the window.
contract DemoPriceFeed is Ownable2Step, IAggregatorV3 {
    error NotUpdater(address caller);
    error AnswerNotPositive(int256 answer);
    error StepTooLarge(int256 previous, int256 next, uint16 maxStepBps);
    error TooSoon(uint256 nextAllowedAt);
    error OutsideDailyBand(int256 anchor, int256 next, uint16 maxDailyMoveBps);

    event UpdaterSet(address indexed updater);
    /// @dev Same signature as Chainlink's, so existing tooling reads it.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event AnswerForced(int256 previous, int256 current, uint256 indexed roundId);

    uint8 public immutable decimals;
    uint16 public immutable maxStepBps; // 0 = unbounded
    /// @notice Seconds that must pass between two `setAnswer` calls. 0 = none.
    uint32 public immutable minUpdateInterval;
    /// @notice Largest move from the start-of-window answer within 24 hours. 0 = unbounded.
    uint16 public immutable maxDailyMoveBps;
    string public description;
    uint256 public constant version = 2;
    uint256 public constant BAND_WINDOW = 1 days;

    address public updater;

    uint80 private _round;
    int256 private _answer;
    uint256 private _updatedAt;

    /// @notice The answer at the start of the current band window, and when it began.
    int256 public bandAnchor;
    uint256 public bandStartedAt;

    constructor(
        uint8 decimals_,
        int256 initialAnswer,
        string memory description_,
        address owner_,
        uint16 maxStepBps_,
        uint32 minUpdateInterval_,
        uint16 maxDailyMoveBps_
    ) Ownable(owner_) {
        if (initialAnswer <= 0) revert AnswerNotPositive(initialAnswer);
        decimals = decimals_;
        description = description_;
        maxStepBps = maxStepBps_;
        minUpdateInterval = minUpdateInterval_;
        maxDailyMoveBps = maxDailyMoveBps_;
        updater = owner_;
        _write(initialAnswer);
        _startBand(initialAnswer);
    }

    // --------------------------------------------------------------- writes

    function setUpdater(address updater_) external onlyOwner {
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setAnswer(int256 answer) external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater(msg.sender);
        if (answer <= 0) revert AnswerNotPositive(answer);
        if (block.timestamp < _updatedAt + minUpdateInterval) revert TooSoon(_updatedAt + minUpdateInterval);
        int256 prev = _answer;
        if (maxStepBps != 0 && _moveBpsExceeds(prev, answer, maxStepBps)) revert StepTooLarge(prev, answer, maxStepBps);
        if (maxDailyMoveBps != 0) {
            // A new window starts from whatever answer stands when the old one ends.
            if (block.timestamp >= bandStartedAt + BAND_WINDOW) _startBand(prev);
            if (_moveBpsExceeds(bandAnchor, answer, maxDailyMoveBps)) {
                revert OutsideDailyBand(bandAnchor, answer, maxDailyMoveBps);
            }
        }
        _write(answer);
    }

    /// @notice Owner-only escape hatch for a real move larger than the step bound.
    function forceAnswer(int256 answer) external onlyOwner {
        if (answer <= 0) revert AnswerNotPositive(answer);
        int256 prev = _answer;
        _write(answer);
        _startBand(answer);
        emit AnswerForced(prev, answer, _round);
    }

    function _startBand(int256 anchor) private {
        bandAnchor = anchor;
        bandStartedAt = block.timestamp;
    }

    function _moveBpsExceeds(int256 from, int256 to, uint16 limitBps) private pure returns (bool) {
        uint256 diff = uint256(to > from ? to - from : from - to);
        return diff * 10_000 > uint256(from) * limitBps;
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
