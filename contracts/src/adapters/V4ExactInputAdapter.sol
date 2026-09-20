// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IExecutionAdapter} from "../interfaces/IExecutionAdapter.sol";

/// @title V4ExactInputAdapter
/// @notice The only execution surface HookFence exposes: one reviewed, single-hop,
///         exact-input Uniswap v4 swap.
///
/// @dev Intentional limits, all of which are tested:
///
///      - No arbitrary call. There is no `target`/`calldata` parameter anywhere in
///        this contract, and no `delegatecall`. The adapter can do exactly one thing.
///      - No generic approval surface. The adapter never grants an allowance; it
///        pulls a bounded amount from the gateway and pays the PoolManager directly.
///      - Route allowlist. A (PoolKey, direction) pair must be enabled by the owner
///        before it can be used, and the gateway independently binds the route hash
///        into the signed intent. Both must agree.
///      - Caller allowlist. Only the configured gateway may execute.
///
///      The adapter reports what actually happened (input spent, output produced).
///      It does NOT decide whether that is acceptable - the gateway re-measures
///      against the recipient's real balance and enforces the policy floor. The
///      adapter is deliberately not trusted to report honestly.
contract V4ExactInputAdapter is Ownable2Step, IExecutionAdapter, IUnlockCallback {
    using SafeERC20 for IERC20;

    error OnlyGateway();
    error OnlyPoolManager();
    error RouteNotAllowed(bytes32 routeHash);
    error RouteHashMismatch(bytes32 expected, bytes32 actual);
    error UnexpectedTokenIn(address expected, address actual);
    error UnexpectedTokenOut(address expected, address actual);
    error ZeroAddress();
    error AmountTooLarge(uint256 amountIn);
    error NegativeOutput(int128 amount);

    event RouteConfigured(bytes32 indexed routeHash, bool allowed);
    event GatewayConfigured(address indexed gateway);

    IPoolManager public immutable poolManager;

    /// @notice The single contract permitted to call `executeExactInput`.
    address public gateway;

    /// @notice Reviewed (PoolKey, direction) routes.
    mapping(bytes32 => bool) public allowedRoutes;

    /// @dev Decoded payload handed to the unlock callback.
    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
    }

    // -----------------------------------------------------------------------
    // Administration
    // -----------------------------------------------------------------------

    function setGateway(address gateway_) external onlyOwner {
        if (gateway_ == address(0)) revert ZeroAddress();
        gateway = gateway_;
        emit GatewayConfigured(gateway_);
    }

    function setRoute(PoolKey calldata key, bool zeroForOne, bool allowed) external onlyOwner {
        bytes32 h = routeHash(key, zeroForOne);
        allowedRoutes[h] = allowed;
        emit RouteConfigured(h, allowed);
    }

    /// @notice Canonical route identity. The gateway binds this into the intent.
    function routeHash(PoolKey calldata key, bool zeroForOne) public pure returns (bytes32) {
        return keccak256(abi.encode(key, zeroForOne));
    }

    // -----------------------------------------------------------------------
    // Execution
    // -----------------------------------------------------------------------

    /// @inheritdoc IExecutionAdapter
    function executeExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        address recipient,
        bytes32 expectedRouteHash
    ) external returns (uint256 amountInSpent, uint256 amountOut) {
        if (msg.sender != gateway) revert OnlyGateway();
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge(amountIn);

        _validateRoute(key, zeroForOne, tokenIn, tokenOut, expectedRouteHash);

        // Pull exactly the intended amount from the gateway. The gateway grants an
        // allowance of exactly `amountIn` and revokes it immediately afterwards.
        IERC20(tokenIn).safeTransferFrom(gateway, address(this), amountIn);

        (amountInSpent, amountOut) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    SwapCallbackData({key: key, zeroForOne: zeroForOne, amountIn: amountIn, recipient: recipient})
                )
            ),
            (uint256, uint256)
        );

        _refundLeftover(tokenIn);
    }

    /// @dev Route identity and asset-pair checks, split out to keep
    ///      `executeExactInput` within the stack limit.
    function _validateRoute(
        PoolKey calldata key,
        bool zeroForOne,
        address tokenIn,
        address tokenOut,
        bytes32 expectedRouteHash
    ) internal view {
        bytes32 h = routeHash(key, zeroForOne);
        if (h != expectedRouteHash) revert RouteHashMismatch(expectedRouteHash, h);
        if (!allowedRoutes[h]) revert RouteNotAllowed(h);

        // The route fixes which currency is which; verify it is the pair the
        // gateway priced, so a re-pointed route cannot silently swap a
        // different asset.
        address routeIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address routeOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        if (routeIn != tokenIn) revert UnexpectedTokenIn(tokenIn, routeIn);
        if (routeOut != tokenOut) revert UnexpectedTokenOut(tokenOut, routeOut);
    }

    /// @dev Return any input the pool did not consume. The gateway reconciles this
    ///      against the owner's balance rather than trusting the number.
    function _refundLeftover(address tokenIn) internal {
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
        if (leftover > 0) {
            IERC20(tokenIn).safeTransfer(gateway, leftover);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        Currency currencyIn = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency currencyOut = data.zeroForOne ? data.key.currency1 : data.key.currency0;

        BalanceDelta delta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                // Negative == exact input.
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inDelta = data.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = data.zeroForOne ? delta.amount1() : delta.amount0();

        // A hook with AFTER_SWAP_RETURNS_DELTA can reduce the output. If it takes
        // more than the whole output, `outDelta` can go negative - do not cast that
        // to an unsigned amount.
        if (outDelta < 0) revert NegativeOutput(outDelta);

        uint256 amountInSpent = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));

        // Pay the pool what we owe.
        poolManager.sync(currencyIn);
        IERC20(Currency.unwrap(currencyIn)).safeTransfer(address(poolManager), amountInSpent);
        poolManager.settle();

        // Send output straight to the recipient - the adapter never custodies it.
        if (amountOut > 0) {
            poolManager.take(currencyOut, data.recipient, amountOut);
        }

        return abi.encode(amountInSpent, amountOut);
    }
}
