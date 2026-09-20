// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTestHook} from "./BaseTestHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title ContextSensitiveHook
/// @notice TEST FIXTURE. A hook that pays out honestly under one execution context
///         and extracts output under another.
///
/// @dev ---------------------------------------------------------------------
///      READ THIS BEFORE CITING THIS FIXTURE AS EVIDENCE OF ANYTHING
///      ---------------------------------------------------------------------
///
///      What this models, honestly:
///
///      Enso documented production pools whose behaviour depends on environment
///      values - gas price, tx.origin, msg.sender, block.coinbase, block.basefee -
///      so that a routing simulation sees a better result than the mined
///      transaction. (https://blog.enso.build/toxic-pools/) This fixture reproduces
///      that *failure class* with one documented discriminator so the A/B/C/D
///      comparison has something real to bite on.
///
///      The discriminator here is `tx.gasprice`:
///
///        - A naive `eth_call` quote sends no gasPrice, so the EVM reports
///          `tx.gasprice == 0`. The hook takes nothing and the quote looks clean.
///        - A mined transaction always has `tx.gasprice > 0`. The hook extracts
///          `extractionBps` of the output.
///
///      What this is NOT:
///
///      This is NOT a claim that `eth_call` is inherently distinguishable from a
///      transaction. It is not. A caller may set `gasPrice` on an `eth_call` and
///      this discriminator collapses immediately - and `test/spike/` proves exactly
///      that in `test_AdversarialHook_IsDefeatedBy_RealisticQuoteContext`. State
///      writes during `eth_call` also execute normally and are merely discarded,
///      so no "real settlement" persistence flag would be honest either.
///
///      The point being made is narrower and survivable: **default quoting paths
///      are distinguishable, so a quote-derived minimum is not a trustworthy
///      safety bound.** The defence that follows from that is an *independent*
///      reference floor - which is precisely why baseline B (an ordinary router
///      given the same oracle floor) also defeats this hook, and why HookFence
///      must not claim otherwise.
contract ContextSensitiveHook is BaseTestHook {
    /// @notice Below this `tx.gasprice`, the hook behaves honestly.
    uint256 public immutable gasPriceThreshold;
    /// @notice Share of swap output taken when the hook decides it is being mined.
    uint256 public immutable extractionBps;

    /// @notice Recorded context of the most recent swap, for the evidence table.
    struct ObservedContext {
        uint256 gasPrice;
        uint256 baseFee;
        address origin;
        address coinbase;
        bool extracted;
        uint256 extractedAmount;
    }

    ObservedContext public lastContext;

    uint256 internal constant BPS = 10_000;

    constructor(IPoolManager poolManager_, uint256 gasPriceThreshold_, uint256 extractionBps_)
        BaseTestHook(poolManager_)
    {
        gasPriceThreshold = gasPriceThreshold_;
        extractionBps = extractionBps_;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        // For an exact-input swap the "unspecified" currency is the output side.
        // amountSpecified < 0 == exact input.
        bool exactInput = params.amountSpecified < 0;
        Currency unspecified = _unspecifiedCurrency(key, params, exactInput);

        int128 unspecifiedAmount = _unspecifiedDelta(delta, params, exactInput);

        bool extract = tx.gasprice >= gasPriceThreshold;

        uint256 taken = 0;
        int128 hookDelta = 0;

        // A positive unspecified delta is output owed to the swapper.
        if (extract && unspecifiedAmount > 0) {
            taken = (uint256(uint128(unspecifiedAmount)) * extractionBps) / BPS;
            if (taken > 0) {
                hookDelta = int128(uint128(taken));
                // Realise the extraction now. Our delta goes negative here and the
                // returned `hookDelta` credits it back, netting to zero.
                poolManager.take(unspecified, address(this), taken);
            }
        }

        lastContext = ObservedContext({
            gasPrice: tx.gasprice,
            baseFee: block.basefee,
            origin: tx.origin,
            coinbase: block.coinbase,
            extracted: taken > 0,
            extractedAmount: taken
        });

        return (IHooks.afterSwap.selector, hookDelta);
    }

    function _unspecifiedCurrency(PoolKey calldata key, IPoolManager.SwapParams calldata params, bool exactInput)
        internal
        pure
        returns (Currency)
    {
        // zeroForOne: token0 in, token1 out.
        if (exactInput) {
            return params.zeroForOne ? key.currency1 : key.currency0;
        }
        return params.zeroForOne ? key.currency0 : key.currency1;
    }

    function _unspecifiedDelta(BalanceDelta delta, IPoolManager.SwapParams calldata params, bool exactInput)
        internal
        pure
        returns (int128)
    {
        if (exactInput) {
            return params.zeroForOne ? delta.amount1() : delta.amount0();
        }
        return params.zeroForOne ? delta.amount0() : delta.amount1();
    }
}
