// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {MockConfigurableToken} from "../../src/mocks/MockConfigurableToken.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";

/// @title Pricing specification — independently derived expected values
///
/// @notice Every expected value here was derived from the economics BY HAND in
///         `docs/MATHS_SPEC.md` §4, not read off the implementation.
///
/// @dev Why this file exists separately from the round-trip tests.
///
///      A round trip (value X into the other asset, value it back) cannot catch a
///      mistake made *symmetrically* in both directions — a wrong exponent used
///      consistently on both legs cancels out and the round trip still closes.
///      Only an externally-derived absolute value catches that.
///
///      So each case below states the economic sanity check alongside the raw
///      number: "$2,550 / $255 = 10 tokens". If the implementation and the
///      hand-derivation disagree, one of them is wrong and the test says which
///      number was expected.
///
///      This fixture deliberately does NOT use `HookFenceFixture`: it needs decimal
///      combinations that do not occur on Robinhood Chain, and the main fixture is
///      pinned to the real surface on purpose.
contract PricingSpecTest is Test {
    StockTokenReferencePolicy internal policy;
    address internal admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_790_000_000);
        policy = new StockTokenReferencePolicy(keccak256("PricingSpec"), admin);
    }

    // =======================================================================
    // MATHS_SPEC §4.1 — standard configuration
    // stockDec 18, quoteDec 6, both feeds 8. Stock $255.00, quote $1.00.
    // =======================================================================

    function test_Spec_4_1_Standard() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(18, 6, 8, 8, 255_00000000, 1_00000000);

        // BUY 2,550.000000 USDG. Sanity: $2,550 / $255 = 10 tokens.
        uint256 bought = policy.referenceValue(address(quote), address(stock), 2550_000000);
        assertEq(bought, 10e18, "2550 USDG must buy exactly 10.000000000000000000 tokens");

        // SELL 10 Stock Tokens. Sanity: 10 x $255 / $1 = 2,550 USDG.
        uint256 sold = policy.referenceValue(address(stock), address(quote), 10e18);
        assertEq(sold, 2550_000000, "10 tokens must sell for exactly 2550.000000 USDG");
    }

    // =======================================================================
    // MATHS_SPEC §4.2 — unusual decimals, proves nothing is hardcoded
    // stockDec 8, quoteDec 18, stockFeedDec 18, quoteFeedDec 6.
    // Stock $50.00, quote $2.00.
    // =======================================================================

    function test_Spec_4_2_UnusualDecimals_Buy() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(8, 18, 18, 6, 50e18, 2e6);

        // BUY 100 quote tokens (1e20 raw at 18dp).
        // Sanity: 100 x $2.00 = $200. $200 / $50 = 4 tokens = 4e8 raw at 8dp.
        uint256 bought = policy.referenceValue(address(quote), address(stock), 1e20);
        assertEq(bought, 4e8, "100 quote tokens at $2 must buy 4.00000000 stock at $50");
    }

    function test_Spec_4_2_UnusualDecimals_Sell() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(8, 18, 18, 6, 50e18, 2e6);

        // SELL 4 Stock Tokens (4e8 raw at 8dp).
        // Sanity: 4 x $50 = $200. $200 / $2.00 = 100 quote tokens = 1e20 raw at 18dp.
        uint256 sold = policy.referenceValue(address(stock), address(quote), 4e8);
        assertEq(sold, 1e20, "4 stock at $50 must sell for 100 quote tokens at $2");
    }

    /// @notice A third decimal combination, to make sure §4.2 was not a lucky pair.
    function test_Spec_ThirdDecimalCombination() public {
        // stockDec 6, quoteDec 18, stockFeedDec 6, quoteFeedDec 18.
        // Stock $10.00 (10e6), quote $0.50 (5e17).
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(6, 18, 6, 18, 10e6, 5e17);

        // BUY with 200 quote tokens (2e20 raw).
        // Sanity: 200 x $0.50 = $100. $100 / $10 = 10 tokens = 10e6 raw at 6dp.
        assertEq(policy.referenceValue(address(quote), address(stock), 2e20), 10e6, "buy leg");

        // SELL 10 stock tokens (10e6 raw).
        // Sanity: 10 x $10 = $100. $100 / $0.50 = 200 quote tokens = 2e20 raw.
        assertEq(policy.referenceValue(address(stock), address(quote), 10e6), 2e20, "sell leg");
    }

    // =======================================================================
    // MATHS_SPEC §4.3 — rounding boundary
    // =======================================================================

    function test_Spec_4_3_SmallestNonZeroBuy() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(18, 6, 8, 8, 255_00000000, 1_00000000);

        // BUY with 1 raw USDG unit (0.000001 USDG).
        //   usd = 1 * 1e8 / 1e6                     = 100
        //   out = 100 * 1e26 / 2.55e18              = 3921568627.45..., truncated
        uint256 got = policy.referenceValue(address(quote), address(stock), 1);
        assertEq(got, 3921568627, "hand-derived: truncated from 3921568627.45...");
    }

    /// @notice Truncation must lose value, never create it, at the boundary.
    function test_Spec_TruncationAlwaysLosesValue() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(18, 6, 8, 8, 333_33333333, 1_00000000);

        // A price chosen so the division does not terminate.
        uint256 out1 = policy.referenceValue(address(quote), address(stock), 1000_000000);
        uint256 out2 = policy.referenceValue(address(quote), address(stock), 2000_000000);

        // Doubling the input can produce at most double the output, never more.
        assertLe(out2, out1 * 2, "truncation must not compound upward");
        // And at least double minus the per-call truncation allowance.
        assertGe(out2 + 4, out1 * 2, "truncation loss must stay within 2 raw units per leg");
    }

    function test_Spec_DustRoundsToZeroRatherThanReverting() public {
        // A very expensive instrument with few decimals: a tiny input buys nothing.
        // stockDec 2, quoteDec 18. Stock $1,000,000, quote $1.00.
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(2, 18, 8, 8, 1_000_000_00000000, 1_00000000);

        // 1 raw quote unit = 1e-18 quote tokens. Nowhere near 0.01 of a stock token.
        uint256 got = policy.referenceValue(address(quote), address(stock), 1);
        assertEq(got, 0, "dust must floor to zero, not revert");
        // The floor derived from it is also zero, so a caller's own minimum governs.
        (uint256 floor,) = policy.requiredMinOut(address(quote), address(stock), 1, 0);
        assertEq(floor, 0);
    }

    // =======================================================================
    // MATHS_SPEC §4.4 — the multiplier is absent from BOTH legs
    // =======================================================================

    function test_Spec_4_4_NonUnitMultiplierDoesNotMoveEitherLeg() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(18, 6, 8, 8, 255_00000000, 1_00000000);

        uint256 buyBefore = policy.referenceValue(address(quote), address(stock), 2550_000000);
        uint256 sellBefore = policy.referenceValue(address(stock), address(quote), 10e18);

        // A non-unit multiplier, as every live Stock Token has after its first
        // dividend. AAPL read 1.000566080061092436 on mainnet 2026-09-20.
        stock.setUIMultiplier(1_500_000_000_000_000_000); // 1.5

        assertEq(
            policy.referenceValue(address(quote), address(stock), 2550_000000),
            buyBefore,
            "multiplier must not enter the BUY leg"
        );
        assertEq(
            policy.referenceValue(address(stock), address(quote), 10e18),
            sellBefore,
            "multiplier must not enter the SELL leg"
        );

        // And the hand-derived absolute values still hold, which is the part a
        // symmetric bug could not survive.
        assertEq(buyBefore, 10e18);
        assertEq(sellBefore, 2550_000000);
    }

    /// @notice Quantifies what the double-count bug would have cost.
    /// @dev At the live AAPL multiplier the error is +0.057% — small enough to read
    ///      as rounding in review. After a 4:1 split (CRWD did one) it is +300%.
    function test_Spec_DoubleCountMagnitude() public {
        (MockConfigurableToken stock, MockConfigurableToken quote) =
            _configure(18, 6, 8, 8, 255_00000000, 1_00000000);

        uint256 correct = policy.referenceValue(address(stock), address(quote), 10e18);

        uint256 liveMultiplier = 1_000_566_080_061_092_436; // mainnet AAPL
        uint256 naiveLive = correct * liveMultiplier / 1e18;
        console2.log("correct                :", correct);
        console2.log("naive w/ live mult     :", naiveLive);
        console2.log("overstatement (6dp)    :", naiveLive - correct);
        assertGt(naiveLive, correct);

        uint256 naiveSplit = correct * 4e18 / 1e18;
        assertEq(naiveSplit, correct * 4, "after a 4:1 split the error is 300%");
    }

    // =======================================================================
    // Helper
    // =======================================================================

    /// @dev Builds a stock/quote pair with arbitrary decimals and prices, and
    ///      registers both with the policy.
    function _configure(
        uint8 stockDec,
        uint8 quoteDec,
        uint8 stockFeedDec,
        uint8 quoteFeedDec,
        int256 stockPrice,
        int256 quotePrice
    ) internal returns (MockConfigurableToken stock, MockConfigurableToken quote) {
        stock = new MockConfigurableToken("Spec Stock", "SPEC", stockDec);
        quote = new MockConfigurableToken("Spec Quote", "SQUOTE", quoteDec);

        MockAggregatorV3 stockFeed = new MockAggregatorV3(stockFeedDec, stockPrice, "SPEC / USD");
        MockAggregatorV3 quoteFeed = new MockAggregatorV3(quoteFeedDec, quotePrice, "SQUOTE / USD");

        vm.startPrank(admin);
        policy.setStockToken(address(stock), address(stockFeed), 86_400, 50);
        policy.setQuoteAsset(address(quote), address(quoteFeed), 86_400, quoteDec);
        vm.stopPrank();
    }
}
