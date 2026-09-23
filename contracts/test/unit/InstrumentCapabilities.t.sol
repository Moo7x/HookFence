// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";

import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockPartialStockToken, MockRetractingStockToken} from "../../src/mocks/MockPartialStockToken.sol";

/// @title Instruments that do not implement the whole Stock Token surface
///
/// @notice Robinhood Chain **mainnet** Stock Tokens answer `oraclePaused()`. The
///         equity tokens on **testnet** (chainId 46630) do not — read directly on
///         2026-09-23, TSLA `0xc9f9…bd4e` and AMZN `0x5884…9e02` implement
///         `uiMultiplier()`, `newUIMultiplier()`, `effectiveAt()` and
///         `totalSupplyUI()`, and revert on `oraclePaused()`.
///
///         Without the capability probe the policy cannot quote a single testnet
///         trade, so there is no public deployment to demonstrate. These tests
///         fix the behaviour in both directions: a missing capability is skipped
///         and recorded, a capability that disappears after configuration is a
///         hard failure.
contract InstrumentCapabilitiesTest is HookFenceFixture {
    uint256 internal constant USDG_IN = 2550_000000;

    // =======================================================================
    // Probing at configuration time
    // =======================================================================

    function test_FullTokenIsRecordedAsHavingEverything() public view {
        StockTokenReferencePolicy.StockTokenConfig memory cfg = policy.stockTokenConfig(address(stock));
        assertTrue(cfg.hasOraclePaused, "mainnet-shaped token exposes oraclePaused");
        assertTrue(cfg.hasCorporateActionData, "and the ERC-8056 reads");
    }

    function test_TestnetShapedTokenIsRecordedWithoutOraclePaused() public {
        MockPartialStockToken tsla = new MockPartialStockToken("Tesla", "TSLA");
        vm.prank(admin);
        policy.setStockToken(address(tsla), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        StockTokenReferencePolicy.StockTokenConfig memory cfg = policy.stockTokenConfig(address(tsla));
        assertFalse(cfg.hasOraclePaused, "oraclePaused() is absent on this instrument");
        assertTrue(cfg.hasCorporateActionData, "but the corporate-action reads are present");
    }

    function test_CapabilitiesAreEmittedForAudit() public {
        MockPartialStockToken tsla = new MockPartialStockToken("Tesla", "TSLA");
        vm.expectEmit(true, false, false, true);
        emit StockTokenReferencePolicy.StockTokenCapabilities(address(tsla), false, true, policy.policyVersion() + 1);
        vm.prank(admin);
        policy.setStockToken(address(tsla), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
    }

    // =======================================================================
    // Quoting
    // =======================================================================

    /// @notice The whole point: a testnet-shaped instrument still prices.
    function test_PartialTokenStillQuotes() public {
        MockPartialStockToken tsla = new MockPartialStockToken("Tesla", "TSLA");
        vm.prank(admin);
        policy.setStockToken(address(tsla), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        uint256 value = policy.referenceValue(address(usdg), address(tsla), USDG_IN);
        assertGt(value, 0, "buy leg prices against an instrument with no oraclePaused()");

        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(tsla), USDG_IN, 0);
        assertGt(floor, 0, "and produces a real floor");
        assertLe(floor, value, "the floor never exceeds the reference");
    }

    /// @notice Skipping the pause read must not skip the corporate-action window.
    function test_PartialTokenStillRejectsACorporateActionWindow() public {
        MockPartialStockToken tsla = new MockPartialStockToken("Tesla", "TSLA");
        vm.prank(admin);
        policy.setStockToken(address(tsla), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        uint256 at = vm.getBlockTimestamp() + 10 minutes;
        tsla.scheduleMultiplier(2e18, at);

        vm.expectRevert(
            abi.encodeWithSelector(StockTokenReferencePolicy.CorporateActionPending.selector, address(tsla), at, 2e18)
        );
        policy.requiredMinOut(address(usdg), address(tsla), USDG_IN, 0);
    }

    /// @notice A token that answers `oraclePaused()` is still subject to it.
    function test_TokenThatAnswersIsStillGatedByThePause() public {
        MockRetractingStockToken rh = new MockRetractingStockToken("Tesla", "TSLA");
        vm.prank(admin);
        policy.setStockToken(address(rh), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        rh.setOraclePaused(true);
        vm.expectRevert(
            abi.encodeWithSelector(StockTokenReferencePolicy.OraclePausedForCorporateAction.selector, address(rh))
        );
        policy.requiredMinOut(address(usdg), address(rh), USDG_IN, 0);
    }

    // =======================================================================
    // Fail-closed
    // =======================================================================

    /// @notice The failure mode a try/catch would have introduced.
    /// @dev If the policy treated a reverting `oraclePaused()` as `false`, this
    ///      quote would succeed and a genuinely paused instrument would trade.
    function test_RetractedCapabilityFailsClosedRatherThanReadingAsUnpaused() public {
        MockRetractingStockToken rh = new MockRetractingStockToken("Tesla", "TSLA");
        vm.prank(admin);
        policy.setStockToken(address(rh), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        (uint256 floorBefore,) = policy.requiredMinOut(address(usdg), address(rh), USDG_IN, 0);
        assertGt(floorBefore, 0, "authorises while answering");

        rh.stopAnswering();

        vm.expectRevert(
            abi.encodeWithSelector(
                StockTokenReferencePolicy.InstrumentStateUnavailable.selector,
                address(rh),
                IStockToken.oraclePaused.selector
            )
        );
        policy.requiredMinOut(address(usdg), address(rh), USDG_IN, 0);
    }

    /// @notice Re-registering after the token changes shape updates the record.
    function test_ReconfiguringRefreshesTheCapabilitySet() public {
        MockRetractingStockToken rh = new MockRetractingStockToken("Tesla", "TSLA");
        vm.prank(admin);
        policy.setStockToken(address(rh), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
        assertTrue(policy.stockTokenConfig(address(rh)).hasOraclePaused, "present at first registration");

        rh.stopAnswering();
        vm.prank(admin);
        policy.setStockToken(address(rh), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        assertFalse(policy.stockTokenConfig(address(rh)).hasOraclePaused, "absent at the second");
        (uint256 floorAfter,) = policy.requiredMinOut(address(usdg), address(rh), USDG_IN, 0);
        assertGt(floorAfter, 0, "and quoting resumes");
    }

    /// @notice Reconfiguration is a material change and must bump the version, so
    ///         signed intents carrying the old one stop being executable.
    function test_ReconfiguringBumpsPolicyVersion() public {
        MockPartialStockToken tsla = new MockPartialStockToken("Tesla", "TSLA");
        uint64 before = policy.policyVersion();

        vm.prank(admin);
        policy.setStockToken(address(tsla), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        assertEq(policy.policyVersion(), before + 1, "one bump per material change");
    }
}
