// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Sanity checks on the harness itself. If these fail, no comparison built
///         on top of the harness means anything.
contract SmokeTest is HookFenceFixture {
    function test_Fixture_PoolsArePricedNearTheReference() public {
        _giveTrader(10e18);

        uint256 refValue = policy.referenceValue(address(stock), address(usdg), 10e18);
        console2.log("reference USDG for 10 stock tokens (6dp):", refValue);

        // 10 tokens at $255 with USDG at $1 == 2550 USDG == 2_550_000_000 raw.
        assertEq(refValue, 2_550_000_000, "reference value should be exactly 2550 USDG");

        // Now confirm the pool actually fills near that, on the honest pool, with a
        // quote-context gas price so the adversarial logic is irrelevant here.
        vm.startPrank(trader);
        stock.approve(address(baselineRouter), type(uint256).max);
        uint256 out = baselineRouter.swapExactIn(honestKey, _zeroForOne(), 10e18, 0, trader);
        vm.stopPrank();

        console2.log("honest pool fill (6dp):", out);
        // Within 1% of refValue: 0.3% fee plus a little price impact.
        assertApproxEqRel(out, refValue, 0.01e18, "honest pool should fill near reference");
    }

    function test_Fixture_HooksShareIdenticalPermissions() public view {
        assertEq(
            uint160(address(honestHook)) & 0x3FFF,
            uint160(address(adversarialHook)) & 0x3FFF,
            "both hooks must carry identical permission flags"
        );
    }

    function test_Fixture_MockMatchesLiveStockTokenSurface() public view {
        // Values read from AAPL on Robinhood Chain mainnet, 2026-09-20.
        assertEq(stock.decimals(), 18, "stock tokens are 18 decimals");
        assertEq(usdg.decimals(), 6, "USDG is 6 decimals");
        assertEq(stockFeed.decimals(), 8, "feeds are 8 decimals");
        assertEq(stock.uiMultiplier(), 1_000_566_080_061_092_436, "live AAPL multiplier");
        assertEq(stock.oraclePaused(), false);
    }
}
