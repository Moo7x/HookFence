// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {MisreportingAdapter} from "../../src/mocks/MisreportingAdapter.sol";
import {BaselineOracleRouter} from "../../src/mocks/BaselineOracleRouter.sol";

/// @title Phase 0 - where HookFence actually differs from baseline B
///
/// @notice `BaselineComparison.t.sol` establishes the uncomfortable half of the
///         result: given the same oracle floor, an ordinary router rejects the same
///         below-floor fill that HookFence rejects. This suite is the attempt to
///         *disprove* that HookFence adds anything at all, and it documents exactly
///         where that attempt fails.
///
/// @dev How baseline B is modelled here, and why it is fair.
///
///      Baseline B is `BaselineOracleRouter`: an ordinary v4 router whose only
///      safety parameter is `minAmountOut`, a `uint256`. A caller using it derives
///      that number from the reference feeds *before* sending the transaction -
///      that is the only thing it can do, because the router's interface has
///      nowhere to put anything else.
///
///      So the tests below compute B's floor from the feed state at quote time,
///      then let the world change before the transaction mines. That is not a
///      contrived handicap; it is the actual shape of the integration. The
///      structural difference is:
///
///        B enforces a NUMBER decided earlier, off-chain.
///        C re-derives the floor, and re-checks instrument state, in the block that
///          settles.
///
///      A conscientious B integrator can of course re-check staleness and pause
///      state off-chain before signing. Two things remain true even then, and both
///      are the honest basis of the product claim:
///        1. the gap between checking and mining is not closed by an off-chain check;
///        2. doing so means re-implementing this policy in every integration, which
///           is the integration-cost argument, not a security-theatre argument.
contract PolicyBeyondFloorTest is HookFenceFixture {
    uint256 internal constant TRADE_SIZE = 10e18;
    uint256 internal constant MINED_GAS_PRICE = 2 gwei;

    /// @dev Floor a baseline-B caller computed at quote time, before the defect.
    uint256 internal quoteTimeFloor;

    function setUp() public override {
        super.setUp();
        _giveTrader(TRADE_SIZE * 20);
        (quoteTimeFloor,) = policy.requiredMinOut(address(stock), address(usdg), TRADE_SIZE, 0);

        vm.startPrank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);
        stock.approve(address(gateway), type(uint256).max);
        vm.stopPrank();
    }

    // =======================================================================
    // PART 1 - What BOTH catch. Stated first, deliberately.
    // =======================================================================

    /// @notice Output enforcement is NOT a HookFence invention.
    function test_Equal_BothRejectBelowFloorFill() public {
        bool bSettled = _runBaseline(adversarialKey, quoteTimeFloor);
        bool cSettled = _runHookFence(adversarialKey, 0);

        assertFalse(bSettled, "B rejects the below-floor fill");
        assertFalse(cSettled, "C rejects the same fill");
        _record("below-floor fill", false, false);
    }

    /// @notice Neither blocks an honest trade.
    function test_Equal_BothAcceptHonestFill() public {
        assertTrue(_runBaseline(honestKey, quoteTimeFloor), "B accepts");
        assertTrue(_runHookFence(honestKey, 0), "C accepts");
        _record("honest fill", true, true);
    }

    // =======================================================================
    // PART 2 - What ONLY HookFence catches.
    // =======================================================================

    /// @notice THE HEADLINE DIFFERENCE.
    ///
    ///         The reference price moves up between quote and settlement while the
    ///         pool has not repriced. B is still enforcing the floor it computed
    ///         earlier, so it happily sells at the old level. C re-derives the floor
    ///         in the settling block and refuses.
    ///
    /// @dev This is the scenario that makes "just pass a minimum to a normal router"
    ///      not equivalent, and it needs no malicious hook at all - only latency
    ///      between an off-chain calculation and inclusion.
    function test_OnlyC_ReferencePriceMovedBeforeInclusion() public {
        // The instrument reprices 10% upward; the AMM has not caught up.
        int256 newPrice = (AAPL_USD * 110) / 100;
        stockFeed.setAnswer(newPrice);
        usdgFeed.setAnswer(USDG_USD);

        (uint256 currentFloor,) = policy.requiredMinOut(address(stock), address(usdg), TRADE_SIZE, 0);

        console2.log("floor computed at quote time :", quoteTimeFloor);
        console2.log("floor correct at settlement  :", currentFloor);

        bool bSettled = _runBaseline(honestKey, quoteTimeFloor);
        bool cSettled = _runHookFence(honestKey, 0);

        assertTrue(bSettled, "B settles against its stale, too-low floor");
        assertFalse(cSettled, "C re-derives the floor in-block and refuses");
        assertGt(currentFloor, quoteTimeFloor, "the correct floor really did move");
        _record("reference price moved before inclusion", true, false);
    }

    /// @notice A `uint256 minAmountOut` cannot express "the feed is stale".
    ///
    ///         The pool still quotes the old price, so it pays B's number and B
    ///         settles. C refuses to price against data nobody is standing behind.
    function test_OnlyC_StaleFeed() public {
        vm.warp(block.timestamp + FEED_HEARTBEAT + 1);

        bool bSettled = _runBaseline(honestKey, quoteTimeFloor);
        bool cSettled = _runHookFence(honestKey, 0);

        assertTrue(bSettled, "B has no concept of feed staleness");
        assertFalse(cSettled, "C fails closed on a stale feed");
        _record("stale feed", true, false);
    }

    /// @notice The issuer pause flag is Stock-Token-specific and advisory: Robinhood
    ///         documents that a paused oracle may still return a value. A generic
    ///         oracle-floor router therefore sees nothing wrong at all.
    function test_OnlyC_IssuerOraclePaused() public {
        _refreshFeeds();
        stock.setOraclePaused(true);

        bool bSettled = _runBaseline(honestKey, quoteTimeFloor);
        bool cSettled = _runHookFence(honestKey, 0);

        assertTrue(bSettled, "B cannot see oraclePaused()");
        assertFalse(cSettled, "C treats a paused oracle as price-unavailable");
        _record("issuer oracle paused", true, false);
    }

    /// @notice A scheduled ERC-8056 multiplier change means the token's economics are
    ///         about to move. Nothing about that is visible in a minimum-output bound.
    function test_OnlyC_CorporateActionPending() public {
        _refreshFeeds();
        // A 2-for-1 split lands in 10 minutes; the policy buffer is 1 hour.
        stock.scheduleMultiplier(stock.uiMultiplier() * 2, block.timestamp + 10 minutes);

        bool bSettled = _runBaseline(honestKey, quoteTimeFloor);
        bool cSettled = _runHookFence(honestKey, 0);

        assertTrue(bSettled, "B settles straight through a pending corporate action");
        assertFalse(cSettled, "C declines inside the corporate-action window");
        _record("corporate action pending", true, false);
    }

    /// @notice Defence in depth: the gateway measures the recipient's real balance
    ///         change rather than trusting what the adapter reports.
    function test_OnlyC_AdapterMisreportsOutput() public {
        _refreshFeeds();

        MisreportingAdapter bad = new MisreportingAdapter(makeAddr("attacker"), type(uint128).max);
        vm.prank(admin);
        gateway.setAdapter(address(bad), true);

        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, 0, honestKey, 4242);
        intent.adapter = address(bad);

        uint256 before = usdg.balanceOf(trader);

        vm.prank(trader, trader);
        vm.expectRevert(abi.encodeWithSelector(ExecutionGateway.OutputBelowFloor.selector, 0, quoteTimeFloor));
        gateway.settle(intent, honestKey, _zeroForOne());

        assertEq(usdg.balanceOf(trader), before, "no USDG moved");
        assertEq(stock.balanceOf(makeAddr("attacker")), 0, "and the input was rolled back too");
        _record("adapter misreports output", true, false);
    }

    /// @notice An ordinary router has no notion of an authorised intent, so there is
    ///         nothing to replay and nothing to expire. These have no baseline-B
    ///         equivalent at all.
    function test_OnlyC_IntentCannotBeReplayed() public {
        _refreshFeeds();

        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, 0, honestKey, 99);

        vm.prank(trader, trader);
        gateway.settle(intent, honestKey, _zeroForOne());

        vm.prank(trader, trader);
        vm.expectRevert(abi.encodeWithSelector(ExecutionGateway.NonceAlreadyUsed.selector, trader, 99));
        gateway.settle(intent, honestKey, _zeroForOne());

        _record("intent replay", true, false);
    }

    function test_OnlyC_ExpiredIntentRejected() public {
        _refreshFeeds();
        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, 0, honestKey, 100);
        intent.deadline = block.timestamp - 1;

        vm.prank(trader, trader);
        vm.expectRevert(
            abi.encodeWithSelector(ExecutionGateway.IntentExpired.selector, intent.deadline, block.timestamp)
        );
        gateway.settle(intent, honestKey, _zeroForOne());
        _record("expired intent", true, false);
    }

    /// @notice Changing any material policy configuration invalidates in-flight
    ///         intents, so an operator cannot silently loosen the rules under a
    ///         trade that was authorised against the old ones.
    function test_OnlyC_PolicyVersionMismatchRejected() public {
        _refreshFeeds();
        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, 0, honestKey, 101);

        // Operator widens the permitted shortfall after the intent was built.
        vm.prank(admin);
        policy.setStockToken(address(stock), address(stockFeed), FEED_HEARTBEAT, 500);

        // Read the new version BEFORE pranking: an external call made while a prank
        // is armed consumes it, and the settle would then run as the test contract.
        uint64 newVersion = policy.policyVersion();
        assertEq(newVersion, intent.policyVersion + 1, "config change must bump the version");

        vm.prank(trader, trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionGateway.PolicyVersionMismatch.selector, intent.policyVersion, newVersion
            )
        );
        gateway.settle(intent, honestKey, _zeroForOne());
        _record("policy version changed mid-flight", true, false);
    }

    /// @notice Identity is by reviewed address, not ticker. A look-alike token with
    ///         the same symbol is simply not supported.
    function test_OnlyC_LookalikeTokenRejected() public {
        _refreshFeeds();
        // Same name and symbol as the real thing, different address.
        address impostor = address(new MockLookalike());

        vm.expectRevert(abi.encodeWithSelector(StockTokenReferencePolicy.TokenNotSupported.selector, impostor));
        policy.requiredMinOut(impostor, address(usdg), TRADE_SIZE, 0);
        _record("look-alike token address", true, false);
    }

    // =======================================================================
    // Runners
    // =======================================================================

    function _runBaseline(PoolKey memory key, uint256 minOut) internal returns (bool settled) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(MINED_GAS_PRICE);
        vm.prank(trader, trader);
        try baselineRouter.swapExactIn(key, _zeroForOne(), TRADE_SIZE, minOut, trader) returns (uint256) {
            settled = true;
        } catch {
            settled = false;
        }
        vm.revertToState(snap);
    }

    function _runHookFence(PoolKey memory key, uint256 userMinOut) internal returns (bool settled) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(MINED_GAS_PRICE);
        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, userMinOut, key, 1);
        vm.prank(trader, trader);
        try gateway.settle(intent, key, _zeroForOne()) returns (uint256) {
            settled = true;
        } catch {
            settled = false;
        }
        vm.revertToState(snap);
    }

    function _record(string memory scenario, bool bSettled, bool cSettled) internal pure {
        console2.log(
            string.concat(
                "scenario: ", scenario, " | B=", bSettled ? "SETTLED" : "REJECTED", " C=", cSettled ? "SETTLED" : "REJECTED"
            )
        );
    }
}

/// @dev Same symbol as the real Stock Token, different contract. Not supported.
contract MockLookalike {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function symbol() external pure returns (string memory) {
        return "AAPL";
    }

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }
}
