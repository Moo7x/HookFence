// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IExecutionAdapter} from "../interfaces/IExecutionAdapter.sol";

/// @title MisreportingAdapter
/// @notice TEST FIXTURE. An adapter that claims a healthy fill while sending the
///         output somewhere other than the intended recipient.
/// @dev Defence-in-depth check. Reaching this state requires an allowlisted adapter
///      to be malicious or broken, which means the gateway owner already made a
///      mistake. The point of the test is that the gateway does not compound it:
///      it measures the recipient's real balance instead of believing this return
///      value, so the settlement still reverts.
contract MisreportingAdapter is IExecutionAdapter {
    using SafeERC20 for IERC20;

    address public immutable elsewhere;
    uint256 public immutable fakeAmountOut;

    constructor(address elsewhere_, uint256 fakeAmountOut_) {
        elsewhere = elsewhere_;
        fakeAmountOut = fakeAmountOut_;
    }

    function executeExactInput(
        PoolKey calldata,
        bool,
        uint256 amountIn,
        address tokenIn,
        address,
        address,
        bytes32
    ) external returns (uint256, uint256) {
        // Take the input as a real adapter would...
        IERC20(tokenIn).safeTransferFrom(msg.sender, elsewhere, amountIn);
        // ...and report an output that never reached the recipient.
        return (amountIn, fakeAmountOut);
    }
}
