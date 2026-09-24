// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {JayoBasket} from "../src/basket/JayoBasket.sol";

/// @title The Jayo journey on the public testnet, between two independent wallets
///
/// @notice The primary public proof. Every step is a real transaction from the
///         wallet that would really send it, so every receipt can be checked by
///         anyone on the public RPC or explorer.
///
///         PHASE 1  Alice builds a basket (60% TSLA / 40% AMZN) with her rUSDG.
///                  Bob copies its recipe with HIS OWN rUSDG into a separate basket.
///                  Alice takes her AMZN out in kind and keeps the basket.
///                  Alice hands the basket to Bob.
///
///         between the phases, run as Alice with `cast call` (no gas, no state):
///                  redeem(aliceBasket)  ->  reverts NotPositionOwner
///
///         PHASE 2  Bob, now the owner, withdraws everything left in it.
///                  Bob takes half of every token out of his own copy.
///
///      Two phases so the refusal is shown against the chain as it really is
///      after the hand-over and before Bob withdraws (after that the basket no
///      longer exists and the error would say so instead).
///
///        JOURNEY_PHASE=1 forge script script/PublicJourney.s.sol --rpc-url <testnet> --broadcast --slow
///        JOURNEY_PHASE=2 forge script script/PublicJourney.s.sol --rpc-url <testnet> --broadcast --slow
contract PublicJourney is Script {
    uint256 constant FUND_ALICE = 20_000000; // 20 rUSDG: 10 per leg, measured at 78 bps
    uint256 constant FUND_BOB_COPY = 8_000000;
    string constant STATE = "./reports/journey-testnet.json";

    function run() external {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
        string memory json = vm.readFile("./reports/jayo-testnet.json");
        JayoBasket basket = JayoBasket(vm.parseJsonAddress(json, ".basket"));
        address rusdg = vm.parseJsonAddress(json, ".usdg");
        address tsla = vm.parseJsonAddress(json, ".tsla");
        address amzn = vm.parseJsonAddress(json, ".amzn");

        uint256 aliceKey = vm.envUint("ALICE_PRIVATE_KEY");
        uint256 bobKey = vm.envUint("BOB_PRIVATE_KEY");
        address alice = vm.addr(aliceKey);
        address bob = vm.addr(bobKey);
        require(alice != bob, "two different wallets");

        uint256 phase = vm.envUint("JOURNEY_PHASE");

        if (phase == 1) {
            JayoBasket.Allocation[] memory a = new JayoBasket.Allocation[](2);
            a[0] = JayoBasket.Allocation({asset: tsla, weightBps: 6000});
            a[1] = JayoBasket.Allocation({asset: amzn, weightBps: 4000});

            vm.startBroadcast(aliceKey);
            IERC20(rusdg).approve(address(basket), type(uint256).max);
            uint256 aliceBasket = basket.create(a, FUND_ALICE, block.timestamp + 1 hours);
            vm.stopBroadcast();

            vm.startBroadcast(bobKey);
            IERC20(rusdg).approve(address(basket), type(uint256).max);
            uint256 bobBasket = basket.copyAllocation(aliceBasket, FUND_BOB_COPY, block.timestamp + 1 hours);
            vm.stopBroadcast();

            vm.startBroadcast(aliceKey);
            basket.redeemAsset(aliceBasket, amzn);
            basket.safeTransferFrom(alice, bob, aliceBasket);
            vm.stopBroadcast();

            require(basket.ownerOf(aliceBasket) == bob, "hand-over did not land");
            require(basket.ownerOf(bobBasket) == bob, "copy belongs to Bob");

            string memory j = "journey";
            vm.serializeUint(j, "aliceBasket", aliceBasket);
            string memory out = vm.serializeUint(j, "bobBasket", bobBasket);
            vm.writeJson(out, STATE);
            console2.log("Alice's basket (now Bob's):", aliceBasket);
            console2.log("Bob's copy:                ", bobBasket);
        } else if (phase == 2) {
            string memory st = vm.readFile(STATE);
            uint256 aliceBasket = vm.parseJsonUint(st, ".aliceBasket");
            uint256 bobBasket = vm.parseJsonUint(st, ".bobBasket");
            require(basket.ownerOf(aliceBasket) == bob, "Bob does not own the handed-over basket");

            vm.startBroadcast(bobKey);
            basket.redeem(aliceBasket);
            basket.redeemFraction(bobBasket, 5000);
            vm.stopBroadcast();

            console2.log("Bob withdrew basket", aliceBasket);
            console2.log("Bob took half of his copy", bobBasket);
        } else {
            revert("JOURNEY_PHASE must be 1 or 2");
        }
    }
}
