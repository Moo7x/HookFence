// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {V4ExactInputAdapter} from "../../src/adapters/V4ExactInputAdapter.sol";
import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {PoolPriceReader} from "../../src/testnet/PoolPriceReader.sol";

interface IOpenMintERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title The whole Jayo journey against live Robinhood Chain testnet state
///
/// @notice Runs on a fork of chainId 46630, so the PoolManager, the equity
///         tokens, the stablecoin and the pool liquidity are all real chain
///         state that nobody on this project deployed. Only the price feeds are
///         ours, because Chainlink publishes no feed directory for this testnet.
///
/// @dev This exists so the testnet deployment is proven before any gas is spent
///      on it, and so the numbers quoted in docs/TESTNET_SURVEY.md are produced
///      by running code rather than by arithmetic in a document.
///
///      Skipped automatically when no RPC is reachable, so it never breaks a
///      local or offline run:
///        forge test --match-contract TestnetJourney -vv
contract TestnetJourneyTest is Test {
    string constant RPC = "https://rpc.testnet.chain.robinhood.com";

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant RUSDG = 0x7C902600cb5bf24225DF1a77b333D84e03C1F210;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint8 constant FEED_DECIMALS = 8;
    uint32 constant FEED_HEARTBEAT = 3600;
    /// @dev 300 bps, not the 50 bps a mainnet deployment would use. The mainnet
    ///      AAPL/USDG pools hold millions; the testnet TSLA/rUSDG pool holds about
    ///      2,000 rUSDG. `test_MeasuredShortfallByLegSize` prints what that costs
    ///      in practice — a 10 rUSDG leg gives up roughly 130 bps, of which 30 is
    ///      the LP fee. A floor calibrated for mainnet depth rejects every testnet
    ///      trade, so this number is raised deliberately and the oversized case is
    ///      still refused.
    uint16 constant MAX_SHORTFALL_BPS = 300;

    int256 constant RUSDG_USD = 1_00000000;

    StockTokenReferencePolicy policy;
    ExecutionGateway gateway;
    V4ExactInputAdapter adapter;
    JayoBasket basket;
    MockAggregatorV3 tslaFeed;
    MockAggregatorV3 amznFeed;
    MockAggregatorV3 usdgFeed;

    address admin = address(this);
    address user = makeAddr("testnetUser");

    bool forked;

    function setUp() public {
        try vm.createSelectFork(RPC) {
            forked = true;
        } catch {
            forked = false;
            return;
        }
        assertEq(block.chainid, 46630, "forked the wrong chain");

        // Seeded FROM THE POOL, not hardcoded. The testnet pools price TSLA near
        // $252 and AMZN near $182 while Chainlink's mainnet feeds say $380.26 and
        // $256.91 — two unrelated venues, 30% apart. A reference taken from
        // mainnet would refuse every testnet trade for a reason that has nothing
        // to do with the trade. See PoolPriceReader for what this costs.
        int256 tslaUsd = int256(PoolPriceReader.usdPrice8(IPoolManager(POOL_MANAGER), _key(TSLA), RUSDG < TSLA));
        int256 amznUsd = int256(PoolPriceReader.usdPrice8(IPoolManager(POOL_MANAGER), _key(AMZN), RUSDG < AMZN));
        assertGt(tslaUsd, 0, "TSLA pool has no price");
        assertGt(amznUsd, 0, "AMZN pool has no price");
        console2.log("TSLA pool price, 8dp:", uint256(tslaUsd));
        console2.log("AMZN pool price, 8dp:", uint256(amznUsd));

        tslaFeed = new MockAggregatorV3(FEED_DECIMALS, tslaUsd, "MOCK TSLA / USD");
        amznFeed = new MockAggregatorV3(FEED_DECIMALS, amznUsd, "MOCK AMZN / USD");
        usdgFeed = new MockAggregatorV3(FEED_DECIMALS, RUSDG_USD, "MOCK rUSDG / USD");

        policy = new StockTokenReferencePolicy(keccak256("Jayo.StockTokenBasket.v1"), admin);
        policy.setQuoteAsset(RUSDG, address(usdgFeed), FEED_HEARTBEAT, 6);
        policy.setStockToken(TSLA, address(tslaFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
        policy.setStockToken(AMZN, address(amznFeed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);

        gateway = new ExecutionGateway(admin, policy);
        adapter = new V4ExactInputAdapter(IPoolManager(POOL_MANAGER), admin);
        adapter.setGateway(address(gateway));
        gateway.setAdapter(address(adapter), true);

        basket = new JayoBasket(gateway, IERC20(RUSDG), admin);

        _route(TSLA);
        _route(AMZN);

        IOpenMintERC20(RUSDG).mint(user, 100_000000); // 100 rUSDG, open mint
    }

    function _route(address stock) internal {
        PoolKey memory key = _key(stock);
        bool buy = RUSDG < stock;
        adapter.setRoute(key, buy, true);
        adapter.setRoute(key, !buy, true);
        basket.setAssetRoute(stock, key, buy, address(adapter), true);
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

    function _alloc() internal pure returns (JayoBasket.Allocation[] memory a) {
        a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: TSLA, weightBps: 5000});
        a[1] = JayoBasket.Allocation({asset: AMZN, weightBps: 5000});
    }

    // =======================================================================

    /// @notice The equity tokens on this chain do not implement `oraclePaused()`.
    ///         Before the capability probe existed, this alone made every quote
    ///         revert and there was no testnet deployment to demonstrate.
    function test_TestnetEquityTokensDoNotAnswerOraclePaused() public {
        if (!forked) return;

        (bool ok,) = TSLA.staticcall(abi.encodeCall(IStockToken.oraclePaused, ()));
        assertFalse(ok, "TSLA answered oraclePaused() - the survey is out of date");

        assertFalse(policy.stockTokenConfig(TSLA).hasOraclePaused, "recorded as absent");
        assertTrue(policy.stockTokenConfig(TSLA).hasCorporateActionData, "ERC-8056 reads are present");
    }

    /// @notice A basket funded with real rUSDG really acquires real TSLA and AMZN
    ///         through the real PoolManager, and the position is the caller's.
    function test_CreateBuysRealEquityThroughTheRealPoolManager() public {
        if (!forked) return;

        vm.startPrank(user);
        IERC20(RUSDG).approve(address(basket), type(uint256).max);
        uint256 id = basket.create(_alloc(), 20_000000, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(basket.ownerOf(id), user, "the position belongs to the funder");

        (address[] memory assets, uint256[] memory amounts) = basket.holdingsOf(id);
        assertEq(assets.length, 2, "two legs");
        assertGt(amounts[0], 0, "acquired TSLA");
        assertGt(amounts[1], 0, "acquired AMZN");

        assertEq(IERC20(TSLA).balanceOf(address(basket)), basket.totalLiabilities(TSLA), "TSLA fully attributed");
        assertEq(IERC20(AMZN).balanceOf(address(basket)), basket.totalLiabilities(AMZN), "AMZN fully attributed");

        console2.log("TSLA acquired (1e18):", amounts[0]);
        console2.log("AMZN acquired (1e18):", amounts[1]);
    }

    /// @notice Withdrawal reads no price. It must therefore work even with the
    ///         feeds driven past their heartbeat.
    function test_WithdrawalWorksWithEveryFeedStale() public {
        if (!forked) return;

        vm.startPrank(user);
        IERC20(RUSDG).approve(address(basket), type(uint256).max);
        uint256 id = basket.create(_alloc(), 20_000000, block.timestamp + 1 hours);
        vm.stopPrank();

        (, uint256[] memory owed) = basket.holdingsOf(id);

        vm.warp(vm.getBlockTimestamp() + FEED_HEARTBEAT + 1 days);

        vm.expectRevert(); // buying is refused: the feeds are stale
        vm.prank(user);
        basket.create(_alloc(), 20_000000, vm.getBlockTimestamp() + 1 hours);

        vm.prank(user);
        basket.redeem(id);

        assertEq(IERC20(TSLA).balanceOf(user), owed[0], "TSLA delivered in kind");
        assertEq(IERC20(AMZN).balanceOf(user), owed[1], "AMZN delivered in kind");
    }

    /// @notice The liquidity on this chain is thin, so the floor does real work.
    ///         A basket sized past what the pool can fill is refused rather than
    ///         executed at a bad price.
    /// @dev This is the constraint that sets the demo size. It is a result, not a
    ///      limitation we are apologising for: the same code accepts 20 rUSDG and
    ///      refuses 2,000 against the same pool in the same block.
    function test_OversizedBasketIsRefusedAgainstRealLiquidity() public {
        if (!forked) return;

        IOpenMintERC20(RUSDG).mint(user, 10_000_000000);

        vm.startPrank(user);
        IERC20(RUSDG).approve(address(basket), type(uint256).max);

        uint256 small = basket.create(_alloc(), 20_000000, block.timestamp + 1 hours);
        assertEq(basket.ownerOf(small), user, "20 rUSDG completes");

        vm.expectRevert();
        basket.create(_alloc(), 2_000_000000, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice What the thin testnet liquidity actually costs, measured rather
    ///         than estimated. This is the evidence behind MAX_SHORTFALL_BPS.
    /// @dev Each size is priced against the pool in the same block, so the numbers
    ///      are comparable. The reference is the policy's own, which on testnet is
    ///      the pool's spot — so what this measures is the LP fee plus the impact
    ///      of the trade itself, and nothing about whether the venue is fairly
    ///      priced against the world. See PoolPriceReader.
    function test_MeasuredShortfallByLegSize() public {
        if (!forked) return;

        uint256[5] memory sizes = [uint256(1_000000), 5_000000, 10_000000, 50_000000, 200_000000];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amountIn = sizes[i];
            uint256 refOut = policy.referenceValue(RUSDG, TSLA, amountIn);

            uint256 snap = vm.snapshotState();
            IOpenMintERC20(RUSDG).mint(user, amountIn);
            vm.startPrank(user);
            IERC20(RUSDG).approve(address(basket), type(uint256).max);

            JayoBasket.Allocation[] memory one = new JayoBasket.Allocation[](1);
            one[0] = JayoBasket.Allocation({asset: TSLA, weightBps: 10_000});

            try basket.create(one, amountIn, block.timestamp + 1 hours) returns (uint256 id) {
                (, uint256[] memory got) = basket.holdingsOf(id);
                uint256 shortfallBps = (refOut - got[0]) * 10_000 / refOut;
                console2.log("rUSDG in (1e6):", amountIn);
                console2.log("   shortfall vs reference, bps:", shortfallBps);
            } catch {
                console2.log("rUSDG in (1e6):", amountIn);
                console2.log("   REFUSED at the configured floor");
            }
            vm.stopPrank();
            vm.revertToState(snap);
        }
    }

    /// @notice Copying spends the copier's own money and takes nothing from the
    ///         source, against real pools rather than a fixture.
    function test_CopyIsFundedByTheCopier() public {
        if (!forked) return;

        vm.startPrank(user);
        IERC20(RUSDG).approve(address(basket), type(uint256).max);
        uint256 source = basket.create(_alloc(), 20_000000, block.timestamp + 1 hours);
        vm.stopPrank();

        (, uint256[] memory sourceBefore) = basket.holdingsOf(source);

        // Smaller than the source on purpose. The copy trades immediately after
        // it, further along the same curve, and the AMZN pool is the shallower of
        // the two - a second 10 rUSDG leg there lands past the 300 bps floor and
        // is refused. That is the protection working, not a bug, so the test
        // demonstrates copying at a size the venue can actually fill.
        address copier = makeAddr("copier");
        IOpenMintERC20(RUSDG).mint(copier, 8_000000);

        vm.startPrank(copier);
        IERC20(RUSDG).approve(address(basket), type(uint256).max);
        uint256 copy = basket.copyAllocation(source, 8_000000, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(basket.ownerOf(copy), copier, "the copy belongs to the copier");
        assertEq(basket.ownerOf(source), user, "the source is untouched");

        (, uint256[] memory sourceAfter) = basket.holdingsOf(source);
        assertEq(sourceAfter[0], sourceBefore[0], "source keeps its TSLA");
        assertEq(sourceAfter[1], sourceBefore[1], "source keeps its AMZN");

        assertEq(IERC20(RUSDG).balanceOf(copier), 0, "the copier paid");
    }
}
