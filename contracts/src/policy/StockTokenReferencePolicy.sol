// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {IExecutionPolicy} from "../interfaces/IExecutionPolicy.sol";

/// @title StockTokenReferencePolicy
/// @notice Derives an independent, conservative output floor for a Stock Token -> USDG
///         exact-input sale, and fails closed whenever the reference data is not
///         trustworthy.
///
/// @dev Design notes that matter for review:
///
///      1. Identity, not tickers. A token is only supported if an operator has
///         explicitly mapped its address to a feed address. A token whose symbol()
///         returns "AAPL" but which is not the mapped address is rejected. Robinhood
///         states this directly: "a token with a matching name/ticker but a different
///         contract address is not a Robinhood Stock Token."
///
///      2. The multiplier is NOT applied here. Robinhood's Chainlink Stock Token
///         feed already returns share price x uiMultiplier, i.e. the price of one
///         whole token. Multiplying the feed result by uiMultiplier() again
///         double-counts every reinvested dividend and every split. We read the
///         multiplier only to (a) record it as evidence and (b) detect a pending
///         corporate action. See test/unit/MultiplierAndUnits.t.sol.
///
///      3. Fail closed. Every reference defect reverts with a distinct custom
///         error. A reverted settlement moves no tokens, so the error selector in the
///         transaction trace is the evidence, not an event.
///
///      4. Sequencer uptime is optional by necessity. Chainlink's reference data
///         directory publishes no L2 Sequencer Uptime Feed for Robinhood Chain as of
///         2026-09-20, although Robinhood's docs recommend one generically. Rather
///         than hardcode a non-existent address, the check is enabled only when an
///         operator sets one. See docs/THREAT_MODEL.md.
contract StockTokenReferencePolicy is Ownable2Step, IExecutionPolicy {
    // -----------------------------------------------------------------------
    // Errors - these selectors are the failure evidence surfaced by the SDK.
    // -----------------------------------------------------------------------
    error TokenNotSupported(address token);
    error QuoteAssetNotSupported(address token);
    error FeedAnswerNotPositive(address feed, int256 answer);
    error FeedRoundIncomplete(address feed);
    error FeedTimestampInFuture(address feed, uint256 updatedAt, uint256 nowTs);
    error FeedStale(address feed, uint256 updatedAt, uint256 nowTs, uint256 maxStaleness);
    error OraclePausedForCorporateAction(address token);
    error CorporateActionPending(address token, uint256 effectiveAt, uint256 newMultiplier);
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 startedAt, uint256 nowTs, uint256 grace);
    error DecimalsOutOfRange(address subject, uint8 decimals);
    error InvalidShortfall(uint16 bps);
    error InvalidStaleness(uint256 secs);
    error ZeroAddress();
    error ZeroAmount();
    error InstrumentStateUnavailable(address token, bytes4 selector);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event StockTokenConfigured(
        address indexed token, address indexed feed, uint256 maxStaleness, uint16 maxShortfallBps, uint64 policyVersion
    );
    /// @notice Which optional Robinhood Stock Token reads this instrument answers.
    ///         Emitted alongside configuration so the capability set of a live
    ///         instrument is auditable from logs, not only from storage.
    event StockTokenCapabilities(
        address indexed token, bool hasOraclePaused, bool hasCorporateActionData, uint64 policyVersion
    );
    event StockTokenRemoved(address indexed token, uint64 policyVersion);
    event QuoteAssetConfigured(address indexed token, address indexed feed, uint256 maxStaleness, uint64 policyVersion);
    event SequencerFeedConfigured(address indexed feed, uint256 gracePeriod, uint64 policyVersion);
    event CorporateActionBufferConfigured(uint256 buffer, uint64 policyVersion);

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    /// @notice Per-Stock-Token reference configuration. All fields are material:
    ///         changing any of them bumps policyVersion.
    struct StockTokenConfig {
        address feed; // Chainlink <TOKEN>/USD proxy. address(0) == unsupported.
        uint32 maxStaleness; // seconds; derived from the feed heartbeat
        uint16 maxShortfallBps; // permitted total shortfall vs the reference value
        uint8 tokenDecimals; // cached at configuration time from the live token
        // Robinhood's mainnet Stock Tokens answer oraclePaused() and the
        // ERC-8056 corporate-action reads. Tokens on other deployments do not
        // all implement the same surface - the equity tokens on Robinhood Chain
        // testnet, for instance, expose uiMultiplier()/effectiveAt() but revert
        // on oraclePaused(). Probing once at configuration, and recording the
        // answer on-chain, keeps that difference an explicit, auditable
        // property of the instrument instead of a try/catch that would quietly
        // read every failure as "not paused".
        bool hasOraclePaused;
        bool hasCorporateActionData;
    }

    /// @notice Per-settlement-asset (USDG) reference configuration.
    struct QuoteAssetConfig {
        address feed; // Chainlink <ASSET>/USD proxy
        uint32 maxStaleness;
        uint8 tokenDecimals;
    }

    /// @inheritdoc IExecutionPolicy
    bytes32 public immutable policyId;

    /// @inheritdoc IExecutionPolicy
    uint64 public policyVersion;

    mapping(address => StockTokenConfig) private _stockTokens;
    mapping(address => QuoteAssetConfig) private _quoteAssets;

    /// @notice Optional L2 sequencer uptime feed. Zero disables the check.
    address public sequencerUptimeFeed;
    /// @notice Grace period after the sequencer comes back up.
    uint256 public sequencerGracePeriod;

    /// @notice How close to a scheduled multiplier change we refuse to settle.
    /// @dev A pending corporate action means the token's share-per-token ratio is
    ///      about to move. The feed and the token can disagree across that boundary,
    ///      so we decline rather than guess. Zero disables the check.
    uint256 public corporateActionBuffer;

    /// @dev Upper bound on any decimals value we will do fixed-point math with.
    uint8 internal constant MAX_DECIMALS = 27;
    uint16 internal constant BPS = 10_000;

    constructor(bytes32 policyId_, address owner_) Ownable(owner_) {
        policyId = policyId_;
        corporateActionBuffer = 1 hours;
        policyVersion = 1;
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function stockTokenConfig(address token) external view returns (StockTokenConfig memory) {
        return _stockTokens[token];
    }

    function quoteAssetConfig(address token) external view returns (QuoteAssetConfig memory) {
        return _quoteAssets[token];
    }

    function isSupported(address tokenIn, address tokenOut) external view returns (bool) {
        return _stockTokens[tokenIn].feed != address(0) && _quoteAssets[tokenOut].feed != address(0);
    }

    // -----------------------------------------------------------------------
    // Core: floor derivation
    // -----------------------------------------------------------------------

    /// @inheritdoc IExecutionPolicy
    function requiredMinOut(address tokenIn, address tokenOut, uint256 amountIn, uint256 userMinOut)
        public
        view
        returns (uint256 floor, ReferenceEvidence memory evidence)
    {
        if (amountIn == 0) revert ZeroAmount();

        (address stockToken, bool isSell) = _resolveDirection(tokenIn, tokenOut);

        StockTokenConfig memory stockCfg = _stockTokens[stockToken];
        QuoteAssetConfig memory quoteCfg = _quoteAssets[isSell ? tokenOut : tokenIn];

        _checkSequencer();
        _checkInstrumentState(stockToken, stockCfg);

        evidence = _buildEvidence(stockToken, amountIn, isSell, stockCfg, quoteCfg);

        // Permitted total shortfall against the independent reference value.
        // Rounding: mulDiv truncates, so the derived floor is never OVERSTATED.
        // The maximum understatement is 1 unit of tokenOut, which is economically
        // immaterial and avoids rounding-induced false rejections of otherwise-honest
        // fills. This direction is deliberate; see ARCHITECTURE.md.
        uint256 referenceFloor = Math.mulDiv(evidence.referenceOut, BPS - stockCfg.maxShortfallBps, BPS);

        floor = userMinOut > referenceFloor ? userMinOut : referenceFloor;
    }

    /// @notice Which of the two tokens is the Stock Token, and which way we are trading.
    ///
    /// @dev The policy is direction-aware rather than sell-only because Jayo funds a
    ///      basket by BUYING Stock Tokens with USDG, and every instrument check
    ///      (issuer pause, corporate-action window, feed validity) applies identically
    ///      whichever side the Stock Token sits on. Making the caller declare the
    ///      direction would let a caller declare it wrongly; deriving it from the
    ///      reviewed configuration cannot be spoofed.
    ///
    ///      Exactly one side must be a configured Stock Token and the other a
    ///      configured quote asset. A pair that is neither, or both, is rejected.
    /// @return stockToken The Stock Token side.
    /// @return isSell True when selling the Stock Token (stock in, quote out).
    function _resolveDirection(address tokenIn, address tokenOut)
        internal
        view
        returns (address stockToken, bool isSell)
    {
        bool inIsStock = _stockTokens[tokenIn].feed != address(0);
        bool outIsStock = _stockTokens[tokenOut].feed != address(0);

        if (inIsStock && !outIsStock) {
            if (_quoteAssets[tokenOut].feed == address(0)) revert QuoteAssetNotSupported(tokenOut);
            return (tokenIn, true);
        }
        if (outIsStock && !inIsStock) {
            if (_quoteAssets[tokenIn].feed == address(0)) revert QuoteAssetNotSupported(tokenIn);
            return (tokenOut, false);
        }
        // Neither side configured, or both are Stock Tokens (stock-for-stock is not a
        // reviewed route: it would need two instrument checks and a cross rate).
        revert TokenNotSupported(inIsStock ? tokenOut : tokenIn);
    }

    /// @notice The Stock Token involved in a pair, for callers that must re-check
    ///         instrument state after an external call.
    /// @dev `ExecutionGateway` uses this instead of assuming the Stock Token is the
    ///      input, which is only true on the sell side.
    /// @inheritdoc IExecutionPolicy
    function instrumentAnswersPause(address stockToken) external view returns (bool) {
        return _stockTokens[stockToken].hasOraclePaused;
    }

    function instrumentOf(address tokenIn, address tokenOut) external view returns (address stockToken) {
        (stockToken,) = _resolveDirection(tokenIn, tokenOut);
    }

    /// @dev Reads both feeds and assembles the receipt evidence.
    /// @dev Written field-by-field into the memory struct rather than through a
    ///      pile of stack locals; the latter overflows the stack in this function.
    function _buildEvidence(
        address stockToken,
        uint256 amountIn,
        bool isSell,
        StockTokenConfig memory stockCfg,
        QuoteAssetConfig memory quoteCfg
    ) internal view returns (ReferenceEvidence memory e) {
        uint8 stockFeedDec;
        uint8 quoteFeedDec;

        // `base` is always the Stock Token feed and `quote` always the settlement
        // asset feed, regardless of trade direction, so a receipt reads the same way
        // for a buy and a sell.
        (e.baseRoundId, e.basePrice, e.baseUpdatedAt, stockFeedDec) = _readFeed(stockCfg.feed, stockCfg.maxStaleness);
        (e.quoteRoundId, e.quotePrice, e.quoteUpdatedAt, quoteFeedDec) = _readFeed(quoteCfg.feed, quoteCfg.maxStaleness);

        e.referenceOut = _referenceOut(
            amountIn,
            uint256(e.basePrice),
            uint256(e.quotePrice),
            isSell,
            stockCfg.tokenDecimals,
            quoteCfg.tokenDecimals,
            stockFeedDec,
            quoteFeedDec
        );

        // Recorded for audit only. Deliberately NOT applied to referenceOut:
        // the feed already includes it.
        e.uiMultiplier = IStockToken(stockToken).uiMultiplier();
        e.policyVersion = policyVersion;
    }

    /// @notice The unadjusted reference value of amountIn, denominated in tokenOut.
    /// @dev Exposed so the SDK and demo can show "reference value" and "enforced floor"
    ///      as separate numbers instead of one opaque threshold.
    function referenceValue(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        (address stockToken, bool isSell) = _resolveDirection(tokenIn, tokenOut);
        StockTokenConfig memory stockCfg = _stockTokens[stockToken];
        QuoteAssetConfig memory quoteCfg = _quoteAssets[isSell ? tokenOut : tokenIn];

        (, int256 basePrice,, uint8 stockFeedDec) = _readFeed(stockCfg.feed, stockCfg.maxStaleness);
        (, int256 quotePrice,, uint8 quoteFeedDec) = _readFeed(quoteCfg.feed, quoteCfg.maxStaleness);

        return _referenceOut(
            amountIn,
            uint256(basePrice),
            uint256(quotePrice),
            isSell,
            stockCfg.tokenDecimals,
            quoteCfg.tokenDecimals,
            stockFeedDec,
            quoteFeedDec
        );
    }

    // -----------------------------------------------------------------------
    // Internal checks
    // -----------------------------------------------------------------------

    /// @dev Reads a Chainlink push feed and applies validity rules.
    ///
    ///      We deliberately do NOT check answeredInRound >= roundId. Chainlink has
    ///      deprecated that field; on current aggregators it carries no information
    ///      and treating it as a liveness signal is a known false-positive source.
    ///      Freshness is enforced by updatedAt against the feed heartbeat instead.
    function _readFeed(address feed, uint32 maxStaleness)
        internal
        view
        returns (uint80 roundId, int256 answer, uint256 updatedAt, uint8 feedDecimals)
    {
        (roundId, answer,, updatedAt,) = IAggregatorV3(feed).latestRoundData();

        if (answer <= 0) revert FeedAnswerNotPositive(feed, answer);
        if (updatedAt == 0) revert FeedRoundIncomplete(feed);
        if (updatedAt > block.timestamp) revert FeedTimestampInFuture(feed, updatedAt, block.timestamp);
        unchecked {
            // Safe: updatedAt <= block.timestamp was just enforced.
            if (block.timestamp - updatedAt > maxStaleness) {
                revert FeedStale(feed, updatedAt, block.timestamp, maxStaleness);
            }
        }

        feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals > MAX_DECIMALS) revert DecimalsOutOfRange(feed, feedDecimals);
    }

    /// @dev Stock-Token-specific instrument state. This is the part a generic
    ///      oracle-floor router does not have: an ordinary router enforcing the same
    ///      numeric floor still settles while the issuer has paused the oracle or
    ///      while a multiplier change is pending.
    /// @dev IMPORTANT - do not reintroduce a `pending == current` early return here.
    ///
    ///      An earlier version returned early when `newUIMultiplier() ==
    ///      uiMultiplier()`, reasoning that equal values mean nothing is scheduled.
    ///      That is wrong precisely at the moment it matters most. The ERC-8056
    ///      reference implementation advances `uiMultiplier()` at `effectiveAt`, so
    ///      the two values become equal exactly as the transition fires - and the
    ///      documented post-effective buffer was skipped from `effectiveAt` onward.
    ///      An independent review reproduced a rejection one second before the
    ///      transition and an acceptance one second after it, with the pre-split
    ///      feed still inside its heartbeat.
    ///
    ///      The window is therefore keyed on `effectiveAt` alone, regardless of
    ///      whether the change has already been applied. See
    ///      `test/unit/ReviewRegressions.t.sol`.
    ///
    ///      Both halves are conditional on what the instrument actually
    ///      implements, decided once at configuration time. A capability the
    ///      token claimed then and refuses now is a fault, not a pass: the read
    ///      reverts with InstrumentStateUnavailable rather than defaulting to
    ///      "nothing is wrong".
    function _checkInstrumentState(address token, StockTokenConfig memory cfg) internal view {
        if (cfg.hasOraclePaused) {
            (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IStockToken.oraclePaused, ()));
            if (!ok || ret.length != 32) {
                revert InstrumentStateUnavailable(token, IStockToken.oraclePaused.selector);
            }
            if (abi.decode(ret, (bool))) revert OraclePausedForCorporateAction(token);
        }

        uint256 buffer = corporateActionBuffer;
        if (buffer == 0 || !cfg.hasCorporateActionData) return;

        uint256 effectiveAt = IStockToken(token).effectiveAt();
        uint256 pending = IStockToken(token).newUIMultiplier();

        if (effectiveAt != 0) {
            // Decline across the whole transition window [effectiveAt - buffer,
            // effectiveAt + buffer]. The upper half is the part that matters: the
            // token has re-based but the feed may still be publishing pre-transition
            // prices that are inside their heartbeat and therefore look valid.
            uint256 lower = effectiveAt > buffer ? effectiveAt - buffer : 0;
            if (block.timestamp >= lower && block.timestamp <= effectiveAt + buffer) {
                revert CorporateActionPending(token, effectiveAt, pending);
            }
            return;
        }

        // A scheduled multiplier with no effective timestamp is a state we do not
        // understand. Fail closed rather than guess.
        if (pending != IStockToken(token).uiMultiplier()) {
            revert CorporateActionPending(token, 0, pending);
        }
    }

    function _checkSequencer() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return; // no published feed on this chain; see NatSpec

        (, int256 status, uint256 startedAt,,) = IAggregatorV3(feed).latestRoundData();
        if (status != 0) revert SequencerDown(); // 0 == up
        uint256 grace = sequencerGracePeriod;
        if (block.timestamp - startedAt <= grace) {
            revert SequencerGracePeriodNotOver(startedAt, block.timestamp, grace);
        }
    }

    /// @dev Full-precision decimal normalisation, both directions.
    ///
    ///      Both legs are the same two steps: value the input in USD, then convert
    ///      that USD into the output token. Only which feed prices which side swaps.
    ///
    ///      SELL (Stock Token in, quote asset out):
    ///        usd = amountIn * stockPrice / 10^stockDec            [10^stockFeedDec]
    ///        out = usd * 10^quoteDec * 10^quoteFeedDec
    ///              / (10^stockFeedDec * quotePrice)
    ///
    ///      BUY (quote asset in, Stock Token out):
    ///        usd = amountIn * quotePrice / 10^quoteDec            [10^quoteFeedDec]
    ///        out = usd * 10^stockDec * 10^stockFeedDec
    ///              / (10^quoteFeedDec * stockPrice)
    ///
    ///      Evaluated as two 512-bit mulDivs so no intermediate has to fit in 256
    ///      bits. Both truncate, so the result is never overstated - which is the
    ///      conservative direction for a MINIMUM output on either leg.
    ///
    ///      The multiplier is absent from both. The Stock Token feed already prices
    ///      one whole token, so it is as wrong to apply it on the way in as on the
    ///      way out. See test/unit/MultiplierAndUnits.t.sol.
    function _referenceOut(
        uint256 amountIn,
        uint256 stockPrice,
        uint256 quotePrice,
        bool isSell,
        uint8 stockDec,
        uint8 quoteDec,
        uint8 stockFeedDec,
        uint8 quoteFeedDec
    ) internal pure returns (uint256) {
        if (isSell) {
            uint256 usdValue = Math.mulDiv(amountIn, stockPrice, 10 ** stockDec);
            return Math.mulDiv(usdValue, 10 ** quoteDec * 10 ** quoteFeedDec, 10 ** stockFeedDec * quotePrice);
        }
        uint256 usdIn = Math.mulDiv(amountIn, quotePrice, 10 ** quoteDec);
        return Math.mulDiv(usdIn, 10 ** stockDec * 10 ** stockFeedDec, 10 ** quoteFeedDec * stockPrice);
    }

    // -----------------------------------------------------------------------
    // Administration - every material change bumps policyVersion
    // -----------------------------------------------------------------------

    function setStockToken(address token, address feed, uint32 maxStaleness, uint16 maxShortfallBps)
        external
        onlyOwner
    {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxShortfallBps >= BPS) revert InvalidShortfall(maxShortfallBps);
        if (maxStaleness == 0) revert InvalidStaleness(maxStaleness);

        uint8 dec = IStockToken(token).decimals();
        if (dec > MAX_DECIMALS) revert DecimalsOutOfRange(token, dec);

        bool hasPaused = _answers(token, IStockToken.oraclePaused.selector);
        bool hasAction = _answers(token, IStockToken.effectiveAt.selector)
            && _answers(token, IStockToken.newUIMultiplier.selector)
            && _answers(token, IStockToken.uiMultiplier.selector);

        _stockTokens[token] = StockTokenConfig({
            feed: feed,
            maxStaleness: maxStaleness,
            maxShortfallBps: maxShortfallBps,
            tokenDecimals: dec,
            hasOraclePaused: hasPaused,
            hasCorporateActionData: hasAction
        });

        uint64 v = ++policyVersion;
        emit StockTokenConfigured(token, feed, maxStaleness, maxShortfallBps, v);
        emit StockTokenCapabilities(token, hasPaused, hasAction, v);
    }

    /// @dev True when `token` answers a zero-argument view returning one word.
    ///      Used only at configuration time; the result is stored, so a quote
    ///      never pays for a probe.
    function _answers(address token, bytes4 selector) private view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(selector));
        return ok && ret.length == 32;
    }

    function removeStockToken(address token) external onlyOwner {
        delete _stockTokens[token];
        uint64 v = ++policyVersion;
        emit StockTokenRemoved(token, v);
    }

    function setQuoteAsset(address token, address feed, uint32 maxStaleness, uint8 tokenDecimals) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxStaleness == 0) revert InvalidStaleness(maxStaleness);
        if (tokenDecimals > MAX_DECIMALS) revert DecimalsOutOfRange(token, tokenDecimals);

        _quoteAssets[token] = QuoteAssetConfig({feed: feed, maxStaleness: maxStaleness, tokenDecimals: tokenDecimals});

        uint64 v = ++policyVersion;
        emit QuoteAssetConfigured(token, feed, maxStaleness, v);
    }

    function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external onlyOwner {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        uint64 v = ++policyVersion;
        emit SequencerFeedConfigured(feed, gracePeriod, v);
    }

    function setCorporateActionBuffer(uint256 buffer) external onlyOwner {
        corporateActionBuffer = buffer;
        uint64 v = ++policyVersion;
        emit CorporateActionBufferConfigured(buffer, v);
    }
}
