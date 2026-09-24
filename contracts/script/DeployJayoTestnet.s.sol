// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {DemoPriceFeed} from "../src/testnet/DemoPriceFeed.sol";
import {StockTokenReferencePolicy} from "../src/policy/StockTokenReferencePolicy.sol";
import {ExecutionGateway} from "../src/core/ExecutionGateway.sol";
import {V4ExactInputAdapter} from "../src/adapters/V4ExactInputAdapter.sol";
import {JayoBasket} from "../src/basket/JayoBasket.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {PoolPriceReader} from "../src/testnet/PoolPriceReader.sol";

interface IOpenMintERC20 {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @title Jayo on Robinhood Chain testnet (chainId 46630)
///
/// @notice Deploys Jayo against the assets that are genuinely on that chain, and
///         against the real Uniswap v4 PoolManager and the real pools.
///
/// @dev WHAT IS REAL HERE, and what is not. Everything below was read from
///      `https://rpc.testnet.chain.robinhood.com` on 2026-09-23; see
///      docs/TESTNET_SURVEY.md for the method.
///
///      REAL — not deployed by us:
///        PoolManager  0x8366a39CC670B4001A1121B8F6A443A643e40951
///          Same address as mainnet, byte-for-byte identical runtime code.
///        TSLA         0xc9f9c86933092bbbfff3ccb4b105a4a94bf3bd4e   18 dp
///        AMZN         0x5884ad2f920c162cfbbacc88c9c51aa75ec09e02   18 dp
///          Both implement ERC-8056. Both revert on `oraclePaused()`, which is
///          why the policy probes capabilities at registration.
///          `mint` on both is access-controlled: we cannot print equity, we have
///          to buy it through the pool like anyone else.
///        rUSDG        0x7c902600cb5bf24225df1a77b333d84e03c1f210    6 dp
///          "Rehearsal USDG". `mint(address,uint256)` is open, so funding the
///          demo needs no token faucet.
///        TSLA/rUSDG pool  id 0xa127342a80d06763b74ed55f9b6b75cb1101d6498a0ebe750863786aba4305c9
///        AMZN/rUSDG pool  id 0x36fa647ec7fd8280b317a6b2616e887e70df70279a829d437be5824b517730f7
///          Both fee 3000, tickSpacing 60, NO HOOK. We neither created nor seeded
///          them; they carry other people's liquidity.
///
///      MOCK — deployed by us, and the only mock left:
///        The three price feeds. Chainlink publishes a reference-data directory
///        for Robinhood Chain mainnet and none for testnet
///        (feeds-robinhood-testnet.json returns 404), and the nine aggregators
///        that are live on testnet are other teams' fixtures — their own
///        descriptions say "(mock)", "(testnet, updated by the ...)" and
///        "TEST ONLY Non-Canonical Manual". Pointing a solvency-critical policy
///        at someone else's hackathon fixture would be worse than deploying our
///        own and saying so.
///
///      LIQUIDITY IS THIN, and that governs the demo size. At the prices read on
///      2026-09-23 the active range held about 2,009 rUSDG / 7.96 TSLA and about
///      906 rUSDG / 4.97 AMZN. Against a 100 bps floor a TSLA leg larger than
///      roughly 14 rUSDG is refused by the policy — correctly. DEFAULT_FUND is
///      set below that on purpose: the demo is meant to complete, and a separate
///      oversized run is meant to be refused.
///
///      Usage:
///        cp .env.example .env    # then put a DEDICATED THROWAWAY key in it
///        forge script script/DeployJayoTestnet.s.sol \
///          --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
contract DeployJayoTestnet is Script {
    // --- chain constants, all verified on 2026-09-23 ------------------------
    uint256 constant CHAIN_ID = 46630;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant RUSDG = 0x7C902600cb5bf24225DF1a77b333D84e03C1F210;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    uint8 constant FEED_DECIMALS = 8;
    /// @dev Our own feeds, so we choose the heartbeat. One hour keeps the
    ///      staleness guard meaningful rather than decorative.
    uint32 constant FEED_HEARTBEAT = 3600;
    /// @dev 300 bps, where a mainnet deployment would use 50. Measured against
    ///      the live TSLA/rUSDG pool by `test/fork/TestnetJourney.t.sol`:
    ///
    ///          1 rUSDG  ->  34 bps      50 rUSDG  -> 269 bps
    ///          5 rUSDG  ->  54 bps     200 rUSDG  -> refused
    ///         10 rUSDG  ->  78 bps
    ///
    ///      of which 30 bps is the pool's own fee. The mainnet AAPL/USDG pools are
    ///      orders of magnitude deeper; a floor calibrated for them refuses every
    ///      trade here. Raised deliberately, with the numbers, rather than tuned
    ///      until something passed.
    uint16 constant MAX_SHORTFALL_BPS = 300;

    int256 constant RUSDG_USD = 1_00000000;

    /// @dev A refresh may move a feed at most 10%. Past that, the refresh is
    ///      refused, the feed ages out after FEED_HEARTBEAT and buying stops until
    ///      the owner looks at it. See DemoPriceFeed.
    uint16 constant FEED_MAX_STEP_BPS = 1000;

    /// @dev 10 rUSDG a leg, which measures at 78 bps against a 300 bps floor.
    uint256 constant DEFAULT_FUND = 20_000000;

    /// @dev Grouped because `_report` takes every address at once and the
    ///      individual-argument form ran the Yul stack out at via_ir.
    struct Deployed {
        StockTokenReferencePolicy policy;
        ExecutionGateway gateway;
        V4ExactInputAdapter adapter;
        JayoBasket basket;
        DemoPriceFeed tslaFeed;
        DemoPriceFeed amznFeed;
        DemoPriceFeed usdgFeed;
        address deployer;
    }

    function run() external virtual {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain testnet");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        _assertChainStateIsWhatWeSurveyed();

        vm.startBroadcast(pk);
        Deployed memory d = _deployAll(deployer);
        vm.stopBroadcast();

        _report(d);
    }

    /// @dev Everything the deployment broadcasts, separated from `run` so the cost
    ///      simulation (SimulateTestnetDemo) exercises exactly the same calls
    ///      without writing a deployment report.
    function _deployAll(address deployer) internal returns (Deployed memory d) {
        d.deployer = deployer;
        // Read from the pools, not hardcoded. Chainlink's mainnet feeds put TSLA
        // at $380.26 and AMZN at $256.91 (2026-09-23) while these pools price them
        // near $256 and $191 - unrelated venues, ~30% apart. Referencing mainnet
        // would refuse every trade here for a reason unrelated to the trade.
        // PoolPriceReader states what taking the pool's own price costs.
        int256 tslaUsd = int256(PoolPriceReader.usdPrice8(IPoolManager(POOL_MANAGER), _key(TSLA), RUSDG < TSLA));
        int256 amznUsd = int256(PoolPriceReader.usdPrice8(IPoolManager(POOL_MANAGER), _key(AMZN), RUSDG < AMZN));
        require(tslaUsd > 0 && amznUsd > 0, "a pool has no price");
        console2.log("TSLA pool price, 8dp:", uint256(tslaUsd));
        console2.log("AMZN pool price, 8dp:", uint256(amznUsd));

        // Access-controlled: only the deployer (owner and updater) can move these,
        // and no single update may move one more than FEED_MAX_STEP_BPS. The first
        // version of this script used an open-setter mock, which on a public
        // chain let anyone rewrite the price a user's floor is computed from.
        d.tslaFeed = new DemoPriceFeed(FEED_DECIMALS, tslaUsd, "DEMO TSLA / USD (pool-derived, Jayo testnet)", deployer, FEED_MAX_STEP_BPS);
        d.amznFeed = new DemoPriceFeed(FEED_DECIMALS, amznUsd, "DEMO AMZN / USD (pool-derived, Jayo testnet)", deployer, FEED_MAX_STEP_BPS);
        d.usdgFeed = new DemoPriceFeed(FEED_DECIMALS, RUSDG_USD, "DEMO rUSDG / USD (fixed at $1, Jayo testnet)", deployer, FEED_MAX_STEP_BPS);

        d.policy = new StockTokenReferencePolicy(keccak256("Jayo.StockTokenBasket.v1"), deployer);
        d.policy.setQuoteAsset(RUSDG, address(d.usdgFeed), FEED_HEARTBEAT, 6);
        d.policy.setStockToken(TSLA, address(d.tslaFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
        d.policy.setStockToken(AMZN, address(d.amznFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        d.gateway = new ExecutionGateway(deployer, d.policy);
        d.adapter = new V4ExactInputAdapter(IPoolManager(POOL_MANAGER), deployer);
        d.adapter.setGateway(address(d.gateway));
        d.gateway.setAdapter(address(d.adapter), true);

        d.basket = new JayoBasket(d.gateway, IERC20(RUSDG), deployer);

        _wireRoutes(d);

        // rUSDG mints to anyone, so the demo wallet funds itself.
        IOpenMintERC20(RUSDG).mint(deployer, 10_000_000000);
    }

    function _wireRoutes(Deployed memory d) internal {
        PoolKey memory tslaKey = _key(TSLA);
        PoolKey memory amznKey = _key(AMZN);

        // zeroForOne for the BUY leg is "spend rUSDG": true when rUSDG sorts first.
        bool tslaBuy = RUSDG < TSLA;
        bool amznBuy = RUSDG < AMZN;

        d.adapter.setRoute(tslaKey, tslaBuy, true);
        d.adapter.setRoute(tslaKey, !tslaBuy, true);
        d.adapter.setRoute(amznKey, amznBuy, true);
        d.adapter.setRoute(amznKey, !amznBuy, true);

        d.basket.setAssetRoute(TSLA, tslaKey, tslaBuy, address(d.adapter), true);
        d.basket.setAssetRoute(AMZN, amznKey, amznBuy, address(d.adapter), true);
    }

    /// @dev Fails before spending gas if the chain no longer matches the survey.
    ///      A silent mismatch here would produce a deployment that looks live and
    ///      cannot trade.
    function _assertChainStateIsWhatWeSurveyed() internal view {
        require(POOL_MANAGER.code.length > 0, "PoolManager missing");
        require(TSLA.code.length > 0 && AMZN.code.length > 0, "equity token missing");
        require(RUSDG.code.length > 0, "rUSDG missing");
        require(IOpenMintERC20(RUSDG).decimals() == 6, "rUSDG decimals moved");
        require(IStockToken(TSLA).decimals() == 18, "TSLA decimals moved");
        require(IStockToken(AMZN).decimals() == 18, "AMZN decimals moved");

        // The capability the policy has to work around. If this ever starts
        // answering, the probe will simply record it and the pause check turns on.
        (bool answers,) = TSLA.staticcall(abi.encodeCall(IStockToken.oraclePaused, ()));
        console2.log("TSLA answers oraclePaused():", answers);
    }

    function _key(address stock) internal pure returns (PoolKey memory) {
        (address c0, address c1) = RUSDG < stock ? (RUSDG, stock) : (stock, RUSDG);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _report(Deployed memory d) internal {
        string memory j = "jayo";
        vm.serializeString(j, "network", "robinhood-chain-testnet");
        vm.serializeString(
            j,
            "warning",
            "PoolManager, TSLA, AMZN, rUSDG and both pools are real chain state we did not deploy. The three price feeds are ours (DemoPriceFeed: deployer-only, 10% step bound, 1h heartbeat) and copy the pools own price: Chainlink publishes no feeds on this testnet."
        );
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", d.deployer);
        vm.serializeAddress(j, "poolManager", POOL_MANAGER);
        vm.serializeAddress(j, "usdg", RUSDG);
        vm.serializeAddress(j, "tsla", TSLA);
        vm.serializeAddress(j, "amzn", AMZN);
        vm.serializeAddress(j, "tslaFeed", address(d.tslaFeed));
        vm.serializeAddress(j, "amznFeed", address(d.amznFeed));
        vm.serializeAddress(j, "usdgFeed", address(d.usdgFeed));
        vm.serializeAddress(j, "policy", address(d.policy));
        vm.serializeAddress(j, "gateway", address(d.gateway));
        vm.serializeAddress(j, "adapter", address(d.adapter));
        address[] memory stocks = new address[](2);
        stocks[0] = TSLA;
        stocks[1] = AMZN;
        vm.serializeAddress(j, "stocks", stocks);
        // No anvil keys, no admin over these feeds from a browser, no time travel
        // on a public chain. The demo panel does not apply here and is hidden.
        vm.serializeBool(j, "demoControls", false);
        vm.serializeString(j, "rpcUrl", "https://rpc.testnet.chain.robinhood.com");
        vm.serializeString(j, "explorer", "https://explorer.testnet.chain.robinhood.com");
        vm.serializeUint(j, "suggestedFund", DEFAULT_FUND);
        vm.serializeUint(j, "feedHeartbeat", FEED_HEARTBEAT);
        vm.serializeUint(j, "maxShortfallBps", MAX_SHORTFALL_BPS);
        vm.serializeString(j, "priceSource", "pool");
        string memory out = vm.serializeAddress(j, "basket", address(d.basket));
        vm.writeJson(out, "./reports/jayo-testnet.json");
        // Also written to a fixed path so the interface fetches exactly one
        // file and never has to probe-and-404 its way to the right network.
        vm.writeJson(out, "./reports/jayo-deployment.json");

        console2.log("policy  ", address(d.policy));
        console2.log("gateway ", address(d.gateway));
        console2.log("adapter ", address(d.adapter));
        console2.log("basket  ", address(d.basket));
    }
}
