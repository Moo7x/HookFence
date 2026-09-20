// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTestHook} from "./BaseTestHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title HonestHook
/// @notice TEST FIXTURE. Control hook: identical permissions to ContextSensitiveHook,
///         but never extracts and never varies with execution context.
/// @dev Deployed at an address carrying the SAME flag bits as the adversarial hook so
///      that path D differs from path C only in hook behaviour, not in pool shape,
///      permissions or gas profile. Without that, a "HookFence does not block honest
///      trades" claim would be comparing two different pools.
contract HonestHook is BaseTestHook {
    struct ObservedContext {
        uint256 gasPrice;
        uint256 baseFee;
        address origin;
        address coinbase;
        bool extracted;
        uint256 extractedAmount;
    }

    ObservedContext public lastContext;

    constructor(IPoolManager poolManager_) BaseTestHook(poolManager_) {}

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        lastContext = ObservedContext({
            gasPrice: tx.gasprice,
            baseFee: block.basefee,
            origin: tx.origin,
            coinbase: block.coinbase,
            extracted: false,
            extractedAmount: 0
        });
        return (IHooks.afterSwap.selector, int128(0));
    }
}
