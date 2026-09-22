// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IExecutionPolicy} from "../interfaces/IExecutionPolicy.sol";

/// @title RevertingPolicy
/// @notice TEST FIXTURE. Every function reverts.
/// @dev Used to prove that in-kind redemption never consults pricing. If `redeem`
///      touched the policy in any way - a floor, a reference value, an instrument
///      lookup - swapping this in would break it. It does not.
contract RevertingPolicy is IExecutionPolicy {
    error PolicyDeliberatelyUnavailable();

    function policyId() external pure returns (bytes32) {
        revert PolicyDeliberatelyUnavailable();
    }

    function policyVersion() external pure returns (uint64) {
        revert PolicyDeliberatelyUnavailable();
    }

    function requiredMinOut(address, address, uint256, uint256)
        external
        pure
        returns (uint256, ReferenceEvidence memory)
    {
        revert PolicyDeliberatelyUnavailable();
    }

    function referenceValue(address, address, uint256) external pure returns (uint256) {
        revert PolicyDeliberatelyUnavailable();
    }

    function instrumentOf(address, address) external pure returns (address) {
        revert PolicyDeliberatelyUnavailable();
    }
}
