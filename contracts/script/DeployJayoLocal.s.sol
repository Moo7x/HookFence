// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {DemoPriceFeed} from "../src/testnet/DemoPriceFeed.sol";
import {LiquiditySeeder} from "../src/mocks/LiquiditySeeder.sol";
import {StockTokenReferencePolicy} from "../src/policy/StockTokenReferencePolicy.sol";
import {ExecutionGateway} from "../src/core/ExecutionGateway.sol";
import {V4ExactInputAdapter} from "../src/adapters/V4ExactInputAdapter.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";
import {JayoRenderer} from "../src/basket/JayoRenderer.sol";

/// @title Local Jayo deployment
///
/// @notice Deploys the whole stack to a local chain with MOCK assets, so the
///         interface can drive the complete journey without touching mainnet.
///
/// @dev EVERY ASSET HERE IS A MOCK. The Stock Tokens are not Robinhood Stock
///      Tokens, the USDG is not Paxos USDG, and the price feeds are not Chainlink.
///      They reproduce the real surfaces (18-decimal ERC-8056 tokens, 6-decimal
///      USDG, 8-decimal feeds) so behaviour matches, but nothing here carries real
///      value. The interface labels this prominently and must continue to.
///
///      The `v4-core` PoolManager is the real implementation.
///
///      Pools are created WITHOUT hooks. The adversarial-hook fixtures belong to
///      the Phase 0 evidence; the product journey does not need them.
///
///      Usage:
///        anvil
///        forge script script/DeployJayoLocal.s.sol --rpc-url http://127.0.0.1:8545 \
///          --broadcast --private-key <anvil key 0>
contract DeployJayoLocal is Script {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;

    uint8 constant FEED_DECIMALS = 8;
    uint32 constant FEED_HEARTBEAT = 86_400;
    uint16 constant MAX_SHORTFALL_BPS = 50;
    uint16 constant FEED_MAX_STEP_BPS = 1000;

    int256 constant AAPL_USD = 255_00000000;
    int256 constant NVDA_USD = 150_00000000;
    int256 constant USDG_USD = 1_00000000;

    struct Deployed {
        PoolManager poolManager;
        MockUSDG usdg;
        MockStockToken aapl;
        MockStockToken nvda;
        DemoPriceFeed aaplFeed;
        DemoPriceFeed nvdaFeed;
        DemoPriceFeed usdgFeed;
        StockTokenReferencePolicy policy;
        ExecutionGateway gateway;
        V4ExactInputAdapter adapter;
        JayoBasket basket;
        LiquiditySeeder seeder;
    }

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk == 0 ? msg.sender : vm.addr(pk);

        if (pk == 0) vm.startBroadcast();
        else vm.startBroadcast(pk);

        Deployed memory d = _deployCore(deployer);
        PoolKey memory aaplKey = _setUpMarket(d, d.aapl, d.aaplFeed, AAPL_USD, deployer);
        PoolKey memory nvdaKey = _setUpMarket(d, d.nvda, d.nvdaFeed, NVDA_USD, deployer);
        _wireBasket(d, aaplKey, nvdaKey);

        // Demo funding for the first few anvil accounts.
        for (uint256 i; i < 3; ++i) {
            d.usdg.mint(vm.addr(uint256(keccak256(abi.encode("anvil", i)))), 0);
        }
        d.usdg.mint(deployer, 1_000_000e6);

        vm.stopBroadcast();

        _writeAddresses(d, aaplKey, nvdaKey, deployer);
    }

    function _deployCore(address deployer) internal returns (Deployed memory d) {
        d.poolManager = new PoolManager(deployer);
        d.seeder = new LiquiditySeeder(IPoolManager(address(d.poolManager)));

        d.usdg = new MockUSDG();
        d.aapl = new MockStockToken("Apple  Robinhood Token [MOCK]", "AAPL");
        d.nvda = new MockStockToken("Nvidia  Robinhood Token [MOCK]", "NVDA");

        // Same access-controlled feed the testnet uses, so the demo panel's
        // "Refresh prices" exercises the real permission model rather than an
        // open setter. The deployer is owner and updater.
        d.aaplFeed = new DemoPriceFeed(FEED_DECIMALS, AAPL_USD, "MOCK AAPL / USD", deployer, FEED_MAX_STEP_BPS, 0, 0);
        d.nvdaFeed = new DemoPriceFeed(FEED_DECIMALS, NVDA_USD, "MOCK NVDA / USD", deployer, FEED_MAX_STEP_BPS, 0, 0);
        d.usdgFeed = new DemoPriceFeed(FEED_DECIMALS, USDG_USD, "MOCK USDG / USD", deployer, FEED_MAX_STEP_BPS, 0, 0);

        d.policy = new StockTokenReferencePolicy(keccak256("Jayo.StockTokenBasket.v1"), deployer);
        d.policy.setQuoteAsset(address(d.usdg), address(d.usdgFeed), FEED_HEARTBEAT, 6);

        d.gateway = new ExecutionGateway(deployer, d.policy);
        d.adapter = new V4ExactInputAdapter(IPoolManager(address(d.poolManager)), deployer);
        d.adapter.setGateway(address(d.gateway));
        d.gateway.setAdapter(address(d.adapter), true);

        d.basket = new JayoBasket(d.gateway, IERC20(address(d.usdg)), deployer, 1);
        // No update interval or daily band on the local feeds above: the demo panel
        // moves time and prices by hand, which those bounds exist to prevent.
        d.basket.setRenderer(new JayoRenderer("http://127.0.0.1:5173", "Local demo chain: mock assets with no value."));
    }

    /// @dev Creates the pool, seeds it, and registers the instrument.
    function _setUpMarket(
        Deployed memory d,
        MockStockToken stock,
        DemoPriceFeed feed,
        int256 priceUsd,
        address deployer
    ) internal returns (PoolKey memory key) {
        bool stockIsCurrency0 = address(stock) < address(d.usdg);
        (Currency c0, Currency c1) = stockIsCurrency0
            ? (Currency.wrap(address(stock)), Currency.wrap(address(d.usdg)))
            : (Currency.wrap(address(d.usdg)), Currency.wrap(address(stock)));

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // no hook: the product journey does not need one
        });

        uint256 rawStock = 1e18;
        uint256 rawUsdg = uint256(priceUsd) * 1e6 / (10 ** FEED_DECIMALS);
        (uint256 a0, uint256 a1) = stockIsCurrency0 ? (rawStock, rawUsdg) : (rawUsdg, rawStock);
        uint160 sqrtPrice = _encodeSqrtPriceX96(a1, a0);

        d.poolManager.initialize(key, sqrtPrice);

        uint256 stockAmount = 200_000e18;
        uint256 usdgAmount = 200_000 * uint256(priceUsd) / (10 ** FEED_DECIMALS) * 1e6;
        stock.mint(deployer, stockAmount * 2);
        d.usdg.mint(deployer, usdgAmount * 2);

        stock.approve(address(d.seeder), type(uint256).max);
        d.usdg.approve(address(d.seeder), type(uint256).max);

        (uint256 amt0, uint256 amt1) = stockIsCurrency0 ? (stockAmount, usdgAmount) : (usdgAmount, stockAmount);
        d.seeder.addLiquidity(
            key, TICK_LOWER, TICK_UPPER, int256(uint256(_liquidityForAmounts(sqrtPrice, amt0, amt1)))
        );

        d.policy.setStockToken(address(stock), address(feed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        // Buying the stock with USDG is the opposite direction to selling it.
        bool buyDirection = !stockIsCurrency0;
        d.adapter.setRoute(key, buyDirection, true);
        d.adapter.setRoute(key, stockIsCurrency0, true); // sell direction too
    }

    function _wireBasket(Deployed memory d, PoolKey memory aaplKey, PoolKey memory nvdaKey) internal {
        d.basket.setAssetRoute(address(d.aapl), aaplKey, !(address(d.aapl) < address(d.usdg)), address(d.adapter), true);
        d.basket.setAssetRoute(address(d.nvda), nvdaKey, !(address(d.nvda) < address(d.usdg)), address(d.adapter), true);
    }

    function _encodeSqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
    }

    function _liquidityForAmounts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint256 intermediate = Math.mulDiv(sqrtPriceX96, sqrtUpper, 1 << 96);
        uint256 l0 = Math.mulDiv(amount0, intermediate, sqrtUpper - sqrtPriceX96);
        uint256 l1 = Math.mulDiv(amount1, 1 << 96, sqrtPriceX96 - sqrtLower);
        return uint128(l0 < l1 ? l0 : l1);
    }

    function _writeAddresses(Deployed memory d, PoolKey memory aaplKey, PoolKey memory nvdaKey, address deployer)
        internal
    {
        string memory j = "jayo";
        vm.serializeString(j, "network", "local-anvil");
        vm.serializeString(j, "warning", "ALL ASSETS ARE MOCKS. Not Robinhood Stock Tokens, not Paxos USDG, not Chainlink feeds.");
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeAddress(j, "poolManager", address(d.poolManager));
        vm.serializeAddress(j, "usdg", address(d.usdg));
        vm.serializeAddress(j, "aapl", address(d.aapl));
        vm.serializeAddress(j, "nvda", address(d.nvda));
        vm.serializeAddress(j, "aaplFeed", address(d.aaplFeed));
        vm.serializeAddress(j, "nvdaFeed", address(d.nvdaFeed));
        vm.serializeAddress(j, "usdgFeed", address(d.usdgFeed));
        vm.serializeAddress(j, "policy", address(d.policy));
        vm.serializeAddress(j, "gateway", address(d.gateway));
        vm.serializeAddress(j, "adapter", address(d.adapter));
        // Generic asset list: the interface should not have to know tickers to
        // render a deployment, and the testnet one holds different ones.
        address[] memory stocks = new address[](2);
        stocks[0] = address(d.aapl);
        stocks[1] = address(d.nvda);
        vm.serializeAddress(j, "stocks", stocks);
        vm.serializeBool(j, "demoControls", true);
        vm.serializeUint(j, "feedHeartbeat", FEED_HEARTBEAT);
        vm.serializeUint(j, "maxShortfallBps", MAX_SHORTFALL_BPS);
        vm.serializeString(j, "priceSource", "demo");
        string memory out = vm.serializeAddress(j, "basket", address(d.basket));

        vm.writeJson(out, "./reports/jayo-local.json");
        // Also written to a fixed path so the interface fetches exactly one
        // file and never has to probe-and-404 its way to the right network.
        vm.writeJson(out, "./reports/jayo-deployment.json");

        console2.log("");
        console2.log("=== Jayo deployed locally (ALL ASSETS ARE MOCKS) ===");
        console2.log("  basket  :", address(d.basket));
        console2.log("  gateway :", address(d.gateway));
        console2.log("  policy  :", address(d.policy));
        console2.log("  usdg    :", address(d.usdg));
        console2.log("  aapl    :", address(d.aapl));
        console2.log("  nvda    :", address(d.nvda));
        console2.log("  addresses written to contracts/reports/jayo-local.json");
        // Silence unused-variable warnings for the keys; they are recorded by the
        // basket's own route configuration.
        aaplKey;
        nvdaKey;
    }
}
