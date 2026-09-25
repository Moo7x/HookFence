// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {JayoFixture} from "../utils/JayoFixture.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {JayoRenderer} from "../../src/basket/JayoRenderer.sol";
import {IJayoRenderer} from "../../src/interfaces/IJayoRenderer.sol";

/// @title Adding money to an existing position, and the plan it is split by
///
/// @notice Version 2's product change: a position is not only created, it can be
///         added to - by its owner, or by anyone giving to its owner - and every
///         addition is bought by that position's own plan. The owner can change the
///         plan for future money; holdings are never rebalanced.
///
/// @dev MOCKED: both stock tokens, USDG, the feeds, the hook, pool liquidity.
///      REAL: the v4-core PoolManager, so every purchase is real v4 accounting.
contract ContributionsTest is JayoFixture {
    uint256 internal constant FUND = 10_000e6;
    uint256 internal constant GIFT = 2_500e6;

    address internal carol = makeAddr("carol");
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        usdg.mint(carol, 1_000_000e6);
        vm.prank(carol);
        usdg.approve(address(basket), type(uint256).max);

        vm.prank(alice);
        id = basket.create(_twoLegAllocation(), FUND, block.timestamp + 1 hours);
    }

    // =======================================================================
    // Contributing
    // =======================================================================

    function test_OwnerAddsToTheSamePosition() public {
        uint256 h1 = basket.holdings(id, address(stock));
        uint256 h2 = basket.holdings(id, address(stock2));

        vm.expectEmit(true, true, false, true, address(basket));
        emit JayoBasket.Contributed(id, alice, GIFT, GIFT, 1);
        vm.prank(alice);
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        assertGt(basket.holdings(id, address(stock)), h1, "leg 1 grew");
        assertGt(basket.holdings(id, address(stock2)), h2, "leg 2 grew");
        assertEq(basket.balanceOf(alice), 1, "no new token: the same position");
        assertEq(basket.nextTokenId(), basket.firstTokenId() + 1, "nothing new was minted");
        assertEq(basket.fundingCount(id), 2, "creation plus one addition");
        assertEq(basket.totalFunded(id), FUND + GIFT, "every rUSDG spent is counted");
        _assertSolvent();
    }

    function test_AnyoneCanAddAndOnlyTheOwnerBenefits() public {
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 h1 = basket.holdings(id, address(stock));

        vm.prank(bob);
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        assertEq(bobUsdg - usdg.balanceOf(bob), GIFT, "the contributor paid");
        assertEq(basket.balanceOf(bob), 0, "and holds nothing for it");
        assertEq(basket.ownerOf(id), alice, "ownership did not move");

        // Only the owner can take it out.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, bob));
        basket.redeemAsset(id, address(stock));

        uint256 owed = basket.holdings(id, address(stock));
        assertGt(owed, h1, "the gift is in the position");
        vm.prank(alice);
        basket.redeem(id);
        assertEq(IERC20(address(stock)).balanceOf(alice), owed, "the owner receives the gift in kind");
    }

    function test_AdditionIsSplitByThePlanAndMeetsEveryFloor() public {
        (uint256[] memory legIn,, uint256[] memory floors, uint256 unspent) = basket.previewContribute(id, GIFT);
        assertEq(legIn[0], GIFT * 6000 / 10_000, "60% to leg 1");
        assertEq(legIn[1], GIFT * 4000 / 10_000, "40% to leg 2");
        assertEq(unspent, 0);

        uint256 h1 = basket.holdings(id, address(stock));
        uint256 h2 = basket.holdings(id, address(stock2));
        vm.prank(carol);
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        assertGe(basket.holdings(id, address(stock)) - h1, floors[0], "leg 1 at or above its floor");
        assertGe(basket.holdings(id, address(stock2)) - h2, floors[1], "leg 2 at or above its floor");
    }

    function test_TheRoundingRemainderGoesBackToTheContributor() public {
        uint256 odd = GIFT + 1; // 60% and 40% of this each round down; 1 unit is left over
        uint256 before = usdg.balanceOf(carol);

        vm.expectEmit(true, true, false, true, address(basket));
        emit JayoBasket.UnspentReturned(id, carol, 1, "weight rounding remainder");
        vm.prank(carol);
        basket.contribute(id, odd, alice, 1, block.timestamp + 1 hours);

        assertEq(before - usdg.balanceOf(carol), GIFT, "charged only what was spent");
    }

    function test_AFailedLegRevertsTheWholeAddition() public {
        // The reference now says leg 1 is far cheaper than the pool: the pool
        // cannot meet the floor, so leg 1 must fail - and take leg 2 with it.
        stockFeed.setAnswer(AAPL_USD / 2);
        uint256 before = usdg.balanceOf(bob);
        uint256 h2 = basket.holdings(id, address(stock2));

        vm.prank(bob);
        vm.expectRevert();
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        assertEq(usdg.balanceOf(bob), before, "nothing charged");
        assertEq(basket.holdings(id, address(stock2)), h2, "no half-bought addition");
        assertEq(basket.fundingCount(id), 1);
    }

    function test_AdditionNeedsAFreshPriceWithdrawalDoesNot() public {
        vm.warp(block.timestamp + FEED_HEARTBEAT + 1);

        vm.prank(bob);
        vm.expectRevert();
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        vm.prank(alice);
        basket.redeemAsset(id, address(stock2)); // still works
    }

    function test_CannotAddToAPositionThatDoesNotExist() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        basket.contribute(999, GIFT, alice, 1, block.timestamp + 1 hours);

        vm.prank(alice);
        basket.redeem(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);
    }

    function test_AdditionRebuysAnAssetTheOwnerTookOut() public {
        vm.prank(alice);
        basket.redeemAsset(id, address(stock2));
        assertEq(basket.assetsOf(id).length, 1, "one asset left");

        vm.prank(carol);
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        assertEq(basket.assetsOf(id).length, 2, "the plan still includes it, so it is bought again");
        assertGt(basket.holdings(id, address(stock2)), 0);
        _assertSolvent();
    }

    function test_AfterAHandOverAdditionsGoToTheNewOwner() public {
        vm.prank(alice);
        basket.transferFrom(alice, bob, id);

        vm.prank(carol);
        basket.contribute(id, GIFT, bob, 1, block.timestamp + 1 hours); // Carol sees, and names, Bob

        uint256 owed = basket.holdings(id, address(stock));
        vm.prank(bob);
        basket.redeem(id);
        assertEq(IERC20(address(stock)).balanceOf(bob), owed, "the new owner has everything");
        assertEq(IERC20(address(stock)).balanceOf(alice), 0, "the previous owner has nothing");
    }

    // =======================================================================
    // The plan
    // =======================================================================

    function test_ChangingThePlanDoesNotTouchHoldings() public {
        uint256 h1 = basket.holdings(id, address(stock));
        uint256 h2 = basket.holdings(id, address(stock2));

        vm.prank(alice);
        basket.setAllocation(id, _single(address(stock)));

        assertEq(basket.allocationVersion(id), 2, "version bumped");
        assertEq(basket.holdings(id, address(stock)), h1, "nothing sold");
        assertEq(basket.holdings(id, address(stock2)), h2, "nothing sold");

        // The next addition follows the new plan: all into leg 1.
        vm.prank(carol);
        basket.contribute(id, GIFT, alice, 2, block.timestamp + 1 hours);
        assertGt(basket.holdings(id, address(stock)), h1, "leg 1 bought");
        assertEq(basket.holdings(id, address(stock2)), h2, "leg 2 not bought");
    }

    /// @notice The race the version exists for: the owner changes the plan while a
    ///         contribution quoted against the old plan is in flight.
    function test_AnAdditionQuotedAgainstAnOldPlanIsRefused() public {
        vm.prank(alice);
        basket.setAllocation(id, _single(address(stock2)));

        uint256 before = usdg.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.AllocationChangedSinceQuote.selector, id, 1, 2));
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);
        assertEq(usdg.balanceOf(carol), before, "nothing charged");
    }

    function test_OnlyTheOwnerChangesThePlan() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, bob));
        basket.setAllocation(id, _single(address(stock)));
    }

    function test_APlanMustBeValidAndBuyable() public {
        JayoBasket.Allocation[] memory bad = _twoLegAllocation();
        bad[1].weightBps = 3000;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.WeightsMustSumToBps.selector, 9000));
        basket.setAllocation(id, bad);

        address unknown = makeAddr("unrouted token");
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.AssetNotSupported.selector, unknown));
        basket.setAllocation(id, _single(unknown));
        vm.stopPrank();
    }

    function test_ACopyTakesTheCurrentPlanAtTheVersionTheCopierSaw() public {
        vm.prank(alice);
        basket.setAllocation(id, _single(address(stock2)));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.AllocationChangedSinceQuote.selector, id, 1, 2));
        basket.copyAllocation(id, GIFT, 1, block.timestamp + 1 hours);

        vm.prank(bob);
        uint256 copyId = basket.copyAllocation(id, GIFT, 2, block.timestamp + 1 hours);
        JayoBasket.Allocation[] memory plan = basket.allocationOf(copyId);
        assertEq(plan.length, 1);
        assertEq(plan[0].asset, address(stock2), "the current plan, not the original one");
        assertEq(basket.allocationVersion(copyId), 1, "a copy starts its own version history");
    }

    function test_SolvencyHoldsAcrossAdditionsAndPartialExits() public {
        // Small additions: the mock pools do not re-price, so large repeated buys
        // would (correctly) run into the 0.5% floor rather than test solvency.
        for (uint256 i; i < 4; ++i) {
            vm.prank(i % 2 == 0 ? bob : carol);
            basket.contribute(id, 100e6 + i * 7, alice, 1, block.timestamp + 1 hours);
            vm.prank(alice);
            basket.redeemFraction(id, 3333);
        }
        _assertSolvent();
        vm.prank(alice);
        basket.redeem(id);
        assertEq(basket.totalLiabilities(address(stock)), 0);
        assertEq(basket.totalLiabilities(address(stock2)), 0);
    }

    // =======================================================================
    // What a wallet shows
    // =======================================================================

    function test_MetadataDescribesTheCurrentPosition() public {
        JayoRenderer r = new JayoRenderer("https://jayo.example", "Test network: no value.");
        vm.prank(admin);
        basket.setRenderer(r);
        vm.prank(bob);
        basket.contribute(id, GIFT, alice, 1, block.timestamp + 1 hours);

        string memory uri = basket.tokenURI(id);
        assertEq(_prefix(uri, 29), "data:application/json;base64,", "base64 JSON");

        string memory json = JayoRenderer(address(basket.renderer())).tokenJSON(address(basket), id);
        assertEq(vm.parseJsonString(json, ".name"), "Jayo basket #1");
        assertEq(vm.parseJsonString(json, ".external_url"), "https://jayo.example/?basket=1");
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), string.concat("Holds ", stock.symbol()));
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "AAPL 60% / NVDA 40%");
        assertEq(vm.parseJsonUint(json, ".attributes[4].value"), 2, "added to twice");
        assertEq(vm.parseJsonString(json, ".attributes[5].value"), "12500 USDG", "bought with");
        assertEq(vm.parseJsonString(json, ".attributes[4].trait_type"), "Times added to");
    }

    function test_MetadataStopsWhenThePositionCloses() public {
        JayoRenderer r = new JayoRenderer("https://jayo.example", "x");
        vm.prank(admin);
        basket.setRenderer(r);
        vm.prank(alice);
        basket.redeem(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        basket.tokenURI(id);
    }

    function test_OnlyTheOperatorReplacesTheRendererAndItReachesDisplayOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        basket.setRenderer(IJayoRenderer(address(0xdead)));

        assertEq(basket.tokenURI(id), "", "no renderer: empty metadata, nothing else affected");
        assertTrue(basket.supportsInterface(0x49064906), "announces ERC-4906 metadata updates");
    }

    // =======================================================================

    function _single(address asset) internal pure returns (JayoBasket.Allocation[] memory a) {
        a = new JayoBasket.Allocation[](1);
        a[0] = JayoBasket.Allocation({asset: asset, weightBps: 10_000});
    }

    function _assertSolvent() internal view {
        assertLe(basket.totalLiabilities(address(stock)), stock.balanceOf(address(basket)), "leg 1 solvent");
        assertLe(basket.totalLiabilities(address(stock2)), stock2.balanceOf(address(basket)), "leg 2 solvent");
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[i];
        return string(out);
    }

    // =======================================================================
    // The race Codex's review found (2026-09-25): a contribution signed while
    // Alice owns the basket, mined after she has handed it to Bob. Version 2
    // let it through to Bob (reproduced on the V2 source, tag jayo-v2-deployed).
    // Version 3 binds the owner the contributor saw.
    // =======================================================================

    function test_Race_AContributionMinedAfterAHandOverIsRefused() public {
        uint64 seenVersion = basket.allocationVersion(id);
        address seenOwner = basket.ownerOf(id); // Alice

        vm.prank(alice);
        basket.transferFrom(alice, bob, id);

        uint256 before = basket.holdings(id, address(stock));
        uint256 carolBefore = usdg.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.OwnerChangedSinceQuote.selector, id, alice, bob));
        basket.contribute(id, GIFT, seenOwner, seenVersion, block.timestamp + 1 hours);

        assertEq(basket.holdings(id, address(stock)), before, "nothing reached Bob");
        assertEq(usdg.balanceOf(carol), carolBefore, "and Carol paid nothing");
    }
}
