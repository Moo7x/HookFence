// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";

/// @title Executed buys — USDG to Stock Token through the gateway and v4 adapter
///
/// @notice `BuySidePolicy.t.sol` and `PricingSpec.t.sol` test what the policy
///         *computes*. This file tests what the pool *pays*. Those are different
///         numbers and conflating them is how a project ends up claiming a
///         calculation as though it were a trade.
///
/// @dev MOCKED COMPONENTS, stated plainly: the Stock Token, USDG, both Chainlink
///      feeds, both hooks and the pool liquidity are all local fixtures. What is
///      real is the `v4-core` `PoolManager` — swap accounting, tick maths, hook
///      dispatch and settlement are the actual Uniswap v4 implementation, deployed
///      fresh in `setUp()`. So "the pool paid X" is a real v4 result against mock
///      assets, not a simulated fill.
contract BuyExecutionTest is HookFenceFixture {
    uint256 internal constant USDG_IN = 2550_000000; // 2,550.000000 USDG
    uint256 internal constant MINED_GAS_PRICE = 2 gwei;

    /// @dev Buying means trading the quote asset for the Stock Token, i.e. the
    ///      opposite direction to the sell leg the Phase 0 fixture enabled.
    bool internal buyZeroForOne;

    /// @dev Cached so `_buyIntent` makes NO external call. An external call while a
    ///      prank is armed consumes it, and the settle would then run as the test
    ///      contract and fail on `UnauthorisedCaller` instead of on the thing under
    ///      test. Refresh after any config change that bumps either value.
    uint64 internal cachedPolicyVersion;
    uint64 internal cachedConfigEpoch;

    function _refreshConfigCache() internal {
        cachedPolicyVersion = policy.policyVersion();
        cachedConfigEpoch = gateway.configEpoch();
    }

    function setUp() public override {
        super.setUp();
        buyZeroForOne = !_zeroForOne();

        // Enable the buy direction on both pools. Routes are direction-specific by
        // design: enabling a sell route must not implicitly enable its inverse.
        vm.startPrank(admin);
        adapter.setRoute(honestKey, buyZeroForOne, true);
        adapter.setRoute(adversarialKey, buyZeroForOne, true);
        vm.stopPrank();

        usdg.mint(trader, USDG_IN * 20);
        vm.prank(trader);
        usdg.approve(address(gateway), type(uint256).max);
        vm.txGasPrice(MINED_GAS_PRICE);
        _refreshConfigCache();
    }

    // =======================================================================
    // The happy path
    // =======================================================================

    function test_SuccessfulBuy_MovesRealTokens() public {
        uint256 usdgBefore = usdg.balanceOf(trader);
        uint256 stockBefore = stock.balanceOf(trader);

        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);

        vm.prank(trader, trader);
        uint256 received = gateway.settle(_buyIntent(honestKey, 0, 1), honestKey, buyZeroForOne);

        uint256 stockGained = stock.balanceOf(trader) - stockBefore;
        uint256 usdgSpent = usdgBefore - usdg.balanceOf(trader);

        console2.log("USDG spent (6dp)      :", usdgSpent);
        console2.log("stock received (18dp) :", stockGained);
        console2.log("enforced floor (18dp) :", floor);

        assertEq(usdgSpent, USDG_IN, "exactly the authorised input was spent");
        assertEq(stockGained, received, "returned amount equals the measured balance delta");
        assertGe(stockGained, floor, "the fill cleared the enforced floor");
        assertGt(stockGained, 0);
    }

    /// @notice The reference price and the executed price are NOT the same number.
    /// @dev The policy computes what the instrument is worth; the pool pays what its
    ///      curve and fee allow. The gap here is the 0.30% pool fee plus price
    ///      impact. Reporting the reference as though it were the fill would be a
    ///      misrepresentation, so this test pins the distinction.
    function test_ReferencePriceIsNotTheExecutedPrice() public {
        uint256 referenceOut = policy.referenceValue(address(usdg), address(stock), USDG_IN);

        uint256 before = stock.balanceOf(trader);
        vm.prank(trader, trader);
        gateway.settle(_buyIntent(honestKey, 0, 2), honestKey, buyZeroForOne);
        uint256 executed = stock.balanceOf(trader) - before;

        console2.log("reference (computed) :", referenceOut);
        console2.log("executed  (pool paid):", executed);
        console2.log("shortfall vs reference (18dp):", referenceOut - executed);

        assertLt(executed, referenceOut, "an honest pool still charges a fee");
        // Within the 50bps the policy permits, which is why the trade settled.
        assertGe(executed, referenceOut * (10_000 - MAX_SHORTFALL_BPS) / 10_000);
    }

    // =======================================================================
    // Rejection leaves nothing behind
    // =======================================================================

    /// @notice A below-floor buy reverts and leaves every balance and every piece
    ///         of accounting exactly as it was.
    /// @dev The adversarial pool extracts output, so the fill lands under the floor.
    ///      Asserting the revert alone would be weak — the point is that a failed
    ///      settlement is indistinguishable from one that never happened.
    function test_RejectedBuy_LeavesBalancesAndAccountingUnchanged() public {
        uint256 traderUsdg = usdg.balanceOf(trader);
        uint256 traderStock = stock.balanceOf(trader);
        uint256 gatewayUsdg = usdg.balanceOf(address(gateway));
        uint256 gatewayStock = stock.balanceOf(address(gateway));
        uint256 adapterUsdg = usdg.balanceOf(address(adapter));
        uint256 nonce = 3;

        ExecutionGateway.ExecutionIntent memory intent = _buyIntent(adversarialKey, 0, nonce);

        vm.prank(trader, trader);
        vm.expectRevert(); // OutputBelowFloor; exact selector asserted below
        gateway.settle(intent, adversarialKey, buyZeroForOne);

        assertEq(usdg.balanceOf(trader), traderUsdg, "no USDG left the trader");
        assertEq(stock.balanceOf(trader), traderStock, "no stock arrived");
        assertEq(usdg.balanceOf(address(gateway)), gatewayUsdg, "gateway holds nothing new");
        assertEq(stock.balanceOf(address(gateway)), gatewayStock, "gateway holds nothing new");
        assertEq(usdg.balanceOf(address(adapter)), adapterUsdg, "adapter holds nothing new");

        assertEq(usdg.allowance(address(gateway), address(adapter)), 0, "no residual allowance");
        assertFalse(gateway.nonceUsed(trader, nonce), "a reverted settlement must not burn the nonce");
    }

    /// @notice And it fails for the intended reason, not an unrelated one.
    function test_RejectedBuy_FailsWithOutputBelowFloor() public {
        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(stock), USDG_IN, 0);

        // What the adversarial pool would actually pay, measured by letting an
        // unconstrained settlement run and rolling it back.
        uint256 snap = vm.snapshotState();
        vm.prank(admin);
        policy.setStockToken(address(stock), address(stockFeed), FEED_HEARTBEAT, 9_000); // 90% tolerance
        _refreshConfigCache();
        uint256 before = stock.balanceOf(trader);
        vm.prank(trader, trader);
        gateway.settle(_buyIntent(adversarialKey, 0, 4), adversarialKey, buyZeroForOne);
        uint256 wouldReceive = stock.balanceOf(trader) - before;
        vm.revertToState(snap);
        _refreshConfigCache(); // the snapshot rollback restored the original version

        vm.prank(trader, trader);
        vm.expectRevert(
            abi.encodeWithSelector(ExecutionGateway.OutputBelowFloor.selector, wouldReceive, floor)
        );
        gateway.settle(_buyIntent(adversarialKey, 0, 5), adversarialKey, buyZeroForOne);
    }

    /// @notice A user minimum stricter than the pool can fill also reverts cleanly.
    function test_RejectedBuy_UserMinimumTooHigh() public {
        uint256 traderUsdg = usdg.balanceOf(trader);
        uint256 impossible = 100e18; // far more stock than 2,550 USDG can buy

        vm.prank(trader, trader);
        vm.expectRevert();
        gateway.settle(_buyIntent(honestKey, impossible, 6), honestKey, buyZeroForOne);

        assertEq(usdg.balanceOf(trader), traderUsdg, "input returned on rejection");
    }

    // =======================================================================
    // Policy rejections reach the executed path, not just the view
    // =======================================================================

    function test_BuyBlockedWhenOracleIsPaused() public {
        stock.setOraclePaused(true);
        uint256 traderUsdg = usdg.balanceOf(trader);

        vm.prank(trader, trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockTokenReferencePolicy.OraclePausedForCorporateAction.selector, address(stock)
            )
        );
        gateway.settle(_buyIntent(honestKey, 0, 7), honestKey, buyZeroForOne);

        assertEq(usdg.balanceOf(trader), traderUsdg);
    }

    function test_BuyBlockedWhenFeedIsStale() public {
        vm.warp(block.timestamp + FEED_HEARTBEAT + 1);
        vm.prank(trader, trader);
        vm.expectRevert();
        gateway.settle(_buyIntent(honestKey, 0, 8), honestKey, buyZeroForOne);
    }

    // =======================================================================
    // Route direction is not implicitly bidirectional
    // =======================================================================

    /// @notice Enabling a sell route must not enable its inverse.
    /// @dev Directions are reviewed separately because their liquidity, price impact
    ///      and hook behaviour differ. This asserts the adapter treats them as
    ///      distinct rather than as one "pair".
    function test_DisablingTheBuyRouteBlocksBuysButNotSells() public {
        vm.prank(admin);
        adapter.setRoute(honestKey, buyZeroForOne, false);

        vm.prank(trader, trader);
        vm.expectRevert();
        gateway.settle(_buyIntent(honestKey, 0, 9), honestKey, buyZeroForOne);

        // The sell direction is untouched.
        _giveTrader(1e18);
        vm.prank(trader);
        stock.approve(address(gateway), type(uint256).max);
        ExecutionGateway.ExecutionIntent memory sellIntent =
            _buildIntent(trader, trader, 1e18, 0, honestKey, 10);
        vm.prank(trader, trader);
        uint256 out = gateway.settle(sellIntent, honestKey, _zeroForOne());
        assertGt(out, 0, "the sell route still works");
    }

    // =======================================================================
    // Helper
    // =======================================================================

    function _buyIntent(PoolKey memory key, uint256 userMinOut, uint256 nonce)
        internal
        view
        returns (ExecutionGateway.ExecutionIntent memory)
    {
        return ExecutionGateway.ExecutionIntent({
            chainId: block.chainid,
            gateway: address(gateway),
            owner: trader,
            recipient: trader,
            tokenIn: address(usdg),
            tokenOut: address(stock),
            amountIn: USDG_IN,
            userMinOut: userMinOut,
            adapter: address(adapter),
            routeHash: keccak256(abi.encode(key, buyZeroForOne)),
            policy: address(policy),
            policyId: POLICY_ID,
            policyVersion: cachedPolicyVersion,
            configEpoch: cachedConfigEpoch,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }
}
