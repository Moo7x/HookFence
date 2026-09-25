// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {DeployJayoTestnet} from "./DeployJayoTestnet.s.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";

interface IJayoBasketV1Admin {
    function setAssetRoute(address asset, PoolKeyV1 calldata key, bool zeroForOne, address adapter, bool enabled) external;
    function owner() external view returns (address);
}

struct PoolKeyV1 {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title Make version 1 withdraw-only on chain
///
/// @notice Version 1 is immutable and its positions must stay withdrawable, but
///         nothing new should be bought through it: new baskets belong in
///         version 2, and a version-1 id reaching 101 would collide with version
///         2's numbering. Disabling version 1's purchase routes refuses `create`
///         and `copyAllocation` there (AssetNotSupported) while every withdrawal
///         path - which never reads a route - keeps working, and hand-overs are
///         untouched. Reversible by the same owner call with `enabled = true`.
contract FreezeV1Purchases is DeployJayoTestnet {
    function run() external override {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain testnet");
        string memory v2 = vm.readFile("./reports/jayo-testnet-v2.json");
        IJayoBasketV1Admin v1 = IJayoBasketV1Admin(vm.parseJsonAddress(v2, ".legacyBasket"));
        address adapter = vm.parseJsonAddress(v2, ".adapter");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        v1.setAssetRoute(TSLA, _v1Key(TSLA), RUSDG < TSLA, adapter, false);
        v1.setAssetRoute(AMZN, _v1Key(AMZN), RUSDG < AMZN, adapter, false);
        vm.stopBroadcast();
        console2.log("version 1 purchases disabled on", address(v1));
    }

    function _v1Key(address stock) internal pure returns (PoolKeyV1 memory) {
        (address c0, address c1) = RUSDG < stock ? (RUSDG, stock) : (stock, RUSDG);
        return PoolKeyV1(c0, c1, FEE, TICK_SPACING, address(0));
    }
}
