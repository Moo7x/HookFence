// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {JayoFixture} from "../utils/JayoFixture.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {RevertingPolicy} from "../../src/mocks/RevertingPolicy.sol";

/// @title Taking part of a position out
///
/// @notice `redeem` was all or nothing: wanting one leg back cost you the
///         position, its allocation record and any manager you had appointed,
///         and cost two more round trips through the pool to rebuild.
///
/// @dev The property that has to survive is the one the whole design rests on:
///      these paths read no price. `test_PartialExitsWorkWithTheWholePolicyDead`
///      proves it the same way `redeem` is proven — by pointing the gateway at a
///      policy whose every function reverts.
contract PartialRedeemTest is JayoFixture {
    uint256 internal constant FUND = 10_000e6;

    uint256 internal id;

    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        id = basket.create(_twoLegAllocation(), FUND, block.timestamp + 1 hours);
    }

    function _held(uint256 tokenId, address asset) internal view returns (uint256) {
        return basket.holdings(tokenId, asset);
    }

    // =======================================================================
    // One asset
    // =======================================================================

    function test_RedeemAssetDeliversThatLegAndKeepsTheRest() public {
        uint256 s1Before = _held(id, address(stock));
        uint256 stock2Before = _held(id, address(stock2));
        assertGt(s1Before, 0);
        assertGt(stock2Before, 0);

        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));

        assertEq(IERC20(address(stock2)).balanceOf(alice), stock2Before, "the leg arrived in full");
        assertEq(_held(id, address(stock2)), 0, "and is gone from the ledger");
        assertEq(_held(id, address(stock)), s1Before, "the other leg is untouched");
        assertEq(basket.ownerOf(id), alice, "the position survives");

        (address[] memory assets,) = basket.holdingsOf(id);
        assertEq(assets.length, 1, "one leg left");
        assertEq(assets[0], address(stock), "and it is the right one");
    }

    /// @notice The invariant is `<=`, never `==`: a donation would break equality.
    function test_SolvencyHoldsAfterAPartialExit() public {
        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));

        assertLe(basket.totalLiabilities(address(stock2)), stock2.balanceOf(address(basket)), "instrument 2");
        assertLe(basket.totalLiabilities(address(stock)), stock.balanceOf(address(basket)), "instrument 1");
        assertEq(basket.totalLiabilities(address(stock2)), 0, "nothing is still owed in instrument 2");
    }

    function test_RedeemAssetRefusesALegThePositionDoesNotHold() public {
        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));

        vm.expectRevert(abi.encodeWithSelector(JayoBasket.AssetNotHeld.selector, id, address(stock2)));
        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));
    }

    function test_OnlyTheOwnerCanTakeALegOut() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, stranger));
        vm.prank(stranger);
        basket.redeemAsset(id, address(stock2));
    }

    /// @notice A recorded delegate grants no action at all today; above all it
    ///         must never be able to take assets out.
    function test_AManagerStillCannotTakeALegOut() public {
        address manager = makeAddr("manager");
        vm.prank(alice);
        basket.setManager(id, manager);

        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, manager));
        vm.prank(manager);
        basket.redeemAsset(id, address(stock2));
    }

    /// @notice Emptying every leg one at a time leaves an empty position, not a
    ///         burnt one. Closing it is still `redeem`'s job.
    function test_TakingEveryLegOutLeavesAnEmptyPositionTheOwnerStillHolds() public {
        vm.startPrank(alice);
        basket.redeemAsset(id, address(stock));
        basket.redeemAsset(id, address(stock2));
        vm.stopPrank();

        assertEq(basket.ownerOf(id), alice, "still owned");
        (address[] memory assets,) = basket.holdingsOf(id);
        assertEq(assets.length, 0, "and empty");

        vm.prank(alice);
        basket.redeem(id); // closes it without reverting on the empty leg list
        vm.expectRevert();
        basket.ownerOf(id);
    }

    // =======================================================================
    // A fraction of everything
    // =======================================================================

    function test_RedeemFractionTakesTheSameShareOfEveryLeg() public {
        uint256 s1Before = _held(id, address(stock));
        uint256 stock2Before = _held(id, address(stock2));

        vm.prank(alice);
        basket.redeemFraction(id, 2500); // a quarter

        assertEq(IERC20(address(stock)).balanceOf(alice), s1Before / 4, "instrument 1 quarter");
        assertEq(IERC20(address(stock2)).balanceOf(alice), stock2Before / 4, "instrument 2 quarter");
        assertEq(_held(id, address(stock)), s1Before - s1Before / 4, "instrument 1 remainder stays");
        assertEq(_held(id, address(stock2)), stock2Before - stock2Before / 4, "instrument 2 remainder stays");
        assertEq(basket.ownerOf(id), alice, "the position survives");
    }

    /// @notice Truncation must favour the position, never the caller.
    function test_RoundingLeavesTheDustInTheBasket() public {
        uint256 s1Before = _held(id, address(stock));

        vm.prank(alice);
        basket.redeemFraction(id, 3333);

        uint256 out = IERC20(address(stock)).balanceOf(alice);
        assertLe(out * 10_000, s1Before * 3333, "never more than the share");
        assertEq(_held(id, address(stock)) + out, s1Before, "nothing is lost or created");
        assertLe(basket.totalLiabilities(address(stock)), stock.balanceOf(address(basket)), "solvent");
    }

    function test_FullFractionEmptiesEveryLegButKeepsThePosition() public {
        vm.prank(alice);
        basket.redeemFraction(id, 10_000);

        (address[] memory assets,) = basket.holdingsOf(id);
        assertEq(assets.length, 0, "no legs left");
        assertEq(basket.ownerOf(id), alice, "the position is still theirs");
        assertEq(basket.totalLiabilities(address(stock)), 0, "nothing owed");
        assertEq(basket.totalLiabilities(address(stock2)), 0, "nothing owed");
    }

    function test_FractionOutOfRangeIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.FractionOutOfRange.selector, uint16(0)));
        vm.prank(alice);
        basket.redeemFraction(id, 0);

        vm.expectRevert(abi.encodeWithSelector(JayoBasket.FractionOutOfRange.selector, uint16(10_001)));
        vm.prank(alice);
        basket.redeemFraction(id, 10_001);
    }

    /// @notice A share too small to deliver anything is refused rather than
    ///         emitting a successful withdrawal of nothing.
    function test_AFractionThatWouldDeliverNothingIsRefused() public {
        vm.prank(alice);
        basket.redeemFraction(id, 10_000); // empty it first

        vm.expectRevert(abi.encodeWithSelector(JayoBasket.FractionWouldDeliverNothing.selector, id, uint16(1)));
        vm.prank(alice);
        basket.redeemFraction(id, 1);
    }

    // =======================================================================
    // The property that matters
    // =======================================================================

    /// @notice Neither path may touch pricing. Proven by making pricing impossible:
    ///         every function on this policy reverts.
    function test_PartialExitsWorkWithTheWholePolicyDead() public {
        vm.prank(alice);
        uint256 secondId = basket.create(_twoLegAllocation(), FUND, block.timestamp + 1 hours);

        // Build it BEFORE arming the prank: a CREATE is an external call and
        // consumes the prank, so `setPolicy` would then run as the test contract
        // and fail on access control. This has bitten this repo three times.
        RevertingPolicy broken = new RevertingPolicy();
        vm.prank(admin);
        gateway.setPolicy(broken);

        uint256 stock2Before = _held(id, address(stock2));
        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));
        assertEq(IERC20(address(stock2)).balanceOf(alice), stock2Before, "one leg out, no oracle");

        vm.prank(alice);
        basket.redeemFraction(secondId, 5000);
        assertGt(IERC20(address(stock)).balanceOf(alice), 0, "half out, no oracle");
    }

    /// @notice Transferring a position carries whatever it still holds, and the
    ///         previous owner loses the partial-exit paths too.
    function test_PartialExitFollowsOwnershipOnTransfer() public {
        address buyer = makeAddr("buyer");

        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));

        vm.prank(alice);
        basket.transferFrom(alice, buyer, id);

        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, alice));
        vm.prank(alice);
        basket.redeemFraction(id, 5000);

        uint256 s1Held = _held(id, address(stock));
        vm.prank(buyer);
        basket.redeemFraction(id, 10_000);
        assertEq(IERC20(address(stock)).balanceOf(buyer), s1Held, "the new owner gets it");
    }
}
