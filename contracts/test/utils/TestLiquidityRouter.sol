// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice TEST ONLY. Minimal router used to seed pool liquidity in the harness.
/// @dev Deliberately hand-rolled so the fixtures do not depend on v4-periphery.
contract TestLiquidityRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    error OnlyPoolManager();

    IPoolManager public immutable poolManager;

    struct CallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        address payer;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        key: key,
                        params: IPoolManager.ModifyLiquidityParams({
                            tickLower: tickLower,
                            tickUpper: tickUpper,
                            liquidityDelta: liquidityDelta,
                            salt: bytes32(0)
                        }),
                        payer: msg.sender
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, data.params, "");

        _settleOrTake(data.key.currency0, delta.amount0(), data.payer);
        _settleOrTake(data.key.currency1, delta.amount1(), data.payer);

        return abi.encode(delta);
    }

    function _settleOrTake(Currency currency, int128 amount, address payer) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), owed);
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, payer, uint256(uint128(amount)));
        }
    }
}
