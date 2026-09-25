// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {JayoFixture} from "../utils/JayoFixture.sol";
import {JayoBasket} from "../../src/basket/JayoBasket.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

/// @notice Drives the basket with random sequences of everything a user can do:
///         create, add money, start and add in kind, change the plan, take out
///         one asset, a fraction or everything, and hand baskets on. Reverts are
///         expected (a floor, a stale owner, an empty fraction) and swallowed;
///         the invariants below must hold whatever succeeded.
contract BasketHandler is Test {
    JayoBasket internal basket;
    IERC20 internal usdg;
    MockStockToken internal s1;
    MockStockToken internal s2;
    address[3] internal actors;

    uint256[] public ids;
    mapping(bytes32 => uint256) public calls;

    constructor(JayoBasket b, IERC20 u, MockStockToken a, MockStockToken c, address[3] memory who) {
        basket = b; usdg = u; s1 = a; s2 = c; actors = who;
        for (uint256 i; i < 3; ++i) {
            s1.mint(who[i], 1_000e18);
            s2.mint(who[i], 1_000e18);
            vm.startPrank(who[i]);
            s1.approve(address(b), type(uint256).max);
            s2.approve(address(b), type(uint256).max);
            vm.stopPrank();
        }
    }

    function idCount() external view returns (uint256) { return ids.length; }

    function _actor(uint256 seed) internal view returns (address) { return actors[seed % 3]; }

    function _id(uint256 seed) internal view returns (uint256) {
        return ids.length == 0 ? 0 : ids[seed % ids.length];
    }

    function _plan(uint256 w) internal view returns (JayoBasket.Allocation[] memory a) {
        uint16 w1 = uint16(bound(w, 1000, 9000));
        a = new JayoBasket.Allocation[](2);
        a[0] = JayoBasket.Allocation({asset: address(s1), weightBps: w1});
        a[1] = JayoBasket.Allocation({asset: address(s2), weightBps: 10_000 - w1});
    }

    function _owner(uint256 id) internal view returns (address o) {
        try basket.ownerOf(id) returns (address x) { o = x; } catch {}
    }

    function create(uint256 who, uint256 amount, uint256 w) external {
        amount = bound(amount, 3e6, 200e6);
        vm.prank(_actor(who));
        try basket.create(_plan(w), amount, block.timestamp + 1 hours) returns (uint256 id) { ids.push(id); calls["create"]++; } catch {}
    }

    function createInKind(uint256 who, uint256 a1, uint256 a2, uint256 w) external {
        address[] memory assets = new address[](2);
        assets[0] = address(s1); assets[1] = address(s2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = bound(a1, 1, 5e18); amounts[1] = bound(a2, 1, 5e18);
        vm.prank(_actor(who));
        try basket.createInKind(_plan(w), assets, amounts) returns (uint256 id) { ids.push(id); calls["createInKind"]++; } catch {}
    }

    function contribute(uint256 who, uint256 idSeed, uint256 amount) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        if (owner_ == address(0)) return;
        amount = bound(amount, 3e6, 100e6);
        uint64 v = basket.allocationVersion(id);
        vm.prank(_actor(who));
        try basket.contribute(id, amount, owner_, v, block.timestamp + 1 hours) { calls["contribute"]++; } catch {}
    }

    function depositInKind(uint256 who, uint256 idSeed, uint256 amt) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        if (owner_ == address(0)) return;
        address[] memory assets = new address[](1);
        assets[0] = amt % 2 == 0 ? address(s1) : address(s2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = bound(amt, 1, 3e18);
        vm.prank(_actor(who));
        try basket.depositInKind(id, owner_, assets, amounts) { calls["depositInKind"]++; } catch {}
    }

    function setAllocation(uint256 idSeed, uint256 w) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        if (owner_ == address(0)) return;
        vm.prank(owner_);
        try basket.setAllocation(id, _plan(w)) { calls["setAllocation"]++; } catch {}
    }

    function redeemAsset(uint256 idSeed, bool first) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        if (owner_ == address(0)) return;
        vm.prank(owner_);
        try basket.redeemAsset(id, first ? address(s1) : address(s2)) { calls["redeemAsset"]++; } catch {}
    }

    function redeemFraction(uint256 idSeed, uint16 bps) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        if (owner_ == address(0)) return;
        vm.prank(owner_);
        try basket.redeemFraction(id, uint16(bound(bps, 1, 10_000))) { calls["redeemFraction"]++; } catch {}
    }

    function redeem(uint256 idSeed) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        if (owner_ == address(0)) return;
        vm.prank(owner_);
        try basket.redeem(id) { calls["redeem"]++; } catch {}
    }

    function handOn(uint256 idSeed, uint256 toSeed) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        address to = _actor(toSeed);
        if (owner_ == address(0) || to == owner_) return;
        vm.prank(owner_);
        basket.transferFrom(owner_, to, id);
        calls["handOn"]++;
    }

    /// @dev A contribution naming a stale owner must never succeed.
    function staleContribution(uint256 who, uint256 idSeed, uint256 wrongSeed) external {
        uint256 id = _id(idSeed);
        address owner_ = _owner(id);
        address wrong = _actor(wrongSeed);
        if (owner_ == address(0) || wrong == owner_) return;
        uint64 v = basket.allocationVersion(id);
        vm.prank(_actor(who));
        try basket.contribute(id, 5e6, wrong, v, block.timestamp + 1 hours) {
            calls["staleSucceeded"]++; // checked by an invariant: must stay zero
        } catch {}
    }
}

/// @title Basket accounting holds under random use
contract BasketInvariantsTest is JayoFixture {
    BasketHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BasketHandler(basket, IERC20(address(usdg)), stock, stock2, [alice, bob, mallory]);
        // The handler pranks as the fixture's funded users; their USDG approvals
        // to the basket were set by the fixture.
        targetContract(address(handler));
    }

    /// The basket never owes more of an asset than it holds.
    function invariant_Solvent() public view {
        assertLe(basket.totalLiabilities(address(stock)), stock.balanceOf(address(basket)));
        assertLe(basket.totalLiabilities(address(stock2)), stock2.balanceOf(address(basket)));
    }

    /// Liabilities are exactly the sum of every live basket's holdings, and a
    /// closed basket holds nothing.
    function invariant_LiabilitiesAreTheSumOfHoldings() public view {
        uint256 sum1; uint256 sum2;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            uint256 h1 = basket.holdings(id, address(stock));
            uint256 h2 = basket.holdings(id, address(stock2));
            if (!basket.exists(id)) {
                assertEq(h1 + h2, 0, "a closed basket holds nothing");
                continue;
            }
            sum1 += h1; sum2 += h2;
        }
        assertEq(basket.totalLiabilities(address(stock)), sum1, "liabilities = sum of holdings (asset 1)");
        assertEq(basket.totalLiabilities(address(stock2)), sum2, "liabilities = sum of holdings (asset 2)");
    }

    /// No open basket is empty, and every listed asset is actually held.
    function invariant_NoEmptyOpenBasket() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            if (!basket.exists(id)) continue;
            (address[] memory assets, uint256[] memory amounts) = basket.holdingsOf(id);
            assertGt(assets.length, 0, "an open basket holds something");
            for (uint256 j; j < amounts.length; ++j) assertGt(amounts[j], 0, "a listed asset is held");
        }
    }

    /// The basket never keeps stablecoin: it spends it or returns it.
    function invariant_NoStablecoinRetained() public view {
        assertEq(usdg.balanceOf(address(basket)), 0);
    }

    /// An addition naming anyone but the current owner never goes through.
    function invariant_NoStaleAdditionSucceeds() public view {
        assertEq(handler.calls("staleSucceeded"), 0);
    }

    /// Coverage: the campaign is only evidence if the actions actually happened.
    /// Printed per run with -vv; asserted loosely so a handler that silently
    /// reverts everything fails the suite instead of passing it.
    function afterInvariant() public view {
        string[9] memory k = ["create", "createInKind", "contribute", "depositInKind", "setAllocation",
            "redeemAsset", "redeemFraction", "redeem", "handOn"];
        uint256 total;
        for (uint256 i; i < k.length; ++i) {
            uint256 c = handler.calls(bytes32(bytes(k[i]))); // the handler keys by the bytes32 string literal
            total += c;
            console2.log(k[i], c);
        }
        assertGt(total, 0, "the handler did something");
    }
}
