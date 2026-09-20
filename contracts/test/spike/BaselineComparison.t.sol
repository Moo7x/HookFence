// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";

import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {BaselineOracleRouter} from "../../src/mocks/BaselineOracleRouter.sol";
import {ContextSensitiveHook} from "../../src/mocks/ContextSensitiveHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title Phase 0 - claim validation spike
///
/// @notice Runs four paths from an identical starting state and records what each
///         one does, so the project's central claim can be judged on evidence
///         rather than on the pitch.
///
///   A  quote-derived minimum with a typical 2% user slippage tolerance
///   B  ordinary v4 router given EXACTLY the same oracle floor HookFence uses
///   C  HookFence with the full policy
///   D  honest-hook control, through HookFence
///
/// @dev The result this suite is designed to expose, and does:
///      **B and C reject the same below-floor fill.** HookFence does not beat a
///      correctly configured oracle-floor router on output enforcement, and the
///      test asserts that equality rather than hiding it. Where C differs from B
///      is tested separately in `PolicyBeyondFloor.t.sol`.
contract BaselineComparisonTest is HookFenceFixture {
    uint256 internal constant TRADE_SIZE = 10e18; // 10 Stock Tokens
    uint256 internal constant USER_SLIPPAGE_BPS = 200; // 2%, a typical retail default

    /// @dev Gas price used to model a naive `eth_call` quote (none supplied).
    uint256 internal constant QUOTE_GAS_PRICE = 0;
    /// @dev Gas price used to model the mined transaction.
    uint256 internal constant MINED_GAS_PRICE = 2 gwei;

    struct PathResult {
        bool settled;
        uint256 amountOut;
        uint256 enforcedMin;
        bytes revertData;
    }

    // -----------------------------------------------------------------------
    // The four paths
    // -----------------------------------------------------------------------

    function test_Phase0_FourPathComparison() public {
        _giveTrader(TRADE_SIZE * 10);

        // --- The quote, taken the way a naive integrator takes it --------------
        uint256 quotedOut = _quoteAdversarialPool(TRADE_SIZE);
        uint256 referenceOut = policy.referenceValue(address(stock), address(usdg), TRADE_SIZE);
        (uint256 oracleFloor,) = policy.requiredMinOut(address(stock), address(usdg), TRADE_SIZE, 0);
        uint256 quoteDerivedMin = quotedOut * (10_000 - USER_SLIPPAGE_BPS) / 10_000;

        console2.log("--- inputs ---------------------------------------------");
        console2.log("trade size (18dp stock)     :", TRADE_SIZE);
        console2.log("quoted out    (6dp USDG)    :", quotedOut);
        console2.log("reference out (6dp USDG)    :", referenceOut);
        console2.log("oracle floor  (6dp USDG)    :", oracleFloor);
        console2.log("quote-derived min (2%)      :", quoteDerivedMin);

        // --- Path A ------------------------------------------------------------
        PathResult memory a = _runBaseline(adversarialKey, quoteDerivedMin);
        // --- Path B ------------------------------------------------------------
        PathResult memory b = _runBaseline(adversarialKey, oracleFloor);
        // --- Path C ------------------------------------------------------------
        PathResult memory c = _runHookFence(adversarialKey, 0);
        // --- Path D ------------------------------------------------------------
        PathResult memory d = _runHookFence(honestKey, 0);

        _log("A  quote-derived min (2%)   ", a);
        _log("B  ordinary router + floor  ", b);
        _log("C  HookFence full policy    ", c);
        _log("D  honest-hook control      ", d);

        // --- Assertions: this is the honest conclusion, asserted ---------------

        // A settles a fill that is materially below the independent reference.
        // That is the failure class the project exists to address.
        assertTrue(a.settled, "A: quote-derived slippage should have let this through");
        assertLt(a.amountOut, oracleFloor, "A: and the fill should be below the oracle floor");

        // B and C both reject it. THIS EQUALITY IS THE POINT. HookFence does not
        // invent output enforcement and this suite refuses to imply otherwise.
        assertFalse(b.settled, "B: ordinary router with the same floor must reject");
        assertFalse(c.settled, "C: HookFence must reject");
        assertEq(b.enforcedMin, c.enforcedMin, "B and C must enforce an identical floor");

        // D shows the policy is not simply blocking everything.
        assertTrue(d.settled, "D: an honest fill must still settle");
        assertGe(d.amountOut, oracleFloor, "D: honest fill clears the floor");

        _writeReport(quotedOut, referenceOut, oracleFloor, quoteDerivedMin, a, b, c, d);
    }

    // -----------------------------------------------------------------------
    // Execution-context evidence
    // -----------------------------------------------------------------------

    /// @notice Records the exact context seen by the hook in the quote call and in
    ///         the mined transaction, as the spike brief requires.
    function test_Phase0_RecordsQuoteAndMinedContexts() public {
        _giveTrader(TRADE_SIZE * 4);

        // Capture the hook's recorded context BEFORE the snapshot is rolled back.
        // Reading it afterwards returns the reverted storage, where zero/false are
        // indistinguishable from defaults - an earlier version of this test did
        // exactly that and was asserting against default values, not observations.
        ContextSensitiveHook.ObservedContext memory quoteCtx;
        {
            uint256 snap = vm.snapshotState();
            vm.txGasPrice(QUOTE_GAS_PRICE);
            vm.prank(trader);
            stock.approve(address(baselineRouter), type(uint256).max);
            vm.prank(trader, trader);
            baselineRouter.swapExactIn(adversarialKey, _zeroForOne(), TRADE_SIZE, 0, trader);
            quoteCtx = _hookContext(); // read while the quote's state still exists
            vm.revertToState(snap);
        }

        vm.txGasPrice(MINED_GAS_PRICE);
        vm.prank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);
        vm.prank(trader, trader);
        baselineRouter.swapExactIn(adversarialKey, _zeroForOne(), TRADE_SIZE, 0, trader);
        ContextSensitiveHook.ObservedContext memory minedCtx = _hookContext();

        console2.log("--- recorded execution contexts ------------------------");
        console2.log("quote  tx.gasprice :", quoteCtx.gasPrice);
        console2.log("quote  extracted   :", quoteCtx.extracted);
        console2.log("mined  tx.gasprice :", minedCtx.gasPrice);
        console2.log("mined  extracted   :", minedCtx.extracted);
        console2.log("mined  extracted amt:", minedCtx.extractedAmount);

        assertEq(quoteCtx.gasPrice, QUOTE_GAS_PRICE, "quote context: no gas price supplied");
        assertFalse(quoteCtx.extracted, "quote context: hook behaves honestly");
        assertEq(minedCtx.gasPrice, MINED_GAS_PRICE, "mined context: real gas price");
        assertTrue(minedCtx.extracted, "mined context: hook extracts");
        assertGt(minedCtx.extractedAmount, 0);
    }

    /// @notice The counter-evidence. We do not claim `eth_call` is inherently
    ///         detectable, and here is the proof that it is not: a quote taken with
    ///         a realistic gas price sees the extraction immediately.
    ///
    /// @dev This matters for honesty. The discriminator in `ContextSensitiveHook` is
    ///      a *default-path* weakness, not a universal one. Any integrator who
    ///      simulates with transaction-like context defeats this particular hook -
    ///      which is exactly why the durable defence is an independent reference
    ///      floor rather than a better simulator, and why baseline B works at all.
    function test_Phase0_AdversarialHook_IsDefeatedBy_RealisticQuoteContext() public {
        _giveTrader(TRADE_SIZE * 4);

        uint256 naiveQuote = _quoteAdversarialPoolAtGasPrice(TRADE_SIZE, QUOTE_GAS_PRICE);
        uint256 realisticQuote = _quoteAdversarialPoolAtGasPrice(TRADE_SIZE, MINED_GAS_PRICE);

        console2.log("naive quote (gasprice 0)    :", naiveQuote);
        console2.log("realistic quote (gasprice>0):", realisticQuote);

        assertGt(naiveQuote, realisticQuote, "the naive quote is the optimistic one");

        // A realistic simulation already predicts the extraction, so a minimum
        // derived from IT would be safe. The hook is only fooling careless callers.
        (uint256 oracleFloor,) = policy.requiredMinOut(address(stock), address(usdg), TRADE_SIZE, 0);
        assertLt(realisticQuote, oracleFloor, "realistic quote already reveals the shortfall");
    }

    /// @notice Gas cost of HookFence's full policy versus the bare baseline, on a
    ///         settlement that succeeds in both.
    function test_Phase0_GasOverheadVersusBaseline() public {
        _giveTrader(TRADE_SIZE * 10);
        vm.txGasPrice(MINED_GAS_PRICE);

        // Baseline B on the honest pool.
        vm.prank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);
        (uint256 floor,) = policy.requiredMinOut(address(stock), address(usdg), TRADE_SIZE, 0);

        uint256 gasBefore = gasleft();
        vm.prank(trader, trader);
        baselineRouter.swapExactIn(honestKey, _zeroForOne(), TRADE_SIZE, floor, trader);
        uint256 gasB = gasBefore - gasleft();

        // HookFence C on the honest pool.
        vm.prank(trader);
        stock.approve(address(gateway), type(uint256).max);
        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, 0, honestKey, 777);

        gasBefore = gasleft();
        vm.prank(trader, trader);
        gateway.settle(intent, honestKey, _zeroForOne());
        uint256 gasC = gasBefore - gasleft();

        console2.log("gas: baseline B (router + floor) :", gasB);
        console2.log("gas: HookFence C (full policy)   :", gasC);
        console2.log("gas: overhead                    :", gasC - gasB);

        string memory json = "gas";
        vm.serializeUint(json, "baselineB", gasB);
        vm.serializeUint(json, "hookfenceC", gasC);
        string memory out = vm.serializeUint(json, "overhead", gasC - gasB);
        vm.writeJson(out, "./reports/gas-comparison.json");

        // NOTE ON THIS BENCHMARK, so the figure is not over-read:
        // B executes first and warms storage slots and account accesses that C then
        // reuses, and the policy is also read before timing starts. This is an
        // in-harness comparison showing the overhead is material and positive, NOT a
        // controlled production benchmark. Treat the absolute number as indicative.
        assertGt(gasC, gasB, "the extra checks are not free, and we report the cost");
    }

    // -----------------------------------------------------------------------
    // Path runners
    // -----------------------------------------------------------------------

    /// @dev Models an `eth_call` quote: execute for real, then discard the state.
    ///      This is exactly what a node does for `eth_call` - writes happen and are
    ///      thrown away - so the hook's storage write is not what distinguishes it.
    function _quoteAdversarialPool(uint256 amountIn) internal returns (uint256) {
        return _quoteAdversarialPoolAtGasPrice(amountIn, QUOTE_GAS_PRICE);
    }

    function _quoteAdversarialPoolAtGasPrice(uint256 amountIn, uint256 gasPrice) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(gasPrice);
        vm.prank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);
        vm.prank(trader, trader);
        uint256 out = baselineRouter.swapExactIn(adversarialKey, _zeroForOne(), amountIn, 0, trader);
        vm.revertToState(snap);
        return out;
    }

    /// @dev Paths A and B: the same ordinary router, differing only in the minimum
    ///      it is given. Both run in the mined context and are rolled back so every
    ///      path starts from identical state.
    function _runBaseline(PoolKey memory key, uint256 minOut) internal returns (PathResult memory r) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(MINED_GAS_PRICE);

        vm.prank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);

        r.enforcedMin = minOut;
        vm.prank(trader, trader);
        try baselineRouter.swapExactIn(key, _zeroForOne(), TRADE_SIZE, minOut, trader) returns (uint256 out) {
            r.settled = true;
            r.amountOut = out;
        } catch (bytes memory err) {
            r.settled = false;
            r.revertData = err;
            // Recover what the fill would have been, for the report.
            r.amountOut = _fillWithoutMinimum(key);
        }

        vm.revertToState(snap);
    }

    /// @dev Paths C and D: the same gateway call, differing only in which pool -
    ///      and therefore which hook - the reviewed route points at.
    function _runHookFence(PoolKey memory key, uint256 userMinOut) internal returns (PathResult memory r) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(MINED_GAS_PRICE);

        vm.prank(trader);
        stock.approve(address(gateway), type(uint256).max);

        (r.enforcedMin,) = policy.requiredMinOut(address(stock), address(usdg), TRADE_SIZE, userMinOut);

        ExecutionGateway.ExecutionIntent memory intent =
            _buildIntent(trader, trader, TRADE_SIZE, userMinOut, key, 1);

        vm.prank(trader, trader);
        try gateway.settle(intent, key, _zeroForOne()) returns (uint256 out) {
            r.settled = true;
            r.amountOut = out;
        } catch (bytes memory err) {
            r.settled = false;
            r.revertData = err;
            r.amountOut = _fillWithoutMinimum(key);
        }

        vm.revertToState(snap);
    }

    /// @dev What the pool would actually have paid with no minimum enforced, in the
    ///      mined context. Used only to report the counterfactual fill next to a
    ///      rejection; it is rolled back and never affects a path's outcome.
    function _fillWithoutMinimum(PoolKey memory key) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(MINED_GAS_PRICE);
        vm.prank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);
        vm.prank(trader, trader);
        out = baselineRouter.swapExactIn(key, _zeroForOne(), TRADE_SIZE, 0, trader);
        vm.revertToState(snap);
    }

    function _log(string memory label, PathResult memory r) internal pure {
        console2.log(label, r.settled ? "SETTLED" : "REVERTED", r.amountOut);
    }

    function _hookContext() internal view returns (ContextSensitiveHook.ObservedContext memory ctx) {
        (ctx.gasPrice, ctx.baseFee, ctx.origin, ctx.coinbase, ctx.extracted, ctx.extractedAmount) =
            adversarialHook.lastContext();
    }

    function _writeReport(
        uint256 quotedOut,
        uint256 referenceOut,
        uint256 oracleFloor,
        uint256 quoteDerivedMin,
        PathResult memory a,
        PathResult memory b,
        PathResult memory c,
        PathResult memory d
    ) internal {
        string memory root = "phase0";
        vm.serializeUint(root, "tradeSizeStock18dp", TRADE_SIZE);
        vm.serializeUint(root, "quotedOutUsdg6dp", quotedOut);
        vm.serializeUint(root, "referenceOutUsdg6dp", referenceOut);
        vm.serializeUint(root, "oracleFloorUsdg6dp", oracleFloor);
        vm.serializeUint(root, "quoteDerivedMinUsdg6dp", quoteDerivedMin);
        vm.serializeBool(root, "A_settled", a.settled);
        vm.serializeUint(root, "A_amountOut", a.amountOut);
        vm.serializeBool(root, "B_settled", b.settled);
        vm.serializeUint(root, "B_enforcedMin", b.enforcedMin);
        vm.serializeBool(root, "C_settled", c.settled);
        vm.serializeUint(root, "C_enforcedMin", c.enforcedMin);
        vm.serializeBool(root, "D_settled", d.settled);
        string memory out = vm.serializeUint(root, "D_amountOut", d.amountOut);
        vm.writeJson(out, "./reports/phase0-baselines.json");
    }
}
