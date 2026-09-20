// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

/// @title Corporate-action multiplier handling and decimal normalisation
///
/// @notice Robinhood documents that the Chainlink Stock Token feed price *already
///         includes* the ERC-8056 `uiMultiplier`: "latestRoundData() returns this
///         directly, so you don't apply the multiplier yourself."
///
///         Applying it again is the single most plausible integration mistake with
///         this asset class, it is silent, and it scales with every dividend and
///         split the instrument has ever had. These tests pin the correct behaviour
///         and quantify what the mistake would cost.
contract MultiplierAndUnitsTest is HookFenceFixture {
    uint256 internal constant TRADE = 10e18;

    // =======================================================================
    // The multiplier must NOT be applied to a feed-derived value
    // =======================================================================

    /// @notice Changing the multiplier alone must not move the reference value.
    /// @dev The feed price is the price of one whole token and already embeds the
    ///      multiplier. If the policy multiplied by it, this assertion would fail by
    ///      exactly the multiplier ratio.
    function test_ReferenceValueIsIndependentOfTheMultiplier() public {
        uint256 baseline = policy.referenceValue(address(stock), address(usdg), TRADE);

        // A 2-for-1 split completes. The feed is unchanged in this test precisely to
        // isolate the multiplier's effect on our arithmetic.
        stock.setUIMultiplier(stock.uiMultiplier() * 2);
        uint256 afterSplit = policy.referenceValue(address(stock), address(usdg), TRADE);

        assertEq(afterSplit, baseline, "multiplier must not enter feed-derived maths");
    }

    /// @notice Quantifies the bug we are avoiding.
    /// @dev A naive implementation computes `value * uiMultiplier / 1e18`. With the
    ///      live AAPL multiplier that is only +0.057%, which is exactly why the
    ///      mistake survives code review - it looks like rounding. After a 2-for-1
    ///      split it is +100%, and the floor becomes unreachable, bricking the pair.
    function test_NaiveDoubleApplicationOverstatesTheFloor() public {
        uint256 correct = policy.referenceValue(address(stock), address(usdg), TRADE);

        uint256 liveMultiplier = stock.uiMultiplier(); // 1.000566... from mainnet
        uint256 naiveLive = Math.mulDiv(correct, liveMultiplier, 1e18);
        assertGt(naiveLive, correct, "even the live multiplier inflates the floor");
        console2.log("correct floor input      :", correct);
        console2.log("naive, live multiplier   :", naiveLive);
        console2.log("overstatement (6dp USDG) :", naiveLive - correct);

        stock.setUIMultiplier(2e18);
        uint256 naiveSplit = Math.mulDiv(correct, 2e18, 1e18);
        assertEq(naiveSplit, correct * 2, "after a split the error is 100%");

        // And the policy is unmoved by any of it.
        assertEq(policy.referenceValue(address(stock), address(usdg), TRADE), correct);
    }

    /// @notice The multiplier is still recorded as evidence, for audit.
    /// @dev Not applying it is not the same as ignoring it.
    function test_MultiplierIsRecordedInEvidenceEvenThoughItIsNotApplied() public view {
        (, StockTokenReferencePolicy.ReferenceEvidence memory ev) =
            policy.requiredMinOut(address(stock), address(usdg), TRADE, 0);
        assertEq(ev.uiMultiplier, stock.uiMultiplier(), "recorded for the receipt");
    }

    // =======================================================================
    // Decimal normalisation: 18-dec token, 8-dec feed, 6-dec USDG
    // =======================================================================

    function test_KnownValue_TenTokensAt255Dollars() public view {
        // 10 tokens x $255.00, USDG at $1.00 -> 2550.000000 USDG (6 dp).
        assertEq(policy.referenceValue(address(stock), address(usdg), 10e18), 2_550_000000);
    }

    function test_UsdgDepegRaisesTheTokenAmountOwed() public {
        // If USDG is worth $0.99, the same value requires MORE USDG.
        usdgFeed.setAnswer(99_000000); // $0.99, 8 dp
        uint256 out = policy.referenceValue(address(stock), address(usdg), 10e18);
        assertGt(out, 2_550_000000, "a weaker USDG means more units owed");
        // 2550 / 0.99 = 2575.757575...
        assertEq(out, 2_575_757575, "truncated, never rounded up");
    }

    /// @notice Rounding direction is deliberate and must never overstate the floor.
    /// @dev `Math.mulDiv` truncates, so the derived floor is at most 1 unit of USDG
    ///      (1e-6) BELOW the exact value. Understating by a millionth of a dollar is
    ///      immaterial; overstating would reject honest fills.
    function testFuzz_ReferenceValueNeverOverstates(uint256 amountIn, uint64 price) public {
        amountIn = bound(amountIn, 1e12, 1_000_000e18);
        price = uint64(bound(price, 1e6, 1_000_000e8)); // $0.01 .. $1,000,000

        stockFeed.setAnswer(int256(uint256(price)));
        usdgFeed.setAnswer(USDG_USD);

        uint256 got = policy.referenceValue(address(stock), address(usdg), amountIn);

        // Exact value in 6-dp USDG, computed independently at full precision.
        uint256 exact = Math.mulDiv(amountIn, uint256(price), 1e18); // 8-dp USD
        exact = Math.mulDiv(exact, 1e6 * 1e8, 1e8 * uint256(uint256(USDG_USD)));

        assertLe(got, exact, "must never exceed the exact value");
        assertGe(got + 2, exact, "and must be within rounding distance of it");
    }

    /// @notice The floor is always the greater of the user's minimum and the
    ///         reference-derived floor, for any inputs.
    function testFuzz_FloorIsMaxOfUserMinAndReference(uint256 amountIn, uint256 userMin) public view {
        amountIn = bound(amountIn, 1e12, 100_000e18);
        userMin = bound(userMin, 0, 1_000_000_000e6);

        (uint256 floor,) = policy.requiredMinOut(address(stock), address(usdg), amountIn, userMin);
        uint256 refValue = policy.referenceValue(address(stock), address(usdg), amountIn);
        uint256 refFloor = Math.mulDiv(refValue, 10_000 - MAX_SHORTFALL_BPS, 10_000);

        assertEq(floor, userMin > refFloor ? userMin : refFloor, "floor == max(userMin, referenceFloor)");
        assertGe(floor, userMin, "never below what the user asked for");
    }

    /// @notice Decimals are read from the contracts, never hardcoded.
    /// @dev A 2-decimal settlement asset with an 18-decimal feed must still work.
    function test_UnusualDecimalCombinationsStillNormalise() public {
        MockAggregatorV3 oddFeed = new MockAggregatorV3(18, 1e18, "ODD / USD"); // $1.00 at 18 dp

        vm.prank(admin);
        policy.setQuoteAsset(address(usdg), address(oddFeed), FEED_HEARTBEAT, 2); // pretend 2 dp

        // 10 tokens x $255 -> 2550.00 in a 2-decimal asset -> 255000.
        assertEq(policy.referenceValue(address(stock), address(usdg), 10e18), 255_000);
    }
}
