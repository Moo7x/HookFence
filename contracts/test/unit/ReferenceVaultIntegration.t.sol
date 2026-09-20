// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFenceFixture} from "../utils/HookFenceFixture.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {ReferenceVault} from "../../src/integrations/ReferenceVault.sol";
import {ExecutionGateway} from "../../src/core/ExecutionGateway.sol";
import {StockTokenReferencePolicy} from "../../src/policy/StockTokenReferencePolicy.sol";

/// @title ReferenceVault integration
///
/// @notice The integration argument, tested rather than asserted in prose.
///
/// @dev SCOPE, stated plainly because an independent review correctly flagged that
///      earlier wording oversold this contract: `ReferenceVault` is a **developer
///      example**, not a finished product. It has no depositor share accounting and
///      only its owner can withdraw. What it demonstrates is the integration
///      surface - that a consuming protocol reaches the whole Stock Token policy
///      through one call and carries none of it itself.
contract ReferenceVaultIntegrationTest is HookFenceFixture {
    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant EXIT = 10e18;
    uint256 internal constant MINED_GAS_PRICE = 2 gwei;

    /// @dev Cached so `_exitAsOwner` makes NO external call before the vault call.
    ///      An external call while a prank is armed consumes it, and the vault call
    ///      would then run as the test contract and fail on ownership instead of on
    ///      the thing under test. See CompilerProbe.t.sol for the sibling trap.
    uint64 internal cachedPolicyVersion;

    function setUp() public override {
        super.setUp();
        stock.mint(address(vault), DEPOSIT);
        vm.txGasPrice(MINED_GAS_PRICE);
        cachedPolicyVersion = policy.policyVersion();
    }

    // =======================================================================
    // The integration works
    // =======================================================================

    function test_VaultExitsThroughTheGateway() public {
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        uint256 stockBefore = stock.balanceOf(address(vault));

        uint256 received = _exit(honestKey, 0);

        assertGt(received, 0, "vault received USDG");
        assertEq(usdg.balanceOf(address(vault)) - usdgBefore, received, "and it actually arrived");
        assertEq(stockBefore - stock.balanceOf(address(vault)), EXIT, "exactly the authorised input was spent");

        (uint256 floor,) = policy.requiredMinOut(address(stock), address(usdg), EXIT, 0);
        assertGe(received, floor, "settlement cleared the enforced floor");
    }

    /// @notice The vault inherits the whole policy without implementing any of it.
    /// @dev Each of these fails inside the gateway, on a vault that contains no feed
    ///      logic whatsoever. That is the reuse claim, demonstrated.
    function test_VaultInheritsPolicyRejections_StaleFeed() public {
        vm.warp(block.timestamp + FEED_HEARTBEAT + 1);
        vm.prank(admin);
        vm.expectRevert(); // policy-level rejection; exact selector covered in PolicyBeyondFloor
        _exitAsOwner(honestKey, 0);
    }

    function test_VaultInheritsPolicyRejections_OraclePaused() public {
        _refreshFeeds();
        stock.setOraclePaused(true);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockTokenReferencePolicy.OraclePausedForCorporateAction.selector, address(stock)
            )
        );
        _exitAsOwner(honestKey, 0);
    }

    /// @notice A below-floor fill rolls back completely - no partial state.
    function test_VaultExitRollsBackEntirelyOnAdversarialPool() public {
        uint256 stockBefore = stock.balanceOf(address(vault));
        uint256 usdgBefore = usdg.balanceOf(address(vault));

        vm.prank(admin);
        vm.expectRevert();
        _exitAsOwner(adversarialKey, 0);

        assertEq(stock.balanceOf(address(vault)), stockBefore, "no Stock Tokens left the vault");
        assertEq(usdg.balanceOf(address(vault)), usdgBefore, "no USDG arrived");
    }

    /// @notice No standing allowance survives a settlement.
    function test_NoResidualAllowanceAfterExit() public {
        _exit(honestKey, 0);
        assertEq(stock.allowance(address(vault), address(gateway)), 0, "vault -> gateway cleared");
        assertEq(stock.allowance(address(gateway), address(adapter)), 0, "gateway -> adapter cleared");
    }

    /// @notice The vault's own rule stays the vault's own rule.
    /// @dev Business logic belongs to the integrator; only execution safety is shared.
    function test_VaultKeepsItsOwnBusinessRule() public {
        vm.prank(admin);
        vault.setMinHoldingToExit(DEPOSIT * 2); // more than it holds

        vm.prank(admin);
        vm.expectRevert(ReferenceVault.BelowTargetExposure.selector);
        _exitAsOwner(honestKey, 0);
    }

    function test_OnlyOwnerCanExit() public {
        vm.prank(trader);
        vm.expectRevert();
        _exitAsOwner(honestKey, 0);
    }

    // =======================================================================
    // The reuse claim, measured
    // =======================================================================

    /// @notice The vault contains no oracle, unit or settlement-accounting logic.
    ///
    /// @dev Checked against the deployed bytecode rather than by reading the source,
    ///      so it cannot drift: if someone later adds a feed read to the vault, the
    ///      function selector appears in its code and this fails.
    function test_VaultBytecodeContainsNoOracleLogic() public view {
        bytes memory code = address(vault).code;

        // latestRoundData() - the vault must never read a feed itself.
        assertFalse(_contains(code, hex"feaf968c"), "vault must not call latestRoundData()");
        // uiMultiplier() - corporate-action handling is the policy's job.
        assertFalse(_contains(code, hex"a60bf13d"), "vault must not read uiMultiplier()");
        // unlock(bytes) - the vault must never touch the PoolManager directly.
        assertFalse(_contains(code, hex"48c89491"), "vault must not call PoolManager.unlock()");

        console2.log("vault runtime bytecode size:", code.length);
        console2.log("gateway runtime bytecode size:", address(gateway).code.length);
        console2.log("policy runtime bytecode size:", address(policy).code.length);
    }

    // =======================================================================
    // Helpers
    // =======================================================================

    /// @dev Exit as the vault owner. Returns the USDG the vault actually received.
    function _exit(PoolKey memory key, uint256 userMinOut) internal returns (uint256) {
        cachedPolicyVersion = policy.policyVersion();
        vm.prank(admin);
        return _exitAsOwner(key, userMinOut);
    }

    /// @dev Exit without pranking, so a test can choose the caller (or arm an
    ///      expectRevert immediately before it). Makes no external call of its own.
    function _exitAsOwner(PoolKey memory key, uint256 userMinOut) internal returns (uint256) {
        return vault.exitPosition(
            address(stock),
            EXIT,
            userMinOut,
            address(adapter),
            _routeHash(key),
            POLICY_ID,
            cachedPolicyVersion,
            key,
            _zeroForOne(),
            block.timestamp + 1 hours
        );
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || haystack.length < needle.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
