// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "./HookFenceFixture.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";

/// @notice Extends the Phase 0 harness with a SECOND Stock Token, so a basket has
///         more than one leg and leg isolation can actually be tested.
///
/// @dev MOCKED: both Stock Tokens, USDG, both Chainlink feeds, both hooks and all
///      pool liquidity. REAL: the `v4-core` PoolManager, so swap accounting, tick
///      maths, hook dispatch and settlement are genuine Uniswap v4.
abstract contract JayoFixture is HookFenceFixture {
    JayoBasket internal basket;

    /// @notice Second instrument, so a basket is not trivially single-asset.
    MockStockToken internal stock2;
    MockAggregatorV3 internal stock2Feed;
    PoolKey internal stock2Key;
    bool internal stock2IsCurrency0;

    /// @dev Direction that BUYS the asset with USDG.
    bool internal buy1;
    bool internal buy2;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    /// @dev $150.00, 8 dp - deliberately a different price from stock 1 so a
    ///      leg-attribution bug produces visibly wrong numbers rather than
    ///      plausible ones.
    int256 internal constant STOCK2_USD = 150_00000000;

    function setUp() public virtual override {
        super.setUp();

        buy1 = !_zeroForOne();

        _deploySecondInstrument();
        _deployBasket();
        _fundUsers();
    }

    function _deploySecondInstrument() internal {
        stock2 = new MockStockToken("Nvidia  Robinhood Token", "NVDA");
        stock2Feed = new MockAggregatorV3(FEED_DECIMALS, STOCK2_USD, "Robinhood NVDA / USD");
        stock2IsCurrency0 = address(stock2) < address(usdg);

        (Currency c0, Currency c1) = stock2IsCurrency0
            ? (Currency.wrap(address(stock2)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock2)));
        stock2Key =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(honestHook))});

        // Buying stock2 with USDG is the direction opposite to selling it.
        buy2 = !stock2IsCurrency0;

        uint256 rawStock = 10 ** STOCK_DECIMALS;
        uint256 rawUsdg = uint256(STOCK2_USD) * (10 ** USDG_DECIMALS) / (10 ** FEED_DECIMALS);
        (uint256 a0, uint256 a1) = stock2IsCurrency0 ? (rawStock, rawUsdg) : (rawUsdg, rawStock);
        poolManager.initialize(stock2Key, _encodeSqrtPriceX96(a1, a0));

        uint256 stockAmount = 40_000e18;
        uint256 usdgAmount = 40_000 * 150 * 1e6;
        stock2.mint(lp, stockAmount * 4);
        usdg.mint(lp, usdgAmount * 4);

        vm.startPrank(lp);
        stock2.approve(address(liquidityRouter), type(uint256).max);
        usdg.approve(address(liquidityRouter), type(uint256).max);
        (uint256 amt0, uint256 amt1) = stock2IsCurrency0 ? (stockAmount, usdgAmount) : (usdgAmount, stockAmount);
        liquidityRouter.addLiquidity(
            stock2Key,
            TICK_LOWER,
            TICK_UPPER,
            int256(uint256(_liquidityForAmounts(_encodeSqrtPriceX96(a1, a0), amt0, amt1)))
        );
        vm.stopPrank();

        vm.prank(admin);
        policy.setStockToken(address(stock2), address(stock2Feed), FEED_HEARTBEAT, MAX_SHORTFALL_BPS);
    }

    function _deployBasket() internal {
        vm.startPrank(admin);
        basket = new JayoBasket(gateway, IERC20(address(usdg)), admin);

        // Buy routes for both instruments.
        adapter.setRoute(honestKey, buy1, true);
        adapter.setRoute(stock2Key, buy2, true);

        basket.setAssetRoute(address(stock), honestKey, buy1, address(adapter), true);
        basket.setAssetRoute(address(stock2), stock2Key, buy2, address(adapter), true);
        vm.stopPrank();
    }

    function _fundUsers() internal {
        address[3] memory users = [alice, bob, mallory];
        for (uint256 i; i < users.length; ++i) {
            usdg.mint(users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdg.approve(address(basket), type(uint256).max);
        }
        vm.txGasPrice(2 gwei);
    }

    /// @notice A standard two-leg allocation: 60% instrument 1, 40% instrument 2.
    function _twoLegAllocation() internal view returns (JayoBasket.Allocation[] memory a) {
        a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: address(stock), weightBps: 6000});
        a[1] = JayoBasket.Allocation({asset: address(stock2), weightBps: 4000});
    }

    /// @notice Republish every feed at the current timestamp.
    function _refreshAllFeeds() internal {
        stockFeed.setAnswer(AAPL_USD);
        stock2Feed.setAnswer(STOCK2_USD);
        usdgFeed.setAnswer(USDG_USD);
    }
}
