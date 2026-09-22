// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

/// @title Buy-side reference pricing
///
/// @notice Jayo funds a basket by BUYING Stock Tokens with USDG. The engine built
///         in Phase 0 only priced the sell leg, so this is genuinely new behaviour
///         rather than a reuse of the existing path.
///
/// @dev The instrument checks are deliberately unchanged between directions: an
///      issuer pause, a corporate-action window or a stale feed makes a Stock Token
///      untradeable, not un-sellable. These tests assert that symmetry explicitly,
///      because a buy path that skipped them would be the obvious way to get this
///      wrong.
contract BuySidePolicyTest is HookFenceFixture {
    uint256 internal constant USDG_IN = 2550_000000; // 2,550.000000 USDG, 6dp
    uint256 internal constant STOCK_IN = 10e18; // 10 Stock Tokens, 18dp

    // =======================================================================
    // Direction resolution
    // =======================================================================

    function test_ResolvesBothDirectionsToTheSameInstrument() public view {
        assertEq(policy.instrumentOf(address(stock), address(usdg)), address(stock), "sell leg");
        assertEq(policy.instrumentOf(address(usdg), address(stock)), address(stock), "buy leg");
    }

    function test_UnsupportedPairReverts() public {
        address stranger = makeAddr("unlistedToken");
        vm.expectRevert(abi.encodeWithSelector(StockTokenReferencePolicy.TokenNotSupported.selector, stranger));
        policy.instrumentOf(stranger, address(usdg));
    }

    /// @notice Stock-for-stock is not a reviewed route and must not silently price.
    /// @dev It would need two instrument checks and a cross rate. Rejecting is the
    ///      honest behaviour rather than picking one side arbitrarily.
    function test_StockForStockIsRejected() public {
        MockStockToken other = new MockStockToken("Nvidia  Robinhood Token", "NVDA");
        vm.prank(admin);
        policy.setStockToken(address(other), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        vm.expectRevert();
        policy.instrumentOf(address(stock), address(other));
    }

    // =======================================================================
    // Buy-side arithmetic
    // =======================================================================

    /// @notice 2,550 USDG at $1.00 buys 10 Stock Tokens at $255.00.
    /// @dev The exact mirror of the sell-side known value, so the two legs can be
    ///      read against each other by eye.
    function test_KnownValue_BuyTenTokens() public view {
        uint256 got = policy.referenceValue(address(usdg), address(stock), USDG_IN);
        assertEq(got, 10e18, "2550 USDG should reference-value at exactly 10 tokens");
    }

    /// @notice Round trip: value X stock into USDG, value that USDG back into stock.
    /// @dev Must return approximately X. Any direction-confusion bug - swapped feeds,
    ///      inverted decimals, a multiplier applied on one leg only - breaks this
    ///      badly rather than subtly, which is why it is the anchor test.
    function test_RoundTripIsConsistent() public view {
        uint256 usdgOut = policy.referenceValue(address(stock), address(usdg), STOCK_IN);
        uint256 backToStock = policy.referenceValue(address(usdg), address(stock), usdgOut);

        console2.log("10 stock ->", usdgOut, "USDG ->", backToStock);
        // Truncation on each leg can only lose value, never create it.
        assertLe(backToStock, STOCK_IN, "round trip must never manufacture tokens");
        assertApproxEqRel(backToStock, STOCK_IN, 1e12, "round trip should be within 1e-6 relative");
    }

    function testFuzz_RoundTripNeverManufacturesValue(uint256 amountIn, uint64 price) public {
        amountIn = bound(amountIn, 1e15, 100_000e18);
        price = uint64(bound(price, 1e7, 100_000e8)); // $0.10 .. $100,000
        stockFeed.setAnswer(int256(uint256(price)));
        usdgFeed.setAnswer(USDG_USD);

        uint256 usdgOut = policy.referenceValue(address(stock), address(usdg), amountIn);
        vm.assume(usdgOut > 0);
        uint256 back = policy.referenceValue(address(usdg), address(stock), usdgOut);

        assertLe(back, amountIn, "a round trip must not create value out of rounding");
    }

    /// @notice The multiplier must not enter the buy leg either.
    /// @dev The sell-side equivalent lives in MultiplierAndUnits.t.sol. Applying it
    ///      on one leg and not the other would be worse than applying it on both:
    ///      the round-trip test above would then fail loudly, which is the point.
    function test_MultiplierDoesNotAffectTheBuyLeg() public {
        uint256 before = policy.referenceValue(address(usdg), address(stock), USDG_IN);
        stock.setUIMultiplier(stock.uiMultiplier() * 2);
        uint256 afterSplit = policy.referenceValue(address(usdg), address(stock), USDG_IN);
        assertEq(afterSplit, before, "feed already includes the multiplier on both legs");
    }

    /// @notice A weaker USDG buys fewer Stock Tokens.
    function test_UsdgDepegBuysLessStock() public {
        usdgFeed.setAnswer(99_000000); // $0.99
        uint256 got = policy.referenceValue(address(usdg), address(stock), USDG_IN);
        assertLt(got, 10e18, "weaker USDG must buy less");
        // 2550 * 0.99 / 255 = 9.9 tokens
        assertApproxEqRel(got, 9.9e18, 1e12);
    }

    // =======================================================================
    // Floors
    // =======================================================================

    function test_BuyFloorAppliesTheSameShortfallAllowance() public view {
        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);
        uint256 refValue = policy.referenceValue(address(usdg), address(stock), USDG_IN);
        assertEq(floor, Math.mulDiv(refValue, 10_000 - MAX_SHORTFALL_BPS, 10_000), "same bps as the sell leg");
    }

    function test_BuyFloorHonoursAUserMinimum() public view {
        uint256 high = 9.999e18;
        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(stock), USDG_IN, high);
        assertEq(floor, high, "user minimum wins when it is stricter");
    }

    // =======================================================================
    // Instrument checks apply identically on the buy leg
    // =======================================================================

    function test_BuyRejectsStaleFeed() public {
        vm.warp(block.timestamp + FEED_HEARTBEAT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockTokenReferencePolicy.FeedStale.selector,
                address(stockFeed),
                block.timestamp - FEED_HEARTBEAT - 1,
                block.timestamp,
                FEED_HEARTBEAT
            )
        );
        policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);
    }

    function test_BuyRejectsPausedOracle() public {
        stock.setOraclePaused(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockTokenReferencePolicy.OraclePausedForCorporateAction.selector, address(stock)
            )
        );
        policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);
    }

    function test_BuyRejectsPendingCorporateAction() public {
        stock.scheduleMultiplier(stock.uiMultiplier() * 2, block.timestamp + 10 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockTokenReferencePolicy.CorporateActionPending.selector,
                address(stock),
                stock.effectiveAt(),
                stock.newUIMultiplier()
            )
        );
        policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);
    }

    function test_BuyRejectsNonPositiveFeed() public {
        stockFeed.setAnswer(0);
        vm.expectRevert(
            abi.encodeWithSelector(StockTokenReferencePolicy.FeedAnswerNotPositive.selector, address(stockFeed), int256(0))
        );
        policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);
    }

    function test_BuyRejectsZeroAmount() public {
        vm.expectRevert(StockTokenReferencePolicy.ZeroAmount.selector);
        policy.requiredMinOut(address(usdg), address(stock), 0, 0);
    }

    /// @notice Evidence is recorded with the same orientation on both legs.
    /// @dev `basePrice` is always the Stock Token and `quotePrice` always the
    ///      settlement asset, so a receipt reads identically for a buy and a sell.
    function test_EvidenceOrientationIsStableAcrossDirections() public view {
        (, StockTokenReferencePolicy.ReferenceEvidence memory sellEv) =
            policy.requiredMinOut(address(stock), address(usdg), STOCK_IN, 0);
        (, StockTokenReferencePolicy.ReferenceEvidence memory buyEv) =
            policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);

        assertEq(sellEv.basePrice, buyEv.basePrice, "base is the Stock Token feed on both legs");
        assertEq(sellEv.quotePrice, buyEv.quotePrice, "quote is the settlement feed on both legs");
        assertEq(sellEv.uiMultiplier, buyEv.uiMultiplier, "same instrument, same multiplier");
    }
}
