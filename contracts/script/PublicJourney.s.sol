// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IJayoBasketV1} from "../src/interfaces/IJayoBasketV1.sol";

/// @title The Jayo journey on the public testnet, between two independent wallets
///
/// @notice The primary public proof. Every step is a real transaction from the
///         wallet that would really send it, so every receipt can be checked by
///         anyone on the public RPC or explorer.
///
///         PHASE 1  Alice builds basket A (60% TSLA / 40% AMZN) with her rUSDG,
///                  then hands basket A to Bob.
///
///         between the phases, as Alice, with `cast call` (no gas, no state):
///                  redeem(A)  ->  reverts NotPositionOwner(A, Alice)
///
///         PHASE 2  Alice copies A's RECIPE with her own money into a new basket C
///                  - same weights, different exact holdings, hers alone.
///                  Bob, now A's owner, takes out only its AMZN and keeps its TSLA.
///
///      This is the sequence that shows what an individually owned position means:
///      the old owner loses all authority over A; A's recorded holdings go with it;
///      the recipe stays public and copyable without touching A; the new owner
///      chooses which asset to take out. A shared-vault design cannot do the last
///      step - a single-asset exit would shift every other holder's ratio.
///
///        JOURNEY_PHASE=1 forge script script/PublicJourney.s.sol --rpc-url <testnet> --broadcast --slow
///        JOURNEY_PHASE=2 forge script script/PublicJourney.s.sol --rpc-url <testnet> --broadcast --slow
contract PublicJourney is Script {
    uint256 constant FUND_ALICE = 20_000000; // 20 rUSDG: 10 per leg, measured at 78 bps on testnet
    uint256 constant FUND_COPY = 8_000000;   // smaller: it trades right after, further along thin curves
    string constant STATE = "./reports/journey-testnet.json";

    IJayoBasketV1 basket; // the version-1 deployment this journey was run against
    address tsla;
    address amzn;

    function run() external {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
        string memory json = vm.readFile("./reports/jayo-testnet.json");
        basket = IJayoBasketV1(vm.parseJsonAddress(json, ".basket"));
        address rusdg = vm.parseJsonAddress(json, ".usdg");
        tsla = vm.parseJsonAddress(json, ".tsla");
        amzn = vm.parseJsonAddress(json, ".amzn");

        uint256 aliceKey = vm.envUint("ALICE_PRIVATE_KEY");
        uint256 bobKey = vm.envUint("BOB_PRIVATE_KEY");
        address alice = vm.addr(aliceKey);
        address bob = vm.addr(bobKey);
        require(alice != bob, "two different wallets");

        uint256 phase = vm.envUint("JOURNEY_PHASE");

        if (phase == 1) {
            IJayoBasketV1.Allocation[] memory a = new IJayoBasketV1.Allocation[](2);
            a[0] = IJayoBasketV1.Allocation({asset: tsla, weightBps: 6000});
            a[1] = IJayoBasketV1.Allocation({asset: amzn, weightBps: 4000});

            vm.startBroadcast(aliceKey);
            IERC20(rusdg).approve(address(basket), type(uint256).max);
            uint256 basketA = basket.create(a, FUND_ALICE, block.timestamp + 1 hours);
            basket.safeTransferFrom(alice, bob, basketA);
            vm.stopBroadcast();

            require(basket.ownerOf(basketA) == bob, "hand-over did not land");

            string memory j = "journey";
            string memory out = vm.serializeUint(j, "basketA", basketA);
            vm.writeJson(out, STATE);
            console2.log("basket A, built by Alice, now owned by Bob:", basketA);
            _show("basket A", basketA);
        } else if (phase == 2) {
            uint256 basketA = vm.parseJsonUint(vm.readFile(STATE), ".basketA");
            require(basket.ownerOf(basketA) == bob, "Bob does not own basket A");

            vm.startBroadcast(aliceKey);
            uint256 basketC = basket.copyAllocation(basketA, FUND_COPY, block.timestamp + 1 hours);
            vm.stopBroadcast();

            uint256 amznBefore = IERC20(amzn).balanceOf(bob);
            vm.startBroadcast(bobKey);
            basket.redeemAsset(basketA, amzn);
            vm.stopBroadcast();

            require(basket.ownerOf(basketC) == alice, "the copy is Alice's");
            require(basket.ownerOf(basketA) == bob, "A is still Bob's after a partial exit");

            string memory j = "journey2";
            vm.serializeUint(j, "basketA", basketA);
            string memory out = vm.serializeUint(j, "basketC", basketC);
            vm.writeJson(out, STATE);

            console2.log("basket C, Alice's copy of A's recipe:", basketC);
            _show("basket A (Bob's, after taking AMZN out)", basketA);
            _show("basket C (Alice's copy)", basketC);
            console2.log("AMZN Bob received in kind (1e18):", IERC20(amzn).balanceOf(bob) - amznBefore);
        } else {
            revert("JOURNEY_PHASE must be 1 or 2");
        }
    }

    function _show(string memory label, uint256 id) internal view {
        (address[] memory assets, uint256[] memory amounts) = basket.holdingsOf(id);
        console2.log(label);
        for (uint256 i; i < assets.length; ++i) {
            console2.log(assets[i] == tsla ? "   TSLA (1e18):" : "   AMZN (1e18):", amounts[i]);
        }
    }
}
