// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {DeployJayoTestnet} from "./DeployJayoTestnet.s.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";
import {JayoRenderer} from "../src/basket/JayoRenderer.sol";
import {ExecutionGateway} from "../src/core/ExecutionGateway.sol";
import {StockTokenReferencePolicy} from "../src/policy/StockTokenReferencePolicy.sol";
import {DemoPriceFeed} from "../src/testnet/DemoPriceFeed.sol";
import {PoolPriceReader} from "../src/testnet/PoolPriceReader.sol";

/// @title Deploy JayoBasket version 2 beside the live version 1
///
/// @notice Reuses the live gateway, policy and adapter (the gateway accepts any
///         contract settling on its own behalf, so a second basket needs no
///         change there). Deploys:
///
///           - JayoBasket v2, whose ids start at 101 so a number names one position
///             across both contracts, and its renderer;
///           - three version-2 demo feeds (interval and daily band) seeded from the
///             pools, handed to the dedicated UPDATER_ADDRESS, and switched into
///             the policy - which both baskets read, so version 1 buys against the
///             same bounded feeds.
///
///         Version 1 is not touched: its positions stay withdrawable and
///         transferable. Its address is recorded as `legacyBasket`.
///
///         PRIVATE_KEY (the deployer, owner of the policy) signs; UPDATER_ADDRESS
///         must be set, and receives UPDATER_FUNDING of test ETH for its gas.
contract DeployJayoV2Testnet is DeployJayoTestnet {
    uint256 constant FIRST_V2_TOKEN_ID = 101;
    uint256 constant UPDATER_FUNDING = 0.002 ether;

    struct V2 {
        JayoBasket basket;
        JayoRenderer renderer;
        DemoPriceFeed tslaFeed;
        DemoPriceFeed amznFeed;
        DemoPriceFeed usdgFeed;
        address updater;
    }

    function run() external override {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain testnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address updater = vm.envAddress("UPDATER_ADDRESS");
        require(updater != deployer, "the updater must be a separate key");

        string memory v1 = vm.readFile("./reports/jayo-testnet.json");
        StockTokenReferencePolicy policy = StockTokenReferencePolicy(vm.parseJsonAddress(v1, ".policy"));
        ExecutionGateway gateway = ExecutionGateway(vm.parseJsonAddress(v1, ".gateway"));
        address adapter = vm.parseJsonAddress(v1, ".adapter");
        require(policy.owner() == deployer && gateway.owner() == deployer, "PRIVATE_KEY does not own the live deployment");
        require(address(gateway.policy()) == address(policy), "the gateway reads a different policy");

        int256 tslaUsd = int256(PoolPriceReader.usdPrice8(IPoolManager(POOL_MANAGER), _key(TSLA), RUSDG < TSLA));
        int256 amznUsd = int256(PoolPriceReader.usdPrice8(IPoolManager(POOL_MANAGER), _key(AMZN), RUSDG < AMZN));
        require(tslaUsd > 0 && amznUsd > 0, "a pool has no price");

        vm.startBroadcast(pk);
        V2 memory d;
        d.updater = updater;
        (d.tslaFeed, d.amznFeed, d.usdgFeed) = _deployFeeds(deployer, tslaUsd, amznUsd);
        d.tslaFeed.setUpdater(updater);
        d.amznFeed.setUpdater(updater);
        d.usdgFeed.setUpdater(updater);

        policy.setQuoteAsset(RUSDG, address(d.usdgFeed), FEED_HEARTBEAT, 6);
        policy.setStockToken(TSLA, address(d.tslaFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
        policy.setStockToken(AMZN, address(d.amznFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        d.basket = new JayoBasket(gateway, IERC20(RUSDG), deployer, FIRST_V2_TOKEN_ID);
        d.renderer = new JayoRenderer(SITE_URL, NETWORK_NOTE);
        d.basket.setRenderer(d.renderer);
        d.basket.setAssetRoute(TSLA, _key(TSLA), RUSDG < TSLA, adapter, true);
        d.basket.setAssetRoute(AMZN, _key(AMZN), RUSDG < AMZN, adapter, true);

        (bool sent,) = updater.call{value: UPDATER_FUNDING}("");
        require(sent, "could not fund the updater");
        vm.stopBroadcast();

        _reportV2(v1, d);
    }

    function _reportV2(string memory v1, V2 memory d) internal {
        string memory j = "jayo-v2";
        vm.serializeString(j, "network", "robinhood-chain-testnet");
        vm.serializeString(
            j,
            "warning",
            "PoolManager, TSLA, AMZN, rUSDG and both pools are real chain state we did not deploy. The three price feeds are ours (DemoPriceFeed v2: a dedicated updater key, 15-minute interval, 10% step, 25% daily band, 1h heartbeat) and copy the pools own price: Chainlink publishes no feeds on this testnet."
        );
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", vm.parseJsonAddress(v1, ".deployer"));
        vm.serializeAddress(j, "updater", d.updater);
        vm.serializeAddress(j, "poolManager", POOL_MANAGER);
        vm.serializeAddress(j, "usdg", RUSDG);
        vm.serializeAddress(j, "tsla", TSLA);
        vm.serializeAddress(j, "amzn", AMZN);
        vm.serializeAddress(j, "tslaFeed", address(d.tslaFeed));
        vm.serializeAddress(j, "amznFeed", address(d.amznFeed));
        vm.serializeAddress(j, "usdgFeed", address(d.usdgFeed));
        vm.serializeAddress(j, "policy", vm.parseJsonAddress(v1, ".policy"));
        vm.serializeAddress(j, "gateway", vm.parseJsonAddress(v1, ".gateway"));
        vm.serializeAddress(j, "adapter", vm.parseJsonAddress(v1, ".adapter"));
        address[] memory stocks = new address[](2);
        stocks[0] = TSLA;
        stocks[1] = AMZN;
        vm.serializeAddress(j, "stocks", stocks);
        vm.serializeBool(j, "demoControls", false);
        vm.serializeString(j, "rpcUrl", "https://rpc.testnet.chain.robinhood.com");
        vm.serializeAddress(j, "multicall3", 0xcA11bde05977b3631167028862bE2a173976CA11);
        vm.serializeString(j, "explorer", "https://explorer.testnet.chain.robinhood.com");
        vm.serializeUint(j, "suggestedFund", DEFAULT_FUND);
        vm.serializeUint(j, "feedHeartbeat", FEED_HEARTBEAT);
        vm.serializeUint(j, "feedMinInterval", FEED_MIN_INTERVAL);
        vm.serializeUint(j, "maxShortfallBps", MAX_SHORTFALL_BPS);
        vm.serializeString(j, "priceSource", "pool");
        vm.serializeUint(j, "firstTokenId", FIRST_V2_TOKEN_ID);
        vm.serializeAddress(j, "legacyBasket", vm.parseJsonAddress(v1, ".basket"));
        vm.serializeAddress(j, "renderer", address(d.renderer));
        string memory out = vm.serializeAddress(j, "basket", address(d.basket));
        vm.writeJson(out, "./reports/jayo-testnet-v2.json");

        console2.log("basket v2 ", address(d.basket));
        console2.log("renderer  ", address(d.renderer));
        console2.log("TSLA feed ", address(d.tslaFeed));
        console2.log("AMZN feed ", address(d.amznFeed));
        console2.log("rUSDG feed", address(d.usdgFeed));
    }
}
