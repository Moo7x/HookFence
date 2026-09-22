// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IExecutionPolicy
/// @notice Contract that decides the minimum acceptable output for a settlement.
/// @dev Implementations MUST fail closed: any doubt about reference data reverts.
interface IExecutionPolicy {
    /// @notice Identifier of this policy family (stable across versions).
    function policyId() external view returns (bytes32);

    /// @notice Monotonically increasing version, bumped on ANY material config change.
    function policyVersion() external view returns (uint64);

    /// @notice Compute the enforced output floor for an exact-input sale.
    /// @param tokenIn      Stock Token being sold.
    /// @param tokenOut     Settlement asset (USDG).
    /// @param amountIn     Exact input amount, in tokenIn's own decimals.
    /// @param userMinOut   Caller's own minimum, in tokenOut's own decimals.
    /// @return floor       max(userMinOut, referenceDerivedFloor), in tokenOut decimals.
    /// @return evidence    Reference data used, for the settlement receipt.
    function requiredMinOut(address tokenIn, address tokenOut, uint256 amountIn, uint256 userMinOut)
        external
        view
        returns (uint256 floor, ReferenceEvidence memory evidence);

    /// @notice Unadjusted reference value of `amountIn`, denominated in `tokenOut`.
    /// @dev The instrument's worth before any permitted shortfall is applied, so a
    ///      caller can show "reference" and "enforced floor" as separate numbers
    ///      rather than one opaque threshold. This is a forecast, not a fill: the
    ///      pool charges a fee and moves on impact. Subject to the same validity
    ///      checks as `requiredMinOut` and reverts identically.
    function referenceValue(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);

    /// @notice Which of a pair is the Stock Token.
    /// @dev Callers that must re-check instrument state after an external call use
    ///      this rather than assuming the Stock Token is the input - true only on
    ///      the sell leg. Reverts if the pair is not a reviewed route.
    function instrumentOf(address tokenIn, address tokenOut) external view returns (address stockToken);

    /// @notice Reference data actually used to derive a floor.
    struct ReferenceEvidence {
        uint80 baseRoundId;
        uint80 quoteRoundId;
        int256 basePrice;
        int256 quotePrice;
        uint256 baseUpdatedAt;
        uint256 quoteUpdatedAt;
        uint256 uiMultiplier;
        uint256 referenceOut;
        uint64 policyVersion;
    }
}
