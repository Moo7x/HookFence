// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title BaselineOracleRouter
/// @notice BASELINE B. An ordinary exact-input Uniswap v4 router that enforces a
///         caller-supplied `minAmountOut` and nothing else.
///
/// @dev This contract exists to keep us honest.
///
///      The temptation in a project like this is to compare against a weak baseline
///      - a router with a 2% quote-derived slippage bound - and declare victory.
///      That comparison would be dishonest, because the thing doing the work is the
///      *independent oracle floor*, not the gateway around it.
///
///      So the A/B/C/D harness hands this router the exact same oracle-derived floor
///      that `StockTokenReferencePolicy` computes for HookFence. It is expected, and
///      asserted in `test/spike/BaselineComparison.t.sol`, that B and C reject an
///      identical below-floor fill. HookFence must earn its keep somewhere else: in
///      the checks a bare minimum-output bound cannot express (feed validity, issuer
///      pause, corporate-action timing, unit handling, intent authenticity, real
///      recipient accounting) and in not requiring every integrator to rebuild them.
contract BaselineOracleRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    error OnlyPoolManager();
    error InsufficientOutput(uint256 received, uint256 minAmountOut);
    error NegativeOutput(int128 amount);

    IPoolManager public immutable poolManager;

    struct CallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address payer;
        address recipient;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Ordinary exact-input swap with a minimum-output bound.
    /// @param minAmountOut Whatever bound the caller chose. Path A passes a
    ///        quote-derived number; path B passes the oracle-derived floor.
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        key: key,
                        zeroForOne: zeroForOne,
                        amountIn: amountIn,
                        payer: msg.sender,
                        recipient: recipient
                    })
                )
            ),
            (uint256)
        );

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        Currency currencyIn = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency currencyOut = data.zeroForOne ? data.key.currency1 : data.key.currency0;

        BalanceDelta delta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inDelta = data.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = data.zeroForOne ? delta.amount1() : delta.amount0();
        if (outDelta < 0) revert NegativeOutput(outDelta);

        uint256 amountInSpent = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));

        poolManager.sync(currencyIn);
        IERC20(Currency.unwrap(currencyIn)).safeTransfer(address(poolManager), amountInSpent);
        poolManager.settle();

        if (amountOut > 0) {
            poolManager.take(currencyOut, data.recipient, amountOut);
        }

        return abi.encode(amountOut);
    }
}
