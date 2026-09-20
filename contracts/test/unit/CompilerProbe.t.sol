// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @title Characterisation test: `vm.warp` vs a cached `block.timestamp` under via-IR
///
/// @notice This documents a real trap that silently corrupted one of our own tests.
///         It asserts the behaviour we actually observe so that a future toolchain
///         change which fixes it will make this test fail loudly.
///
/// @dev What happens
///
///      ```solidity
///      vm.warp(1_000_000);
///      uint256 at = block.timestamp + 600;   // 1_000_600
///      vm.warp(at);                          // -> 1_000_600   correct
///      vm.warp(at + 1);                      // -> 1_001_201   NOT 1_000_601
///      ```
///
///      Why it is not a compiler bug: within a single transaction `TIMESTAMP` is
///      genuinely constant, so the Yul optimiser is entitled to rematerialise
///      `block.timestamp + 600` at each use instead of keeping it on the stack.
///      `vm.warp` breaks that invariant from outside the EVM, so the recomputed
///      value differs from the one that was cached. Note `console2.log(at)` still
///      prints 1_000_600 - the stack slot is fine; it is the *re-derived* use in
///      the argument position that drifts.
///
///      **Rule for this repository: never reuse a local derived from
///      `block.timestamp` across a `vm.warp`.** Read the value back from storage
///      or an immutable (an external call result cannot be rematerialised), or
///      warp to absolute literals.
///
///      This trap made `test_Regression_CorporateActionBufferHoldsAcrossTheTransition`
///      warp past the corporate-action buffer it was supposed to be probing, which
///      looked like a policy defect and was not.
contract CompilerProbeTest is Test {
    function test_CachedBlockTimestampDriftsAcrossWarp_KnownTrap() public {
        vm.warp(1_000_000);
        uint256 at = block.timestamp + 600;
        assertEq(at, 1_000_600, "the local itself reads correctly");

        vm.warp(at);
        assertEq(block.timestamp, 1_000_600, "a single use is fine");

        // The trap: this does NOT land on 1_000_601.
        vm.warp(at + 1);
        console2.log("expected 1000601, actually got:", block.timestamp);
        assertEq(
            block.timestamp,
            1_001_201,
            "KNOWN TRAP: block.timestamp was rematerialised as (1000600 + 600) + 1. "
            "If this assertion starts failing, the toolchain changed - re-read the NatSpec."
        );
    }

    /// @notice The safe pattern: an external call result cannot be rematerialised.
    function test_ValueReadBackFromAnExternalCallIsStable() public {
        vm.warp(1_000_000);
        TimestampHolder holder = new TimestampHolder(block.timestamp + 600);

        vm.warp(holder.at());
        assertEq(block.timestamp, 1_000_600);

        vm.warp(holder.at() + 1);
        assertEq(block.timestamp, 1_000_601, "stable: the value came from a call, not from TIMESTAMP");

        vm.warp(holder.at() + 3540);
        assertEq(block.timestamp, 1_004_140, "still stable after repeated warps");
    }
}

contract TimestampHolder {
    uint256 public immutable at;

    constructor(uint256 at_) {
        at = at_;
    }
}
