// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {DeployJayoTestnet} from "./DeployJayoTestnet.s.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";
import {JayoRenderer} from "../src/basket/JayoRenderer.sol";
import {ExecutionGateway} from "../src/core/ExecutionGateway.sol";

/// @title Deploy JayoBasket version 3 beside versions 1 and 2
///
/// @notice Version 3 binds every addition to the owner the contributor saw (the
///         race found in review: a version-2 contribution mined after a
///         hand-over reached the new owner) and adds in-kind starting and adding.
///
///         Reuses the live gateway, policy, adapter and version-2 feeds. Deploys
///         version 3 with ids from 201 and its renderer, then makes version 2
///         withdraw-only exactly as version 1 was: its purchase routes are
///         disabled, while every withdrawal and hand-over keeps working.
///         Version 2's two baskets (#101, #102) stay listed and withdrawable.
contract DeployJayoV3Testnet is DeployJayoTestnet {
    uint256 constant FIRST_V3_TOKEN_ID = 201;

    function run() external override {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain testnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory v2r = vm.readFile("./reports/jayo-testnet-v2.json");
        ExecutionGateway gateway = ExecutionGateway(vm.parseJsonAddress(v2r, ".gateway"));
        address adapter = vm.parseJsonAddress(v2r, ".adapter");
        JayoBasket v2 = JayoBasket(vm.parseJsonAddress(v2r, ".basket"));
        require(v2.owner() == deployer && gateway.owner() == deployer, "PRIVATE_KEY does not own the live deployment");

        vm.startBroadcast(pk);
        JayoBasket basket = new JayoBasket(gateway, IERC20(RUSDG), deployer, FIRST_V3_TOKEN_ID);
        JayoRenderer renderer = new JayoRenderer(SITE_URL, NETWORK_NOTE);
        basket.setRenderer(renderer);
        basket.setAssetRoute(TSLA, _key(TSLA), RUSDG < TSLA, adapter, true);
        basket.setAssetRoute(AMZN, _key(AMZN), RUSDG < AMZN, adapter, true);

        // Version 2 becomes withdraw-only: no new money through it.
        v2.setAssetRoute(TSLA, _key(TSLA), RUSDG < TSLA, adapter, false);
        v2.setAssetRoute(AMZN, _key(AMZN), RUSDG < AMZN, adapter, false);
        vm.stopBroadcast();

        string memory j = "jayo-v3";
        vm.serializeString(j, "network", "robinhood-chain-testnet");
        vm.serializeString(j, "warning", vm.parseJsonString(v2r, ".warning"));
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeAddress(j, "updater", vm.parseJsonAddress(v2r, ".updater"));
        vm.serializeAddress(j, "poolManager", POOL_MANAGER);
        vm.serializeAddress(j, "usdg", RUSDG);
        vm.serializeAddress(j, "tsla", TSLA);
        vm.serializeAddress(j, "amzn", AMZN);
        vm.serializeAddress(j, "tslaFeed", vm.parseJsonAddress(v2r, ".tslaFeed"));
        vm.serializeAddress(j, "amznFeed", vm.parseJsonAddress(v2r, ".amznFeed"));
        vm.serializeAddress(j, "usdgFeed", vm.parseJsonAddress(v2r, ".usdgFeed"));
        vm.serializeAddress(j, "policy", vm.parseJsonAddress(v2r, ".policy"));
        vm.serializeAddress(j, "gateway", address(gateway));
        vm.serializeAddress(j, "adapter", adapter);
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
        vm.serializeUint(j, "firstTokenId", FIRST_V3_TOKEN_ID);
        vm.serializeAddress(j, "legacyBasket", vm.parseJsonAddress(v2r, ".legacyBasket"));
        vm.serializeAddress(j, "legacyBasket2", address(v2));
        vm.serializeAddress(j, "renderer", address(renderer));
        string memory out = vm.serializeAddress(j, "basket", address(basket));
        vm.writeJson(out, "./reports/jayo-testnet-v3.json");

        console2.log("basket v3", address(basket));
        console2.log("renderer ", address(renderer));
        console2.log("v2 is now withdraw-only:", address(v2));
    }
}
