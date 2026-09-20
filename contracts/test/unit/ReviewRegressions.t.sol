// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";

/// @notice Token whose multiplier advances at `effectiveAt`, matching the ERC-8056
///         reference implementation's timestamp-dependent getter.
/// @dev Taken from the independent review's reproduction. This is a model of the
///      reference implementation, NOT a verified copy of a deployed Robinhood
///      contract - the live behaviour still needs a pinned-fork check.
contract TimedMultiplierToken is ERC20 {
    uint256 public immutable effectiveAt;
    uint256 public constant newUIMultiplier = 2e18;
    bool public constant oraclePaused = false;

    constructor(uint256 at) ERC20("Timed", "TIMED") {
        effectiveAt = at;
    }

    function uiMultiplier() external view returns (uint256) {
        return block.timestamp >= effectiveAt ? newUIMultiplier : 1e18;
    }
}

/// @title Regressions for defects found in independent review of commit 976ec9a
///
/// @notice Two defects were reproduced by an independent reviewer. These tests are
///         the inverted versions: they assert the defects are CLOSED. Each one
///         fails against the pre-fix code.
///
/// @dev Both assert a precise custom error rather than "some revert happened", so
///      they cannot pass for an unrelated reason.
contract ReviewRegressionsTest is HookFenceFixture {
    uint256 internal constant TRADE = 10e18;

    // =======================================================================
    // Defect 1 - a replacement policy must not inherit old signatures
    // =======================================================================

    /// @notice An intent signed against one policy contract must NOT authorise
    ///         against a replacement that reports the same policyId/policyVersion.
    ///
    /// @dev Original finding: `policyId` and `policyVersion` are both self-reported
    ///      by the policy contract, so an administrator could deploy a second policy
    ///      with an identical pair but a 5% shortfall instead of 0.5%, call
    ///      `setPolicy`, and an already-signed intent would still settle - below the
    ///      floor its signer agreed to.
    ///
    ///      Fixed by binding the policy ADDRESS and a gateway-owned `configEpoch`
    ///      into the signed struct.
    function test_Regression_ReplacementPolicyCannotReuseOldSignature() public {
        _giveTrader(TRADE);
        vm.prank(trader);
        stock.approve(address(gateway), TRADE);

        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE, 0, adversarialKey, 112233);
        bytes memory signature = _sign(intent);

        address originalPolicy = address(policy);
        uint64 originalEpoch = gateway.configEpoch();

        // Administrator swaps in a looser policy carrying the SAME id and version.
        vm.startPrank(admin);
        StockTokenReferencePolicy replacement = new StockTokenReferencePolicy(POLICY_ID, admin);
        replacement.setStockToken(address(stock), address(stockFeed), FEED_HEARTBEAT, 500); // 5%
        replacement.setQuoteAsset(address(usdg), address(usdgFeed), FEED_HEARTBEAT, USDG_DECIMALS);
        gateway.setPolicy(replacement);
        vm.stopPrank();

        // The impersonation is genuine: identity and version are indistinguishable.
        assertEq(replacement.policyId(), policy.policyId(), "same policyId");
        assertEq(replacement.policyVersion(), intent.policyVersion, "same policyVersion");
        assertTrue(address(replacement) != originalPolicy, "but a different contract");

        // The epoch moved, so the old authorisation is dead.
        assertEq(gateway.configEpoch(), originalEpoch + 1, "setPolicy must bump the epoch");

        vm.txGasPrice(2 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionGateway.PolicyContractMismatch.selector, originalPolicy, address(replacement)
            )
        );
        gateway.settleWithSignature(intent, adversarialKey, _zeroForOne(), signature);
    }

    /// @notice Enabling or disabling an adapter also invalidates in-flight intents.
    function test_Regression_AdapterConfigChangeBumpsEpoch() public {
        _giveTrader(TRADE);
        vm.prank(trader);
        stock.approve(address(gateway), TRADE);

        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE, 0, honestKey, 5150);
        bytes memory signature = _sign(intent);
        uint64 signedEpoch = intent.configEpoch;

        vm.prank(admin);
        gateway.setAdapter(makeAddr("someOtherAdapter"), true);

        vm.txGasPrice(2 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(ExecutionGateway.ConfigEpochMismatch.selector, signedEpoch, signedEpoch + 1)
        );
        gateway.settleWithSignature(intent, honestKey, _zeroForOne(), signature);
    }

    /// @notice Control: with configuration untouched, the same signature settles.
    /// @dev Without this, the two tests above would also pass if signatures were
    ///      simply broken.
    function test_Regression_SignatureStillWorksWhenConfigUnchanged() public {
        _giveTrader(TRADE);
        vm.prank(trader);
        stock.approve(address(gateway), TRADE);

        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE, 0, honestKey, 6161);
        bytes memory signature = _sign(intent);

        vm.txGasPrice(2 gwei);
        uint256 received = gateway.settleWithSignature(intent, honestKey, _zeroForOne(), signature);

        (uint256 floor,) = policy.requiredMinOut(address(stock), address(usdg), TRADE, 0);
        assertGe(received, floor, "honest signed settlement clears the floor");
    }

    // =======================================================================
    // Defect 2 - the post-effective corporate-action buffer
    // =======================================================================

    /// @notice The buffer must hold on BOTH sides of `effectiveAt`.
    ///
    /// @dev Original finding: `_checkInstrumentState` returned early when
    ///      `newUIMultiplier() == uiMultiplier()`. Under the ERC-8056 reference
    ///      getter those become equal exactly AT `effectiveAt`, so the documented
    ///      post-effective buffer was skipped from that instant onward. The reviewer
    ///      reproduced a rejection one second before the transition and an
    ///      acceptance one second after it, with the pre-transition feed still
    ///      inside its heartbeat.
    ///
    ///      This test walks before / at / after and requires rejection throughout.
    function test_Regression_CorporateActionBufferHoldsAcrossTheTransition() public {
        TimedMultiplierToken token = new TimedMultiplierToken(block.timestamp + 10 minutes);

        vm.prank(admin);
        policy.setStockToken(address(token), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        // Read the transition time back from the token's immutable rather than
        // keeping a local derived from block.timestamp. Under via-IR such a local
        // is rematerialised after vm.warp changes the timestamp, which silently
        // warps past the window this test exists to probe. See CompilerProbe.t.sol.
        uint256 at = token.effectiveAt();

        bytes memory expected = abi.encodeWithSelector(
            StockTokenReferencePolicy.CorporateActionPending.selector, address(token), at, uint256(2e18)
        );

        // Before the transition.
        vm.expectRevert(expected);
        policy.requiredMinOut(address(token), address(usdg), TRADE, 0);

        // Exactly at it - the moment the getter flips and the old code stopped caring.
        vm.warp(token.effectiveAt());
        vm.expectRevert(expected);
        policy.requiredMinOut(address(token), address(usdg), TRADE, 0);

        // One second after: this is the exact case the reviewer demonstrated passing.
        vm.warp(token.effectiveAt() + 1);
        vm.expectRevert(expected);
        policy.requiredMinOut(address(token), address(usdg), TRADE, 0);

        // Still inside the +1h buffer.
        vm.warp(token.effectiveAt() + 59 minutes);
        vm.expectRevert(expected);
        policy.requiredMinOut(address(token), address(usdg), TRADE, 0);
    }

    /// @notice Once the buffer has fully elapsed, trading resumes.
    /// @dev The fix must not permanently brick an instrument that has completed a
    ///      corporate action.
    function test_Regression_TradingResumesAfterTheBufferElapses() public {
        TimedMultiplierToken token = new TimedMultiplierToken(block.timestamp + 10 minutes);

        vm.prank(admin);
        policy.setStockToken(address(token), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        vm.warp(token.effectiveAt() + 1 hours + 1);
        _refreshFeeds(); // a post-transition price has been published

        (uint256 floor,) = policy.requiredMinOut(address(token), address(usdg), TRADE, 0);
        assertGt(floor, 0, "instrument must become tradeable again");
    }

    /// @notice The same window applies to the mock used by the rest of the suite,
    ///         now that it advances its multiplier the way the reference does.
    function test_Regression_MockAdvancesMultiplierAtEffectiveAt() public {
        uint256 before = stock.uiMultiplier();
        stock.scheduleMultiplier(before * 2, block.timestamp + 10 minutes);

        assertEq(stock.uiMultiplier(), before, "unchanged before effectiveAt");
        vm.warp(stock.effectiveAt());
        assertEq(stock.uiMultiplier(), before * 2, "advances AT effectiveAt, as ERC-8056 does");
        assertEq(stock.newUIMultiplier(), stock.uiMultiplier(), "and the two become equal there");
    }

    // =======================================================================
    // Helpers
    // =======================================================================

    function _sign(ExecutionGateway.ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderKey, gateway.hashIntent(intent));
        return abi.encodePacked(r, s, v);
    }
}
