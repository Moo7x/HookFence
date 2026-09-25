// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {DemoPriceFeed} from "../../src/testnet/DemoPriceFeed.sol";
import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";

/// @title Who may move the demo price feed
///
/// @notice The first testnet deployment script used a mock feed whose
///         `setAnswer` anyone could call. On a public chain that means anyone can
///         set the reference price a user's floor is computed from, one block
///         before that user's trade. These tests pin the replacement.
contract DemoPriceFeedTest is Test {
    uint8 internal constant DEC = 8;
    int256 internal constant PRICE = 256_50000000; // $256.50
    uint16 internal constant STEP = 1000; // 10%

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    DemoPriceFeed internal feed;

    function setUp() public {
        feed = new DemoPriceFeed(DEC, PRICE, "DEMO TSLA / USD", owner, STEP, 0, 0);
        vm.prank(owner);
        feed.setUpdater(keeper);
    }

    function _answer() internal view returns (int256 a) {
        (, a,,,) = feed.latestRoundData();
    }

    // =======================================================================
    // Access control
    // =======================================================================

    function test_StrangerCannotUpdate() public {
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.NotUpdater.selector, stranger));
        vm.prank(stranger);
        feed.setAnswer(PRICE + 1);
        assertEq(_answer(), PRICE, "unchanged");
    }

    /// @notice The attack the open mock allowed: nudge the reference down so a
    ///         victim's floor drops, then trade against them.
    function test_StrangerCannotLowerTheReferenceBeforeSomeoneElsesTrade() public {
        for (int256 p = 1; p < PRICE; p = p * 10) {
            vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.NotUpdater.selector, stranger));
            vm.prank(stranger);
            feed.setAnswer(p);
        }
        assertEq(_answer(), PRICE);
    }

    function test_FuzzNoOneButUpdaterOrOwnerCanUpdate(address caller, int256 answer) public {
        vm.assume(caller != keeper && caller != owner);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.NotUpdater.selector, caller));
        vm.prank(caller);
        feed.setAnswer(answer);
    }

    function test_UpdaterCanUpdate() public {
        uint256 later = vm.getBlockTimestamp() + 30 minutes;
        vm.warp(later);
        vm.prank(keeper);
        feed.setAnswer(PRICE + 1_00000000);

        (uint80 round, int256 a,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(a, PRICE + 1_00000000);
        assertEq(updatedAt, later, "freshness moves with the write");
        assertEq(round, 2, "a new round");
    }

    function test_OwnerCanUpdate() public {
        vm.prank(owner);
        feed.setAnswer(PRICE - 1_00000000);
        assertEq(_answer(), PRICE - 1_00000000);
    }

    function test_ReplacedUpdaterLosesTheRight() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        feed.setUpdater(newKeeper);

        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.NotUpdater.selector, keeper));
        vm.prank(keeper);
        feed.setAnswer(PRICE);
    }

    function test_OnlyOwnerAppointsTheUpdater() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        feed.setUpdater(stranger);
    }

    function test_OnlyOwnerCanForce() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        feed.forceAnswer(PRICE * 3);
    }

    // =======================================================================
    // Bounds
    // =======================================================================

    function test_NonPositiveAnswersAreRefused() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.AnswerNotPositive.selector, int256(0)));
        feed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.AnswerNotPositive.selector, int256(-1)));
        feed.setAnswer(-1);
        vm.stopPrank();
    }

    function test_StepExactlyAtTheBoundIsAllowed() public {
        vm.prank(keeper);
        feed.setAnswer(PRICE + PRICE / 10);
        assertEq(_answer(), PRICE + PRICE / 10);
    }

    function test_StepBeyondTheBoundIsRefusedUpAndDown() public {
        int256 up = PRICE + PRICE / 10 + 1;
        int256 down = PRICE - PRICE / 10 - 1;
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.StepTooLarge.selector, PRICE, up, STEP));
        feed.setAnswer(up);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.StepTooLarge.selector, PRICE, down, STEP));
        feed.setAnswer(down);
        vm.stopPrank();
    }

    /// @notice A refused refresh leaves the old answer to go stale. That is the
    ///         point: a pool pushed far off its price should stop buying, not
    ///         become the new reference.
    function test_RefusedStepLeavesTheOldTimestamp() public {
        (,,, uint256 before,) = feed.latestRoundData();
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        vm.expectRevert();
        vm.prank(keeper);
        feed.setAnswer(PRICE * 2);
        (,,, uint256 afterTs,) = feed.latestRoundData();
        assertEq(afterTs, before, "no freshness was granted");
    }

    function test_OwnerForceBypassesTheStepAndSaysSo() public {
        vm.expectEmit(false, false, true, true);
        emit DemoPriceFeed.AnswerForced(PRICE, PRICE * 2, 2);
        vm.prank(owner);
        feed.forceAnswer(PRICE * 2);
        assertEq(_answer(), PRICE * 2);
    }

    // =======================================================================
    // Through the policy
    // =======================================================================

    /// @notice End to end: once stale, a stranger cannot revive buying; only the
    ///         updater can.
    function test_StaleFeedCanOnlyBeRevivedByTheUpdater() public {
        MockStockToken stock = new MockStockToken("Tesla", "TSLA");
        MockUSDG usdg = new MockUSDG();
        DemoPriceFeed usdgFeed = new DemoPriceFeed(DEC, 1_00000000, "DEMO USDG / USD", owner, STEP, 0, 0);

        StockTokenReferencePolicy policy = new StockTokenReferencePolicy(keccak256("t"), owner);
        vm.startPrank(owner);
        policy.setQuoteAsset(address(usdg), address(usdgFeed), 1 hours, 6);
        policy.setStockToken(address(stock), address(feed), 1 hours, 300);
        vm.stopPrank();

        policy.requiredMinOut(address(usdg), address(stock), 10e6, 0); // fresh: fine

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(); // FeedStale
        policy.requiredMinOut(address(usdg), address(stock), 10e6, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.NotUpdater.selector, stranger));
        feed.setAnswer(PRICE);

        vm.prank(keeper);
        feed.setAnswer(PRICE);
        vm.prank(owner);
        usdgFeed.setAnswer(1_00000000);

        (uint256 floor,) = policy.requiredMinOut(address(usdg), address(stock), 10e6, 0);
        assertGt(floor, 0, "buying resumes only after the updater refreshes");
    }

    // =======================================================================
    // Version 2: bounds for an unattended updater
    // =======================================================================

    // vm.getBlockTimestamp(), not block.timestamp: under via_ir the latter can be
    // read once and reused across vm.warp calls.

    /// @dev The testnet parameters: 15 minutes between updates, 10% a step, 25% a day.
    function _bounded() internal returns (DemoPriceFeed f) {
        f = new DemoPriceFeed(DEC, PRICE, "DEMO TSLA / USD", owner, STEP, 900, 2500);
        vm.prank(owner);
        f.setUpdater(keeper);
    }

    function test_UpdaterMustWaitTheMinimumInterval() public {
        DemoPriceFeed f = _bounded();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.TooSoon.selector, vm.getBlockTimestamp() + 900));
        f.setAnswer(PRICE + 1);

        vm.warp(vm.getBlockTimestamp() + 900);
        vm.prank(keeper);
        f.setAnswer(PRICE + 1);
    }

    /// @notice The attack the interval exists for: a stolen updater key applying the
    ///         10% step over and over. With the daily band, three steps is the limit.
    function test_AStolenUpdaterKeyCannotWalkThePricePastTheDailyBand() public {
        DemoPriceFeed f = _bounded();
        int256 p = PRICE;
        for (uint256 i; i < 2; ++i) {
            vm.warp(vm.getBlockTimestamp() + 900);
            p = p * 110 / 100;
            vm.prank(keeper);
            f.setAnswer(p); // +10%, then +21% cumulative
        }
        vm.warp(vm.getBlockTimestamp() + 900);
        int256 next = p * 110 / 100; // +33% from the start of the window
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.OutsideDailyBand.selector, PRICE, next, uint16(2500)));
        f.setAnswer(next);
    }

    function test_ANewWindowStartsFromTheAnswerThatStandsWhenTheOldOneEnds() public {
        DemoPriceFeed f = _bounded();
        int256 p = PRICE * 121 / 100;
        vm.warp(vm.getBlockTimestamp() + 900);
        vm.prank(keeper);
        f.setAnswer(PRICE * 110 / 100);
        vm.warp(vm.getBlockTimestamp() + 900);
        vm.prank(keeper);
        f.setAnswer(p);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(keeper);
        f.setAnswer(p * 110 / 100); // measured from p now, not from PRICE
        assertEq(f.bandAnchor(), p, "the window re-anchored at the standing answer");
    }

    function test_TheOwnerCanStillForceAndThatRestartsTheWindow() public {
        DemoPriceFeed f = _bounded();
        int256 moved = PRICE * 140 / 100;
        vm.prank(owner);
        f.forceAnswer(moved); // no interval, step or band applies to the owner's override
        assertEq(f.bandAnchor(), moved);
        assertEq(f.bandStartedAt(), vm.getBlockTimestamp());
    }

    function test_BoundsApplyToTheOwnersOrdinaryUpdatesToo() public {
        DemoPriceFeed f = _bounded();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceFeed.TooSoon.selector, vm.getBlockTimestamp() + 900));
        f.setAnswer(PRICE);
    }
}
