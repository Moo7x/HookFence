// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {JayoFixture} from "../utils/JayoFixture.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC721Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {RevertingPolicy} from "../../src/mocks/RevertingPolicy.sol";
import {IExecutionPolicy} from "../../src/interfaces/IExecutionPolicy.sol";

/// @dev Takes 1% of every transfer, so a contract that credits the requested
///      amount instead of what arrived would owe more than it holds.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @title Starting and adding to a basket with Stock Tokens already held
///
/// @notice Version 3. The property that matters is the same one redemption rests
///         on: nothing here reads a price. It is proven the same way, by pointing
///         the gateway at a policy whose every function reverts.
contract InKindTest is JayoFixture {
    uint256 internal constant HELD1 = 3e18;
    uint256 internal constant HELD2 = 5e18;

    function setUp() public override {
        super.setUp();
        stock.mint(alice, 10e18);
        stock2.mint(alice, 10e18);
        stock.mint(bob, 10e18);
        stock2.mint(bob, 10e18);
        for (uint256 i; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            vm.startPrank(u);
            IERC20(address(stock)).approve(address(basket), type(uint256).max);
            IERC20(address(stock2)).approve(address(basket), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _assets() internal view returns (address[] memory a, uint256[] memory amt) {
        a = new address[](2);
        a[0] = address(stock);
        a[1] = address(stock2);
        amt = new uint256[](2);
        amt[0] = HELD1;
        amt[1] = HELD2;
    }

    function _killPricing() internal {
        IExecutionPolicy dead = new RevertingPolicy();
        vm.prank(admin);
        gateway.setPolicy(dead);
    }

    // =======================================================================
    // Starting a basket in kind
    // =======================================================================

    function test_StartABasketWithTokensYouHold() public {
        (address[] memory a, uint256[] memory amt) = _assets();
        vm.prank(alice);
        uint256 id = basket.createInKind(_twoLegAllocation(), a, amt);

        assertEq(basket.ownerOf(id), alice);
        assertEq(basket.holdings(id, address(stock)), HELD1, "exactly what was moved in");
        assertEq(basket.holdings(id, address(stock2)), HELD2);
        assertEq(IERC20(address(stock)).balanceOf(alice), 10e18 - HELD1, "from Alice's own wallet");
        assertEq(basket.fundingCount(id), 1);
        assertEq(basket.totalFunded(id), 0, "nothing was bought");
        assertEq(basket.allocationVersion(id), 1, "and it has a plan for money added later");
        _assertSolvent();
    }

    /// @notice The reason in kind matters: it works with pricing gone entirely -
    ///         stale feeds, a broken policy, closed markets - and so does the rest
    ///         of the journey that needs no purchase.
    function test_TheWholeInKindJourneyNeedsNoPrice() public {
        _killPricing();
        (address[] memory a, uint256[] memory amt) = _assets();

        vm.prank(alice);
        uint256 id = basket.createInKind(_twoLegAllocation(), a, amt);

        address[] memory one = new address[](1);
        one[0] = address(stock);
        uint256[] memory oneAmt = new uint256[](1);
        oneAmt[0] = 1e18;
        vm.prank(bob);
        basket.depositInKind(id, alice, one, oneAmt); // a gift, in kind

        vm.prank(alice);
        basket.transferFrom(alice, bob, id);
        vm.prank(bob);
        basket.redeemAsset(id, address(stock2));
        assertEq(IERC20(address(stock2)).balanceOf(bob), 10e18 + HELD2);
        vm.prank(bob);
        basket.redeem(id);
        assertEq(IERC20(address(stock)).balanceOf(bob), 10e18 - 1e18 + HELD1 + 1e18, "the gift came back with the rest");
        assertEq(basket.totalLiabilities(address(stock)), 0);
    }

    function test_ABasketStartedInKindCanLaterBeBoughtInto() public {
        (address[] memory a, uint256[] memory amt) = _assets();
        vm.prank(alice);
        uint256 id = basket.createInKind(_twoLegAllocation(), a, amt);

        vm.prank(bob);
        basket.contribute(id, 2_500e6, alice, 1, block.timestamp + 1 hours);
        assertGt(basket.holdings(id, address(stock)), HELD1, "a purchase adds to what was moved in");
        assertEq(basket.fundingCount(id), 2);
        _assertSolvent();
    }

    // =======================================================================
    // Adding in kind to an existing basket
    // =======================================================================

    function test_AnyoneCanAddTokensTheyHoldToSomeonesBasket() public {
        vm.prank(alice);
        uint256 id = basket.create(_twoLegAllocation(), 1_000e6, block.timestamp + 1 hours);
        uint256 h2 = basket.holdings(id, address(stock2));

        address[] memory one = new address[](1);
        one[0] = address(stock2);
        uint256[] memory amt = new uint256[](1);
        amt[0] = 2e18;
        vm.expectEmit(true, true, true, true, address(basket));
        emit JayoBasket.DepositedInKind(id, bob, address(stock2), 2e18);
        vm.prank(bob);
        basket.depositInKind(id, alice, one, amt);

        assertEq(basket.holdings(id, address(stock2)), h2 + 2e18);
        assertEq(basket.balanceOf(bob), 0, "Bob gains no claim");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.NotPositionOwner.selector, id, bob));
        basket.redeemAsset(id, address(stock2));
    }

    function test_AnInKindGiftMinedAfterAHandOverIsRefused() public {
        (address[] memory a, uint256[] memory amt) = _assets();
        vm.prank(alice);
        uint256 id = basket.createInKind(_twoLegAllocation(), a, amt);
        vm.prank(alice);
        basket.transferFrom(alice, mallory, id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.OwnerChangedSinceQuote.selector, id, alice, mallory));
        basket.depositInKind(id, alice, a, amt);
    }

    function test_ADepositCreditsWhatArrivedNotWhatWasAsked() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        vm.prank(admin);
        basket.setAssetRoute(address(fee), honestKey, buy1, address(adapter), true);
        fee.mint(alice, 100e18);
        vm.prank(alice);
        fee.approve(address(basket), type(uint256).max);

        address[] memory a = new address[](1);
        a[0] = address(fee);
        uint256[] memory amt = new uint256[](1);
        amt[0] = 100e18;
        JayoBasket.Allocation[] memory plan = new JayoBasket.Allocation[](1);
        plan[0] = JayoBasket.Allocation({asset: address(stock), weightBps: 10_000});

        vm.prank(alice);
        uint256 id = basket.createInKind(plan, a, amt);
        assertEq(basket.holdings(id, address(fee)), 99e18, "credited 99, the amount that arrived");
        assertEq(basket.totalLiabilities(address(fee)), fee.balanceOf(address(basket)), "owes exactly what it holds");
    }

    // =======================================================================
    // What is refused
    // =======================================================================

    function test_OnlyAssetsAPurchaseCouldBuyAreAccepted() public {
        FeeOnTransferToken stray = new FeeOnTransferToken();
        stray.mint(alice, 1e18);
        address[] memory a = new address[](1);
        a[0] = address(stray);
        uint256[] memory amt = new uint256[](1);
        amt[0] = 1e18;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.AssetNotSupported.selector, address(stray)));
        basket.createInKind(_twoLegAllocation(), a, amt);
    }

    function test_MalformedDepositsAreRefused() public {
        (address[] memory a, uint256[] memory amt) = _assets();
        vm.startPrank(alice);

        uint256[] memory short = new uint256[](1);
        short[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.LengthMismatch.selector, 2, 1));
        basket.createInKind(_twoLegAllocation(), a, short);

        address[] memory dup = new address[](2);
        dup[0] = address(stock);
        dup[1] = address(stock);
        vm.expectRevert(abi.encodeWithSelector(JayoBasket.DuplicateAsset.selector, address(stock)));
        basket.createInKind(_twoLegAllocation(), dup, amt);

        amt[1] = 0;
        vm.expectRevert(JayoBasket.ZeroAmount.selector);
        basket.createInKind(_twoLegAllocation(), a, amt);

        vm.expectRevert(JayoBasket.NoLegs.selector);
        basket.createInKind(_twoLegAllocation(), new address[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_CannotAddToAClosedBasket() public {
        (address[] memory a, uint256[] memory amt) = _assets();
        vm.prank(alice);
        uint256 id = basket.createInKind(_twoLegAllocation(), a, amt);
        vm.prank(alice);
        basket.redeem(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        basket.depositInKind(id, alice, a, amt);
    }

    function test_SolvencyAcrossInKindPurchasesAndExits() public {
        (address[] memory a, uint256[] memory amt) = _assets();
        vm.prank(alice);
        uint256 id = basket.createInKind(_twoLegAllocation(), a, amt);
        uint256[] memory gift = new uint256[](2);
        gift[0] = 1e18;
        gift[1] = 1e18;
        for (uint256 i; i < 3; ++i) {
            vm.prank(bob);
            basket.depositInKind(id, alice, a, gift);
            vm.prank(bob);
            basket.contribute(id, 100e6, alice, 1, block.timestamp + 1 hours);
            vm.prank(alice);
            basket.redeemFraction(id, 4000);
        }
        _assertSolvent();
        vm.prank(alice);
        basket.redeem(id);
        assertEq(basket.totalLiabilities(address(stock)), 0);
        assertEq(basket.totalLiabilities(address(stock2)), 0);
    }

    function _assertSolvent() internal view {
        assertLe(basket.totalLiabilities(address(stock)), stock.balanceOf(address(basket)), "leg 1 solvent");
        assertLe(basket.totalLiabilities(address(stock2)), stock2.balanceOf(address(basket)), "leg 2 solvent");
    }
}
