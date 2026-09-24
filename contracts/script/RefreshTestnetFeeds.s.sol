// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {DemoPriceFeed} from "../src/testnet/DemoPriceFeed.sol";
import {PoolPriceReader} from "../src/testnet/PoolPriceReader.sol";

/// @title Keep the testnet demo feeds inside their heartbeat
///
/// @notice The testnet feeds have a one-hour heartbeat. Past that the policy
///         refuses every purchase (correctly), so a live demo needs someone to
///         republish. This is that someone: it re-reads each pool's spot price
///         and writes it to the matching feed, and writes $1.00 to the rUSDG feed.
///
/// @dev REFRESH PLAN
///        - Run once immediately before any demo session.
///        - While a session is open, `scripts/keep-testnet-feeds-fresh.sh` runs
///          this every 40 minutes, which leaves a 20-minute margin inside the
///          heartbeat for a slow block or a failed run.
///        - Outside sessions, do nothing. Letting the feeds go stale means buying
///          is refused, which is the safe resting state; withdrawals need no price
///          and keep working.
///
///      WHAT A REFRESH CANNOT DO. It copies the pool's price into the feed. If
///      someone has pushed that pool off its fair price, a refresh copies the
///      distortion - there is no independent market on this network to compare
///      against. Two things limit the damage: only the deployer can write, and a
///      write that would move a feed more than its step bound (10%) is skipped
///      here and would revert on-chain anyway. A skipped feed goes stale after its
///      heartbeat and buying stops until a person decides, with `forceAnswer`.
///
///      Usage:
///        forge script script/RefreshTestnetFeeds.s.sol \
///          --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
contract RefreshTestnetFeeds is Script {
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int256 constant RUSDG_USD = 1_00000000;

    function run() external {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
        string memory json = vm.readFile("./reports/jayo-testnet.json");

        address pm = vm.parseJsonAddress(json, ".poolManager");
        address usdg = vm.parseJsonAddress(json, ".usdg");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        _refreshFromPool(pm, usdg, vm.parseJsonAddress(json, ".tsla"), DemoPriceFeed(vm.parseJsonAddress(json, ".tslaFeed")), "TSLA");
        _refreshFromPool(pm, usdg, vm.parseJsonAddress(json, ".amzn"), DemoPriceFeed(vm.parseJsonAddress(json, ".amznFeed")), "AMZN");
        _write(DemoPriceFeed(vm.parseJsonAddress(json, ".usdgFeed")), RUSDG_USD, "rUSDG");

        vm.stopBroadcast();
    }

    function _refreshFromPool(address pm, address usdg, address stock, DemoPriceFeed feed, string memory label) internal {
        (address c0, address c1) = usdg < stock ? (usdg, stock) : (stock, usdg);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        int256 spot = int256(PoolPriceReader.usdPrice8(IPoolManager(pm), key, usdg < stock));
        _write(feed, spot, label);
    }

    function _write(DemoPriceFeed feed, int256 next, string memory label) internal {
        (, int256 prev,, uint256 updatedAt,) = feed.latestRoundData();
        uint16 step = feed.maxStepBps();
        uint256 diff = uint256(next > prev ? next - prev : prev - next);

        if (next <= 0 || (step != 0 && diff * 10_000 > uint256(prev) * step)) {
            console2.log(string.concat("SKIPPED ", label, ": move exceeds the feed's step bound"));
            console2.log("   previous (8dp):", uint256(prev));
            console2.log("   pool now (8dp):", next > 0 ? uint256(next) : 0);
            console2.log("   It will go stale and buying will stop. Check the pool, then forceAnswer if the move is real.");
            return;
        }
        feed.setAnswer(next);
        console2.log(string.concat("refreshed ", label, " (8dp):"), uint256(next));
        console2.log("   age before refresh, s:", block.timestamp - updatedAt);
    }
}
