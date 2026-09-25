// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {V4ExactInputAdapter} from "../../src/adapters/V4ExactInputAdapter.sol";
import {JayoBasket} from "../../src/basket/JayoBasket.sol";

/// @title What Jayo costs on Robinhood Chain MAINNET state, next to doing it by hand
///
/// @notice Forks chain 4663 and configures Jayo exactly as a mainnet deployment
///         would be: real Paxos USDG, the canonical TSLA and AMZN Stock Tokens,
///         Chainlink's published Robinhood feeds as the reference (NOT a pool-
///         derived price - on mainnet the reference is independent), a 50 bps
///         floor, and the deepest hookless USDG pool for each asset.
///
///         For each basket size it measures, from the SAME starting state:
///           Jayo    approve once + create (both legs in one transaction)
///           manual  approve once + two separate swaps through the same pools
///         and then what handing the result to someone costs each way.
///
///         Nothing here is broadcast. It is a fork: real state, simulated
///         transactions. Skips itself if the RPC is unreachable or if the equity
///         feeds are stale (they publish 24/5; on a weekend Jayo correctly refuses).
///
///           forge test --match-contract MainnetForkCost -vv
///           MAINNET_FORK_BLOCK=71413360 forge test --match-contract MainnetForkCost -vv
///
///      Pin a block to reproduce a result. Live mainnet state moves: on
///      2026-09-24, about twenty minutes apart, the AMZN pool went from 15 bps to
///      66 bps below Chainlink at demo size, and Jayo went from accepting to
///      refusing. Both runs are recorded in docs/MAINNET_FORK_COST.md.
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

interface IAggLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract MainnetForkCostTest is Test {
    string constant RPC = "https://rpc.mainnet.chain.robinhood.com";

    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // Canonical addresses from docs.robinhood.com/chain/contracts (on-chain registry).
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    // Chainlink, from feeds-robinhood-mainnet.json.
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant AMZN_FEED = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C;

    uint32 constant HEARTBEAT = 86_400;
    uint16 constant MAINNET_FLOOR_BPS = 50;

    StockTokenReferencePolicy policy;
    ExecutionGateway gateway;
    V4ExactInputAdapter adapter;
    JayoBasket basket;
    PoolSwapTest router;
    PoolKey tslaKey;
    PoolKey amznKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bool ready;

    function setUp() public {
        uint256 pin = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            try vm.createSelectFork(RPC) {} catch { return; }
        } else {
            try vm.createSelectFork(RPC, pin) {} catch { return; }
        }
        require(block.chainid == 4663, "forked the wrong chain");

        // The deepest hookless USDG pools, found by scripts/find-routes.mjs.
        tslaKey = _key(TSLA, 3000, 60);   // ~10.0M USDG active, -0.16% vs Chainlink
        amznKey = _key(AMZN, 2400, 24);   // ~562k USDG active,  -0.13% vs Chainlink

        policy = new StockTokenReferencePolicy(keccak256("Jayo.StockTokenBasket.v1"), address(this));
        policy.setQuoteAsset(USDG, USDG_FEED, HEARTBEAT, 6);
        policy.setStockToken(TSLA, TSLA_FEED, HEARTBEAT, MAINNET_FLOOR_BPS);
        policy.setStockToken(AMZN, AMZN_FEED, HEARTBEAT, MAINNET_FLOOR_BPS);

        gateway = new ExecutionGateway(address(this), policy);
        adapter = new V4ExactInputAdapter(IPoolManager(PM), address(this));
        adapter.setGateway(address(gateway));
        gateway.setAdapter(address(adapter), true);
        basket = new JayoBasket(gateway, IERC20(USDG), address(this), 1);
        _route(TSLA, tslaKey);
        _route(AMZN, amznKey);

        router = new PoolSwapTest(IPoolManager(PM));

        // Feeds publish 24/5. If they are stale, Jayo refuses to buy - correct, but
        // then there is nothing to measure.
        try policy.requiredMinOut(USDG, TSLA, 1e6, 0) {} catch { console2.log("equity feeds stale: skipping"); return; }
        try policy.requiredMinOut(USDG, AMZN, 1e6, 0) {} catch { console2.log("equity feeds stale: skipping"); return; }
        ready = true;
    }

    function _key(address stock, uint24 fee, int24 spacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = USDG < stock ? (USDG, stock) : (stock, USDG);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(0)));
    }

    function _route(address stock, PoolKey memory key) internal {
        bool buy = USDG < stock; // spending USDG
        adapter.setRoute(key, buy, true);
        adapter.setRoute(key, !buy, true);
        basket.setAssetRoute(stock, key, buy, address(adapter), true);
    }

    function _fund(address who, uint256 amount) internal {
        // USDG is a proxy; move real balance out of the PoolManager rather than
        // guess the storage layout. Fork only.
        vm.prank(PM);
        IERC20(USDG).transfer(who, amount);
    }

    function _alloc() internal pure returns (JayoBasket.Allocation[] memory a) {
        a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: TSLA, weightBps: 6000});
        a[1] = JayoBasket.Allocation({asset: AMZN, weightBps: 4000});
    }

    function _manualSwap(PoolKey memory key, address stock, uint256 usdgIn) internal returns (uint256 out) {
        bool zeroForOne = USDG < stock;
        uint256 before = IERC20(stock).balanceOf(alice);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(usdgIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        out = IERC20(stock).balanceOf(alice) - before;
    }

    struct Result {
        bool accepted;
        bytes revertData;
        uint256 jayoTsla; uint256 jayoAmzn; uint256 jayoGas;
        uint256 manTsla; uint256 manAmzn; uint256 manGas;
        uint256 refTsla; uint256 refAmzn;
        uint256 floorTsla; uint256 floorAmzn;
        uint256 nftHandoverGas; uint256 erc20HandoverGas; uint256 exitGas;
        uint256 jayoApproveGas; uint256 manApproveGas;
        uint256 bobTslaViaJayo; uint256 bobAmznViaJayo;
    }

    /// @dev Execution gas plus 21,000 intrinsic per transaction. Calldata cost and
    ///      the chain's L1 data fee are not included.
    uint256 constant INTRINSIC = 21_000;
    // No ETH/USD read here on purpose: the public RPC is not an archive node, and
    // a pinned-block run can only use state this machine has already cached.
    // Dollar figures are derived in docs/MAINNET_FORK_COST.md from the gas and
    // base fee printed below.

    function _measure(uint256 usdgIn) internal returns (Result memory r) {
        uint256 legT = usdgIn * 6000 / 10_000;
        uint256 legA = usdgIn - legT;
        r.refTsla = policy.referenceValue(USDG, TSLA, legT);
        r.refAmzn = policy.referenceValue(USDG, AMZN, legA);
        (r.floorTsla,) = policy.requiredMinOut(USDG, TSLA, legT, 0);
        (r.floorAmzn,) = policy.requiredMinOut(USDG, AMZN, legA, 0);

        _fund(alice, usdgIn * 2);
        uint256 snap = vm.snapshotState();

        // ---- Jayo: one approval, one transaction for both legs
        vm.startPrank(alice);
        uint256 g = gasleft();
        IERC20(USDG).approve(address(basket), type(uint256).max);
        r.jayoApproveGas = g - gasleft();
        g = gasleft();
        uint256 id;
        try basket.create(_alloc(), usdgIn, block.timestamp + 1 hours) returns (uint256 newId) {
            id = newId;
            r.accepted = true;
        } catch (bytes memory reason) {
            r.revertData = reason;
            // Refused by the floor. Still measure what a direct swap would have
            // delivered, so the refusal can be stated in bps rather than asserted.
            vm.stopPrank();
            vm.revertToState(snap);
            vm.startPrank(alice);
            IERC20(USDG).approve(address(router), type(uint256).max);
            r.manTsla = _manualSwap(tslaKey, TSLA, legT);
            r.manAmzn = _manualSwap(amznKey, AMZN, legA);
            vm.stopPrank();
            vm.revertToState(snap);
            return r;
        }
        r.jayoGas = g - gasleft();
        (, uint256[] memory held) = basket.holdingsOf(id);
        r.jayoTsla = held[0];
        r.jayoAmzn = held[1];
        g = gasleft();
        basket.safeTransferFrom(alice, bob, id);
        r.nftHandoverGas = g - gasleft();
        vm.stopPrank();
        vm.prank(bob);
        g = gasleft();
        basket.redeem(id);
        r.exitGas = g - gasleft();
        r.bobTslaViaJayo = IERC20(TSLA).balanceOf(bob);
        r.bobAmznViaJayo = IERC20(AMZN).balanceOf(bob);

        vm.revertToState(snap);

        // ---- manual: one approval, two swaps through the same pools
        vm.startPrank(alice);
        g = gasleft();
        IERC20(USDG).approve(address(router), type(uint256).max);
        r.manApproveGas = g - gasleft();
        g = gasleft();
        r.manTsla = _manualSwap(tslaKey, TSLA, legT);
        r.manAmzn = _manualSwap(amznKey, AMZN, legA);
        r.manGas = g - gasleft();
        g = gasleft();
        IERC20(TSLA).transfer(bob, r.manTsla);
        IERC20(AMZN).transfer(bob, r.manAmzn);
        r.erc20HandoverGas = g - gasleft();
        vm.stopPrank();

        vm.revertToState(snap);
    }

    function _bps(uint256 got, uint256 ref) internal pure returns (int256) {
        return (int256(ref) - int256(got)) * 10_000 / int256(ref);
    }

    /// @notice Buy, hand to someone, and the recipient takes the tokens at once.
    ///         Jayo: approve, create, one NFT transfer, recipient redeems (4 tx).
    ///         Manual: approve, two swaps, two token transfers (5 tx); the recipient
    ///         already holds the tokens, so there is no withdrawal step.
    function _totals(Result memory r) internal pure returns (uint256 jayo, uint256 manual) {
        jayo = r.jayoApproveGas + r.jayoGas + r.nftHandoverGas + r.exitGas + 4 * INTRINSIC;
        manual = r.manApproveGas + r.manGas + r.erc20HandoverGas + 5 * INTRINSIC;
    }

    function _report(uint256 usdgIn, Result memory r) internal pure {
        console2.log("=====================================================");
        console2.log("basket size, USDG (6dp):", usdgIn);
        if (!r.accepted) {
            console2.log("  REFUSED by the 50 bps floor. A direct swap of the same legs would have got:");
            console2.log("  TSLA, bps below Chainlink:");
            console2.logInt(_bps(r.manTsla, r.refTsla));
            console2.log("  AMZN, bps below Chainlink:");
            console2.logInt(_bps(r.manAmzn, r.refAmzn));
            return;
        }
        console2.log("  Jayo   TSLA (1e18):", r.jayoTsla);
        console2.log("  manual TSLA (1e18):", r.manTsla);
        console2.log("  Jayo   AMZN (1e18):", r.jayoAmzn);
        console2.log("  manual AMZN (1e18):", r.manAmzn);
        console2.log("  TSLA shortfall vs Chainlink, bps (negative = better than reference):");
        console2.logInt(_bps(r.jayoTsla, r.refTsla));
        console2.log("  AMZN shortfall vs Chainlink, bps:");
        console2.logInt(_bps(r.jayoAmzn, r.refAmzn));
        console2.log("  execution gas, Jayo create (1 tx):     ", r.jayoGas);
        console2.log("  execution gas, manual 2 swaps (2 tx):  ", r.manGas);
        console2.log("  hand-over gas, Jayo 1 NFT:             ", r.nftHandoverGas);
        console2.log("  hand-over gas, manual 2 ERC-20s:       ", r.erc20HandoverGas);
        console2.log("  recipient exit gas, Jayo redeem:       ", r.exitGas);
        (uint256 jt, uint256 mt) = _totals(r);
        console2.log("  BUY + HAND OVER + RECIPIENT WITHDRAWS AT ONCE (incl. 21k per tx):");
        console2.log("    Jayo, 4 tx, gas:                     ", jt);
        console2.log("    manual, 5 tx, gas:                   ", mt);
        console2.log("    recipient ends with the same TSLA and AMZN either way");
    }

    function _context() internal view {
        // block.number on an Arbitrum chain is the L1 block; the L2 block is ArbSys's.
        console2.log("fork block (L2):", IArbSys(address(0x64)).arbBlockNumber());
        console2.log("block time:", block.timestamp);
        (, int256 t,, uint256 tAt,) = IAggLike(TSLA_FEED).latestRoundData();
        (, int256 a,, uint256 aAt,) = IAggLike(AMZN_FEED).latestRoundData();
        console2.log("Chainlink TSLA (8dp):", uint256(t));
        console2.log("   age, s:", block.timestamp - tAt);
        console2.log("Chainlink AMZN (8dp):", uint256(a));
        console2.log("   age, s:", block.timestamp - aAt);
    }

    // =======================================================================

    /// @notice Every size is measured the same way; whether Jayo accepts it is a
    ///         result, not an assumption. A refused size must be one where a direct
    ///         swap would indeed have landed more than 50 bps below Chainlink.
    function test_MainnetCostBySize() public {
        if (!ready) return;
        _context();
        uint256[7] memory sizes = [uint256(20e6), 1_000e6, 2_500e6, 5_000e6, 7_500e6, 10_000e6, 25_000e6];
        for (uint256 i; i < sizes.length; ++i) {
            Result memory r = _measure(sizes[i]);
            _report(sizes[i], r);
            if (r.accepted) {
                // Same pools, same state, no protocol fee: Jayo must receive exactly
                // what a direct swap receives. Any difference would be a fee or a leak.
                assertEq(r.jayoTsla, r.manTsla, "TSLA: Jayo and a direct swap must match");
                assertEq(r.jayoAmzn, r.manAmzn, "AMZN: Jayo and a direct swap must match");
                assertGe(r.jayoTsla, r.floorTsla, "TSLA inside the floor");
                assertGe(r.jayoAmzn, r.floorAmzn, "AMZN inside the floor");
                // After the hand-over the recipient withdraws in kind and holds
                // exactly what a manual buyer would have handed over.
                assertEq(r.bobTslaViaJayo, r.manTsla, "recipient's TSLA");
                assertEq(r.bobAmznViaJayo, r.manAmzn, "recipient's AMZN");
            } else {
                // The EXACT revert: the gateway's OutputBelowFloor for the first leg,
                // in execution order, that a direct swap shows would fill below its
                // floor - with the received and required amounts to the unit.
                bytes memory expected = r.manTsla < r.floorTsla
                    ? abi.encodeWithSelector(ExecutionGateway.OutputBelowFloor.selector, r.manTsla, r.floorTsla)
                    : abi.encodeWithSelector(ExecutionGateway.OutputBelowFloor.selector, r.manAmzn, r.floorAmzn);
                assertEq(r.revertData, expected, "refused for exactly the floor, on exactly that leg");
                // The refusal must be justified against the policy's exact floor, not
                // a rounded percentage: at least one leg really would have come in below it.
                bool justified = r.manTsla < r.floorTsla || r.manAmzn < r.floorAmzn;
                assertTrue(justified, "refused a basket that a direct swap would have filled inside the floor");
            }
        }
        console2.log("base fee on the fork, wei:", block.basefee);
    }

}
