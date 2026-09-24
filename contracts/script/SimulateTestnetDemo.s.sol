// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DeployJayoTestnet} from "./DeployJayoTestnet.s.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";

/// @title Every transaction a testnet demo costs, simulated against live state
///
/// @notice Runs the deployment, then the whole journey the interface drives, then
///         one feed refresh — each as the transaction it would really be — so the
///         dry-run record lists every call a funded wallet will have to pay for.
///         `scripts/estimate-testnet-cost.mjs` then prices each one, including the
///         L1 data component that a local EVM simulation cannot see.
///
/// @dev DRY RUN ONLY. Never pass --broadcast; use DeployJayoTestnet for that.
///        forge script script/SimulateTestnetDemo.s.sol \
///          --rpc-url https://rpc.testnet.chain.robinhood.com
contract SimulateTestnetDemo is DeployJayoTestnet {
    function run() external override {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain testnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address recipient = address(0xBEEF);

        vm.startBroadcast(pk);

        // ---- deployment -----------------------------------------------------
        Deployed memory d = _deployAll(me);

        // ---- the journey the interface drives -------------------------------
        IERC20(RUSDG).approve(address(d.basket), type(uint256).max);

        JayoBasket.Allocation[] memory a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: TSLA, weightBps: 6000});
        a[1] = JayoBasket.Allocation({asset: AMZN, weightBps: 4000});

        uint256 first = d.basket.create(a, DEFAULT_FUND, block.timestamp + 1 hours);
        uint256 copy = d.basket.copyAllocation(first, DEFAULT_FUND / 2, block.timestamp + 1 hours);
        d.basket.redeemAsset(copy, AMZN);
        d.basket.redeemFraction(copy, 5000);
        d.basket.safeTransferFrom(me, recipient, first);
        d.basket.redeem(copy);

        // ---- one refresh of all three feeds ---------------------------------
        (, int256 t,,,) = d.tslaFeed.latestRoundData();
        (, int256 z,,,) = d.amznFeed.latestRoundData();
        d.tslaFeed.setAnswer(t);
        d.amznFeed.setAnswer(z);
        d.usdgFeed.setAnswer(RUSDG_USD);

        vm.stopBroadcast();
    }
}
