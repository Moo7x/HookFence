// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDG
/// @notice TEST FIXTURE standing in for Paxos USDG. NOT real USDG.
/// @dev 6 decimals, matching the live USDG on Robinhood Chain mainnet
///      (0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), verified 2026-09-20.
///      The 18-in / 6-out asymmetry against Stock Tokens is exactly what makes the
///      policy's decimal normalisation non-trivial, so the mock preserves it.
contract MockUSDG is ERC20 {
    constructor() ERC20("Mock Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
