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

/// @title The operator's override for a refresh the step bound refused
///
/// @notice RefreshTestnetFeeds skips any asset whose pool moved more than the
///         feed's step bound (10%) since the last publish, and that feed then
///         expires. This is what a person runs AFTER looking at why the pool
///         moved and deciding the move is genuine - for example, an unrelated
///         address buying steadily over hours, rather than one block of
///         manipulation. It copies the pool's current price with `forceAnswer`,
///         which the feed records as its own `AnswerForced` event.
///
/// @dev Two guards against using it carelessly:
///        FORCE_ASSET must name the asset (TSLA or AMZN) - there is no "all";
///        FORCE_MAX_BPS caps the move being accepted (default 2500 = 25%).
///
///        FORCE_ASSET=AMZN forge script script/ForceTestnetFeed.s.sol \
///          --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
contract ForceTestnetFeed is Script {
    function run() external {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
        string memory asset = vm.envString("FORCE_ASSET");
        uint256 maxBps = vm.envOr("FORCE_MAX_BPS", uint256(2500));
        string memory json = vm.readFile("./reports/jayo-testnet.json");

        bool isT = keccak256(bytes(asset)) == keccak256("TSLA");
        bool isA = keccak256(bytes(asset)) == keccak256("AMZN");
        require(isT || isA, "FORCE_ASSET must be TSLA or AMZN");

        address pm = vm.parseJsonAddress(json, ".poolManager");
        address usdg = vm.parseJsonAddress(json, ".usdg");
        address stock = vm.parseJsonAddress(json, isT ? ".tsla" : ".amzn");
        DemoPriceFeed feed = DemoPriceFeed(vm.parseJsonAddress(json, isT ? ".tslaFeed" : ".amznFeed"));

        (address c0, address c1) = usdg < stock ? (usdg, stock) : (stock, usdg);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        int256 spot = int256(PoolPriceReader.usdPrice8(IPoolManager(pm), key, usdg < stock));
        (, int256 prev,, uint256 updatedAt,) = feed.latestRoundData();

        uint256 diff = uint256(spot > prev ? spot - prev : prev - spot);
        uint256 moveBps = diff * 10_000 / uint256(prev);
        console2.log(string.concat(asset, " feed (8dp):"), uint256(prev));
        console2.log("pool now (8dp):", uint256(spot));
        console2.log("move, bps:", moveBps);
        console2.log("feed age, s:", block.timestamp - updatedAt);
        require(moveBps <= maxBps, "move larger than FORCE_MAX_BPS - look again before overriding");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        feed.forceAnswer(spot);
        vm.stopBroadcast();
        console2.log("forced; the feed emitted AnswerForced");
    }
}
