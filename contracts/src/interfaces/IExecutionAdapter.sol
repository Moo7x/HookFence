// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IExecutionAdapter
/// @notice Narrow execution surface the gateway is allowed to call.
/// @dev Deliberately NOT a generic "execute(target, data)" interface. Every argument
///      is typed and checked; there is no field an attacker could use to redirect a
///      call. Adding a route requires an explicit owner action on the adapter.
interface IExecutionAdapter {
    /// @notice Perform one reviewed exact-input swap.
    /// @param key               Pool identity.
    /// @param zeroForOne        Swap direction within that pool.
    /// @param amountIn          Exact input to spend.
    /// @param tokenIn           Expected input token; must match the route.
    /// @param tokenOut          Expected output token; must match the route.
    /// @param recipient         Receives the output directly from the PoolManager.
    /// @param expectedRouteHash Route hash bound into the authorised intent.
    /// @return amountInSpent    Input actually consumed by the pool.
    /// @return amountOut        Output the adapter believes was produced. The gateway
    ///                          does not trust this and re-measures the recipient's
    ///                          real balance instead.
    function executeExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        address recipient,
        bytes32 expectedRouteHash
    ) external returns (uint256 amountInSpent, uint256 amountOut);
}
