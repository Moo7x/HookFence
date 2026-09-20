// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {HonestHook} from "../../src/mocks/HonestHook.sol";
import {ContextSensitiveHook} from "../../src/mocks/ContextSensitiveHook.sol";
import {BaselineOracleRouter} from "../../src/mocks/BaselineOracleRouter.sol";

import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {V4ExactInputAdapter} from "../../src/adapters/V4ExactInputAdapter.sol";
import {ReferenceVault} from "../../src/integrations/ReferenceVault.sol";

import {TestLiquidityRouter} from "./TestLiquidityRouter.sol";

/// @notice Shared harness: a Stock Token / USDG v4 market with an honest pool and a
///         context-sensitive pool, wired to HookFence and to the baseline router.
///
/// @dev The two pools are identical in every respect except which hook they carry,
///      and both hooks are deployed at addresses with the SAME permission flags. A
///      comparison between them therefore isolates hook behaviour rather than pool
///      shape, fee tier or hook permissions.
abstract contract HookFenceFixture is Test {
    // --- Reference values, taken from live Robinhood Chain mainnet on 2026-09-20 ---

    /// @dev Stock Tokens are 18 decimals.
    uint8 internal constant STOCK_DECIMALS = 18;
    /// @dev USDG is 6 decimals (0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168).
    uint8 internal constant USDG_DECIMALS = 6;
    /// @dev Chainlink feeds on Robinhood Chain report 8 decimals, heartbeat 86400s.
    uint8 internal constant FEED_DECIMALS = 8;
    uint32 internal constant FEED_HEARTBEAT = 86_400;

    /// @dev $255.00 per AAPL token, 8 decimals.
    int256 internal constant AAPL_USD = 255_00000000;
    /// @dev $1.00 per USDG, 8 decimals.
    int256 internal constant USDG_USD = 1_00000000;

    /// @dev Permitted shortfall vs the independent reference: 50 bps.
    uint16 internal constant MAX_SHORTFALL_BPS = 50;

    bytes32 internal constant POLICY_ID = keccak256("HookFence.StockTokenToUSDG.v1");

    // --- Actors -------------------------------------------------------------
    address internal admin = makeAddr("admin");
    address internal lp = makeAddr("lp");
    address internal trader;
    uint256 internal traderKey;

    // --- Core contracts -----------------------------------------------------
    PoolManager internal poolManager;
    MockStockToken internal stock;
    MockUSDG internal usdg;
    MockAggregatorV3 internal stockFeed;
    MockAggregatorV3 internal usdgFeed;

    HonestHook internal honestHook;
    ContextSensitiveHook internal adversarialHook;

    StockTokenReferencePolicy internal policy;
    ExecutionGateway internal gateway;
    V4ExactInputAdapter internal adapter;
    BaselineOracleRouter internal baselineRouter;
    ReferenceVault internal vault;
    TestLiquidityRouter internal liquidityRouter;

    // --- Pools --------------------------------------------------------------
    PoolKey internal honestKey;
    PoolKey internal adversarialKey;
    /// @notice True when the Stock Token sorted below USDG, so selling is zeroForOne.
    bool internal stockIsCurrency0;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Hook permissions used by BOTH hooks: afterSwap + afterSwapReturnsDelta.
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    /// @dev Gas price the adversarial hook treats as "this is a real transaction".
    uint256 internal constant EXTRACTION_GAS_PRICE_THRESHOLD = 1 gwei;
    /// @dev Output the adversarial hook skims once it decides it is being mined.
    uint256 internal constant EXTRACTION_BPS = 120; // 1.2%

    function setUp() public virtual {
        (trader, traderKey) = makeAddrAndKey("trader");

        vm.warp(1_790_000_000); // a plausible 2026 timestamp

        poolManager = new PoolManager(admin);
        liquidityRouter = new TestLiquidityRouter(IPoolManager(address(poolManager)));
        baselineRouter = new BaselineOracleRouter(IPoolManager(address(poolManager)));

        stock = new MockStockToken("Apple  Robinhood Token", "AAPL");
        usdg = new MockUSDG();
        stockIsCurrency0 = address(stock) < address(usdg);

        stockFeed = new MockAggregatorV3(FEED_DECIMALS, AAPL_USD, "Robinhood AAPL / USD");
        usdgFeed = new MockAggregatorV3(FEED_DECIMALS, USDG_USD, "USDG / USD");

        _deployHooks();
        _initialisePools();
        _deployHookFence();
        _seedLiquidity();
    }

    // -----------------------------------------------------------------------
    // Setup steps
    // -----------------------------------------------------------------------

    function _deployHooks() internal {
        // v4 encodes hook permissions in the hook's address. Place both hooks at
        // addresses carrying identical flags so path C and path D differ only in
        // behaviour.
        address honestAddr = address(uint160(0x4000) | HOOK_FLAGS);
        address advAddr = address(uint160(0x8000) | HOOK_FLAGS);

        deployCodeTo("HonestHook.sol:HonestHook", abi.encode(IPoolManager(address(poolManager))), honestAddr);
        deployCodeTo(
            "ContextSensitiveHook.sol:ContextSensitiveHook",
            abi.encode(IPoolManager(address(poolManager)), EXTRACTION_GAS_PRICE_THRESHOLD, EXTRACTION_BPS),
            advAddr
        );

        honestHook = HonestHook(honestAddr);
        adversarialHook = ContextSensitiveHook(advAddr);
    }

    function _initialisePools() internal {
        honestKey = _buildKey(IHooks(address(honestHook)));
        adversarialKey = _buildKey(IHooks(address(adversarialHook)));

        uint160 sqrtPrice = _initialSqrtPriceX96();
        poolManager.initialize(honestKey, sqrtPrice);
        poolManager.initialize(adversarialKey, sqrtPrice);
    }

    function _buildKey(IHooks hooks) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = stockIsCurrency0
            ? (Currency.wrap(address(stock)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock)));
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: hooks});
    }

    /// @dev v4 prices are ratios of RAW token units, so the 18-vs-6 decimal gap shows
    ///      up here directly: 1e18 raw stock is worth 255e6 raw USDG.
    function _initialSqrtPriceX96() internal view returns (uint160) {
        uint256 rawStock = 10 ** STOCK_DECIMALS;
        uint256 rawUsdg = uint256(AAPL_USD) * (10 ** USDG_DECIMALS) / uint256(uint256(10) ** FEED_DECIMALS);
        (uint256 amount0, uint256 amount1) =
            stockIsCurrency0 ? (rawStock, rawUsdg) : (rawUsdg, rawStock);
        return _encodeSqrtPriceX96(amount1, amount0);
    }

    /// @dev sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96, in full precision.
    function _encodeSqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        uint256 ratioX192 = Math.mulDiv(amount1, 1 << 192, amount0);
        return uint160(Math.sqrt(ratioX192));
    }

    function _deployHookFence() internal {
        vm.startPrank(admin);

        policy = new StockTokenReferencePolicy(POLICY_ID, admin);
        policy.setStockToken(address(stock), address(stockFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
        policy.setQuoteAsset(address(usdg), address(usdgFeed), FEED_HEARTBEAT, USDG_DECIMALS);

        gateway = new ExecutionGateway(admin, policy);
        adapter = new V4ExactInputAdapter(IPoolManager(address(poolManager)), admin);
        adapter.setGateway(address(gateway));
        gateway.setAdapter(address(adapter), true);

        // Only the adversarial route is enabled by default; tests that want the
        // honest control pool enable it explicitly.
        adapter.setRoute(adversarialKey, _zeroForOne(), true);
        adapter.setRoute(honestKey, _zeroForOne(), true);

        vault = new ReferenceVault(gateway, IERC20(address(usdg)), admin);

        vm.stopPrank();
    }

    /// @dev Full-range tick bounds aligned to TICK_SPACING (60).
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    function _seedLiquidity() internal {
        // Deep enough that a 10-100 token trade barely moves the price, so the
        // adversarial hook's extraction is not drowned out by price impact.
        uint256 stockAmount = 40_000e18;
        uint256 usdgAmount = 40_000 * 255 * 1e6;

        // Each pool gets its own liquidity, so mint twice over plus headroom.
        stock.mint(lp, stockAmount * 4);
        usdg.mint(lp, usdgAmount * 4);

        vm.startPrank(lp);
        stock.approve(address(liquidityRouter), type(uint256).max);
        usdg.approve(address(liquidityRouter), type(uint256).max);

        (uint256 amount0, uint256 amount1) =
            stockIsCurrency0 ? (stockAmount, usdgAmount) : (usdgAmount, stockAmount);
        int256 liquidity = int256(uint256(_liquidityForAmounts(_initialSqrtPriceX96(), amount0, amount1)));

        liquidityRouter.addLiquidity(honestKey, TICK_LOWER, TICK_UPPER, liquidity);
        liquidityRouter.addLiquidity(adversarialKey, TICK_LOWER, TICK_UPPER, liquidity);
        vm.stopPrank();
    }

    /// @dev Largest liquidity affordable with both amounts at the current price.
    ///      Computed rather than hardcoded so the harness is correct whichever way
    ///      the two token addresses happen to sort - the 18-vs-6 decimal gap makes
    ///      the two orderings differ by ~1e9 in liquidity units.
    function _liquidityForAmounts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);

        // L such that amount0 covers [current, upper]
        uint256 intermediate = Math.mulDiv(sqrtPriceX96, sqrtUpper, 1 << 96);
        uint256 l0 = Math.mulDiv(amount0, intermediate, sqrtUpper - sqrtPriceX96);

        // L such that amount1 covers [lower, current]
        uint256 l1 = Math.mulDiv(amount1, 1 << 96, sqrtPriceX96 - sqrtLower);

        return uint128(l0 < l1 ? l0 : l1);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @notice Selling the Stock Token means going from stock to USDG.
    function _zeroForOne() internal view returns (bool) {
        return stockIsCurrency0;
    }

    function _routeHash(PoolKey memory key) internal view returns (bytes32) {
        return keccak256(abi.encode(key, _zeroForOne()));
    }

    function _giveTrader(uint256 stockAmount) internal {
        stock.mint(trader, stockAmount);
    }

    /// @notice Republish both feeds at the current block timestamp.
    function _refreshFeeds() internal {
        stockFeed.setAnswer(AAPL_USD);
        usdgFeed.setAnswer(USDG_USD);
    }

    function _buildIntent(
        address owner_,
        address recipient,
        uint256 amountIn,
        uint256 userMinOut,
        PoolKey memory key,
        uint256 nonce
    ) internal view returns (ExecutionGateway.ExecutionIntent memory) {
        return ExecutionGateway.ExecutionIntent({
            chainId: block.chainid,
            gateway: address(gateway),
            owner: owner_,
            recipient: recipient,
            tokenIn: address(stock),
            tokenOut: address(usdg),
            amountIn: amountIn,
            userMinOut: userMinOut,
            adapter: address(adapter),
            routeHash: _routeHash(key),
            policy: address(policy),
            policyId: POLICY_ID,
            policyVersion: policy.policyVersion(),
            configEpoch: gateway.configEpoch(),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }
}
