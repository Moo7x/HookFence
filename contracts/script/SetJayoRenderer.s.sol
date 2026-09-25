// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeployJayoTestnet} from "./DeployJayoTestnet.s.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";
import {JayoRenderer} from "../src/basket/JayoRenderer.sol";

/// @notice Replace what wallets display for version-2 baskets. The renderer is
///         the operator's only power over positions and it reaches display only:
///         holdings, ownership and withdrawals are untouched. Updates the
///         `renderer` field of reports/jayo-testnet-v2.json.
contract SetJayoRenderer is DeployJayoTestnet {
    function run() external override {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain testnet");
        string memory path = "./reports/jayo-testnet-v2.json";
        JayoBasket basket = JayoBasket(vm.parseJsonAddress(vm.readFile(path), ".basket"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        JayoRenderer r = new JayoRenderer(SITE_URL, NETWORK_NOTE);
        basket.setRenderer(r);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(r)), path, ".renderer");
        console2.log("renderer", address(r));
    }
}
