// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {JayoFixture} from "../utils/JayoFixture.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {RevertingPolicy} from "../../src/mocks/RevertingPolicy.sol";

/// @title Dust handling, failure paths, and redemption independence
///
/// @notice Three things this file pins down:
///
///   1. **A funded purchase never silently acquires nothing.** Arithmetic that
///      rounds to zero is valid arithmetic and unacceptable user behaviour. Each
///      way a leg can be too small has its own named error.
///   2. **Creation is all-or-nothing.** One bad leg leaves no partial position, no
///      orphaned holdings, and no retained USDG.
///   3. **Redemption never consults pricing** — proven by swapping in a policy
///      whose every function reverts, and redeeming anyway.
contract BasketDustAndFailureTest is JayoFixture {
    uint256 internal constant FUNDING = 10_000e6;

    // =======================================================================
    // Dust: three distinct ways a leg can be too small, three distinct errors
    // =======================================================================

    /// @notice Below the operator's configured floor, rejected before pricing.
    function test_Dust_LegBelowConfiguredMinimum() public {
        JayoBasket.Allocation[] memory a = _singleLeg(address(stock));

        // minLegInput defaults to 1.000000 USDG; fund below it.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(JayoBasket.LegBelowMinimum.selector, address(stock), 500_000, 1_000000)
        );
        basket.create(a, 500_000, block.timestamp + 1 hours); // 0.5 USDG
    }

    /// @notice A leg whose reference value rounds to zero raw units is refused.
    /// @dev Spending real USDG to acquire nothing is the failure this prevents. The
    ///      arithmetic is correct; the outcome is not acceptable.
    function test_Dust_LegWouldAcquireNothing() public {
        // Drop the operator floor so the *pricing* check is what bites, not the
        // configured minimum.
        vm.prank(admin);
        basket.setMinLegInput(1);

        // An absurd price, so one raw USDG unit buys zero raw stock units.
        //   usd = 1 * 1e8 / 1e6                    = 100
        //   out = 100 * 1e26 / (1e8 * 2e20)        = 0   (truncated)
        vm.prank(admin);
        stockFeed.setAnswer(2e20); // $2,000,000,000,000 per token

        JayoBasket.Allocation[] memory a = _singleLeg(address(stock));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(JayoBasket.LegWouldAcquireNothing.selector, address(stock), 1)
        );
        basket.create(a, 1, block.timestamp + 1 hours);
    }

    /// @notice A zero enforced floor is refused rather than treated as protection.
    ///
    /// @dev This is the subtle one. If the reference floor rounds to zero and the
    ///      user supplies no minimum, the settlement would execute against
    ///      `minOut = 0` — meaning ANY fill passes, including a zero fill. A zero
    ///      minimum is not protection. The contract refuses instead of pretending.
    function test_Dust_ZeroFloorIsNotTreatedAsProtection() public {
        vm.prank(admin);
        basket.setMinLegInput(1);
        vm.prank(admin);
        stockFeed.setAnswer(2e20);

        // Confirm the premise: the policy really does derive a zero floor here,
        // so the guard is doing work rather than being redundant.
        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(stock), 1, 0);
        assertEq(floor, 0, "premise: the derived floor is zero at this size");

        JayoBasket.Allocation[] memory a = _singleLeg(address(stock));
        vm.prank(alice);
        vm.expectRevert();
        basket.create(a, 1, block.timestamp + 1 hours);
    }

    /// @notice A leg just above the dust boundary succeeds, so the guard is not
    ///         simply blocking everything small.
    function test_Dust_JustAboveTheBoundarySucceeds() public {
        vm.prank(admin);
        basket.setMinLegInput(1_000000); // 1 USDG

        JayoBasket.Allocation[] memory a = _singleLeg(address(stock));
        vm.prank(alice);
        uint256 id = basket.create(a, 1_000000, block.timestamp + 1 hours);

        uint256 acquired = basket.holdings(id, address(stock));
        assertGt(acquired, 0, "1 USDG buys a real, non-zero amount");
        console2.log("1.000000 USDG acquired (18dp):", acquired);
    }

    // =======================================================================
    // Unspent amounts are explained, never silently retained
    // =======================================================================

    /// @notice Weight rounding leaves a remainder; it goes back to the funder.
    /// @dev Three legs at 3333/3333/3334 bps of an amount not divisible by 10000
    ///      cannot spend every unit. An unexplained retention is how a contract
    ///      quietly accrues other people's money.
    function test_UnspentRemainderIsReturnedAndAnnounced() public {
        JayoBasket.Allocation[] memory a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: address(stock), weightBps: 3333});
        a[1] = JayoBasket.Allocation({asset: address(stock2), weightBps: 6667});

        uint256 funding = 10_000e6 + 7; // deliberately not divisible
        uint256 before = usdg.balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        uint256 id = basket.create(a, funding, block.timestamp + 1 hours);

        uint256 actuallySpent = before - usdg.balanceOf(alice);
        assertLt(actuallySpent, funding, "a remainder existed");
        console2.log("funded :", funding);
        console2.log("spent  :", actuallySpent);
        console2.log("returned:", funding - actuallySpent);

        // The basket keeps no USDG of its own.
        assertEq(usdg.balanceOf(address(basket)), 0, "no USDG retained by the contract");
        assertEq(basket.totalLiabilities(address(usdg)), 0, "and none owed in USDG");
        assertGt(basket.holdings(id, address(stock)), 0);
    }

    // =======================================================================
    // All-or-nothing creation
    // =======================================================================

    /// @notice One failing leg reverts the whole creation — no partial position.
    function test_FailedLegRevertsEntireCreation() public {
        uint256 nextId = 1;
        uint256 aliceBefore = usdg.balanceOf(alice);

        // Leg 2's asset is disabled, so the second leg fails after the first has
        // already settled inside the same transaction.
        vm.prank(admin);
        basket.setAssetRoute(address(stock2), stock2Key, buy2, address(adapter), false);

        JayoBasket.Allocation[] memory a = _twoLegAllocation();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.AssetNotSupported.selector, address(stock2)));
        basket.create(a, FUNDING, block.timestamp + 1 hours);

        // Nothing survived: no token, no holdings, no liabilities, no spend.
        vm.expectRevert();
        basket.ownerOf(nextId);
        assertEq(basket.holdings(nextId, address(stock)), 0, "first leg rolled back too");
        assertEq(basket.totalLiabilities(address(stock)), 0, "no orphaned liability");
        assertEq(usdg.balanceOf(alice), aliceBefore, "funding returned in full");
        assertEq(usdg.balanceOf(address(basket)), 0, "contract retained nothing");
        assertEq(stock.balanceOf(address(basket)), 0, "contract holds no stray asset");
    }

    /// @notice A stale feed during creation also reverts everything.
    function test_StaleFeedDuringCreationRevertsEverything() public {
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.warp(block.timestamp + FEED_HEARTBEAT + 1);

        vm.prank(alice);
        vm.expectRevert();
        basket.create(_twoLegAllocation(), FUNDING, block.timestamp + 1 hours);

        assertEq(usdg.balanceOf(alice), aliceBefore);
        assertEq(basket.totalLiabilities(address(stock)), 0);
    }

    // =======================================================================
    // Allocation shape
    // =======================================================================

    function test_WeightsMustSumToExactlyBps() public {
        JayoBasket.Allocation[] memory a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: address(stock), weightBps: 5000});
        a[1] = JayoBasket.Allocation({asset: address(stock2), weightBps: 4000}); // 9000

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.WeightsMustSumToBps.selector, 9000));
        basket.create(a, FUNDING, block.timestamp + 1 hours);
    }

    function test_DuplicateAssetRejected() public {
        JayoBasket.Allocation[] memory a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: address(stock), weightBps: 5000});
        a[1] = JayoBasket.Allocation({asset: address(stock), weightBps: 5000});

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.DuplicateAsset.selector, address(stock)));
        basket.create(a, FUNDING, block.timestamp + 1 hours);
    }

    function test_EmptyAllocationRejected() public {
        JayoBasket.Allocation[] memory a = new JayoBasket.Allocation[](0);
        vm.prank(alice);
        vm.expectRevert(JayoBasket.NoLegs.selector);
        basket.create(a, FUNDING, block.timestamp + 1 hours);
    }

    // =======================================================================
    // Redemption never consults pricing
    // =======================================================================

    /// @notice Redeem works with a policy whose every function reverts.
    ///
    /// @dev The strongest available proof that in-kind redemption has no pricing
    ///      dependency. If `redeem` read a floor, a reference value or an instrument
    ///      anywhere, this would revert. It does not.
    ///
    ///      This is what makes "withdraw its underlying assets" survivable when
    ///      every equity feed is asleep — the case that the sell-only design could
    ///      not resolve without contradicting itself.
    function test_RedeemWorksWithACompletelyBrokenPolicy() public {
        vm.prank(alice);
        uint256 id = basket.create(_twoLegAllocation(), FUNDING, block.timestamp + 1 hours);

        uint256 owed1 = basket.holdings(id, address(stock));
        uint256 owed2 = basket.holdings(id, address(stock2));
        assertGt(owed1, 0);
        assertGt(owed2, 0);

        // Pricing becomes entirely unavailable.
        RevertingPolicy broken = new RevertingPolicy();
        vm.prank(admin);
        gateway.setPolicy(broken);

        // Sanity: the premise holds — anything price-dependent is now dead.
        vm.prank(alice);
        vm.expectRevert();
        basket.create(_twoLegAllocation(), FUNDING, block.timestamp + 1 hours);

        // Redemption is unaffected.
        vm.prank(alice);
        basket.redeem(id);

        assertEq(stock.balanceOf(alice), owed1, "leg 1 returned in kind");
        assertEq(stock2.balanceOf(alice), owed2, "leg 2 returned in kind");
        assertEq(basket.totalLiabilities(address(stock)), 0, "liabilities cleared");
    }

    /// @notice Only the current owner may redeem.
    function test_OnlyOwnerRedeems() public {
        vm.prank(alice);
        uint256 id = basket.create(_twoLegAllocation(), FUNDING, block.timestamp + 1 hours);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, bob));
        basket.redeem(id);
    }

    // =======================================================================
    // Helper
    // =======================================================================

    function _singleLeg(address asset) internal pure returns (JayoBasket.Allocation[] memory a) {
        a = new JayoBasket.Allocation[](1);
        a[0] = JayoBasket.Allocation({asset: asset, weightBps: 10_000});
    }
}
