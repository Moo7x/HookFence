// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {ExecutionGateway} from "../core/ExecutionGateway.sol";
import {IExecutionPolicy} from "../interfaces/IExecutionPolicy.sol";

/// @title ReferenceVault
/// @notice A minimal Stock Token vault that exits positions through HookFence.
///
/// @dev This is the integration argument, in code.
///
///      A vault that wanted the same safety without a gateway would have to carry,
///      itself: the token-to-feed mapping, `latestRoundData` validity rules
///      (positive / complete / not future-dated / not stale), the issuer
///      `oraclePaused` flag, ERC-8056 corporate-action timing, 18-decimal token to
///      8-decimal feed to 6-decimal USDG normalisation, the "do not re-apply
///      uiMultiplier" rule, and post-trade recipient balance accounting.
///
///      Here, that is `gateway.settle(intent, key, zeroForOne)`. What the vault still
///      owns is its own business rule - when to sell and how much - which is exactly
///      the part that should not live in shared infrastructure.
///
///      Measured in `test/unit/ReferenceVaultIntegration.t.sol`, which asserts the
///      vault never reads a price feed and never calls the PoolManager directly.
contract ReferenceVault is Ownable2Step {
    using SafeERC20 for IERC20;

    error NothingToSell();
    error BelowTargetExposure();
    error ZeroAddress();

    event ExitExecuted(address indexed stockToken, uint256 amountIn, uint256 usdgReceived, uint256 enforcedFloor);

    ExecutionGateway public immutable gateway;
    IERC20 public immutable usdg;

    /// @notice Vault's own rule: refuse to sell below this holding size.
    uint256 public minHoldingToExit;

    /// @dev The vault's own nonce stream for gateway intents.
    uint256 public nextNonce;

    constructor(ExecutionGateway gateway_, IERC20 usdg_, address owner_) Ownable(owner_) {
        if (address(gateway_) == address(0) || address(usdg_) == address(0)) revert ZeroAddress();
        gateway = gateway_;
        usdg = usdg_;
    }

    function setMinHoldingToExit(uint256 v) external onlyOwner {
        minHoldingToExit = v;
    }

    /// @notice Deposit Stock Tokens into the vault.
    function deposit(IERC20 stockToken, uint256 amount) external {
        stockToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice What the gateway would enforce for this exit right now.
    /// @dev A convenience read for the UI. Not a guarantee - see ExecutionGateway.
    function previewExit(address stockToken, uint256 amountIn, uint256 userMinOut)
        external
        view
        returns (uint256 floor, IExecutionPolicy.ReferenceEvidence memory evidence)
    {
        return gateway.previewFloor(stockToken, address(usdg), amountIn, userMinOut);
    }

    /// @notice Sell a Stock Token position for USDG through HookFence.
    ///
    /// @dev The entire safety surface is the `settle` call. The vault contributes its
    ///      own rule (`minHoldingToExit`) and its own slippage preference
    ///      (`userMinOut`); everything about whether the reference data can be
    ///      trusted, and whether the USDG that arrived is enough, is the gateway's.
    function exitPosition(
        address stockToken,
        uint256 amountIn,
        uint256 userMinOut,
        address adapter,
        bytes32 routeHash,
        bytes32 policyId,
        uint64 policyVersion,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 deadline
    ) external onlyOwner returns (uint256 usdgReceived) {
        uint256 holding = IERC20(stockToken).balanceOf(address(this));
        if (holding == 0 || amountIn == 0) revert NothingToSell();
        if (holding < minHoldingToExit) revert BelowTargetExposure();

        // The gateway pulls `amountIn` from this contract, so it needs an allowance
        // for exactly that. The gateway revokes its own downstream allowance itself.
        IERC20(stockToken).forceApprove(address(gateway), amountIn);

        ExecutionGateway.ExecutionIntent memory intent = ExecutionGateway.ExecutionIntent({
            chainId: block.chainid,
            gateway: address(gateway),
            owner: address(this),
            recipient: address(this),
            tokenIn: stockToken,
            tokenOut: address(usdg),
            amountIn: amountIn,
            userMinOut: userMinOut,
            adapter: adapter,
            routeHash: routeHash,
            policy: address(gateway.policy()),
            policyId: policyId,
            policyVersion: policyVersion,
            configEpoch: gateway.configEpoch(),
            nonce: nextNonce++,
            deadline: deadline
        });

        usdgReceived = gateway.settle(intent, key, zeroForOne);

        // Leave no standing allowance if the gateway consumed less than authorised.
        IERC20(stockToken).forceApprove(address(gateway), 0);

        emit ExitExecuted(stockToken, amountIn, usdgReceived, 0);
    }

    /// @notice Withdraw settled USDG.
    function withdrawUsdg(address to, uint256 amount) external onlyOwner {
        usdg.safeTransfer(to, amount);
    }
}
