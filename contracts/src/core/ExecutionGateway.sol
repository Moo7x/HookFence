// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IExecutionPolicy} from "../interfaces/IExecutionPolicy.sol";
import {IExecutionAdapter} from "../interfaces/IExecutionAdapter.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";

/// @title ExecutionGateway
/// @notice Settles one authorised Stock Token -> USDG sale, and only if the tokens
///         the recipient actually received satisfy the active policy.
///
/// @dev The honest scope of this contract:
///
///      Uniswap v4 already enforces a minimum output, and an ordinary router handed
///      the same oracle-derived floor rejects the same below-floor fill. This
///      gateway does not invent slippage protection and does not claim to. What it
///      adds is that the *whole* Stock Token policy - instrument identity, feed
///      validity, issuer pause, corporate-action timing, unit handling, intent
///      authenticity, and real post-trade balance accounting - is enforced together,
///      inside the settlement transaction, behind one call an integrator makes once.
///      See docs/BASELINE_RESULTS.md for exactly which of those a plain oracle-floor
///      router also covers (output enforcement) and which it does not.
///
///      Evidence model: a failed settlement reverts, so it writes no event and no
///      state. Failures are evidenced by the transaction status plus the decoded
///      custom error in the trace. Only successful settlements emit a receipt. This
///      contract deliberately does not pretend a reverted attempt can log anything.
contract ExecutionGateway is Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error WrongChain(uint256 expected, uint256 actual);
    error WrongGateway(address expected, address actual);
    error IntentExpired(uint256 deadline, uint256 nowTs);
    error NonceAlreadyUsed(address owner, uint256 nonce);
    error UnauthorisedCaller(address caller, address owner);
    error InvalidSignature();
    error AdapterNotAllowed(address adapter);
    error PolicyContractMismatch(address expected, address actual);
    error ConfigEpochMismatch(uint64 expected, uint64 actual);
    error PolicyIdMismatch(bytes32 expected, bytes32 actual);
    error PolicyVersionMismatch(uint64 expected, uint64 actual);
    error OutputBelowFloor(uint256 received, uint256 required);
    error InputOverspent(uint256 spent, uint256 authorised);
    error InstrumentStateChangedDuringExecution(address token);
    error SameToken(address token);
    error ZeroAddress();
    error ZeroAmount();

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice What actually moved, as measured after execution.
    struct SettlementReceipt {
        address tokenIn;
        address tokenOut;
        uint256 amountInSpent;
        uint256 amountOutReceived;
        uint256 enforcedFloor;
        bytes32 policyId;
        uint64 policyVersion;
    }

    /// @notice Emitted only on a settlement that passed every check.
    event SettlementExecuted(
        bytes32 indexed intentHash,
        address indexed owner,
        address indexed recipient,
        SettlementReceipt receipt,
        IExecutionPolicy.ReferenceEvidence evidence
    );

    event AdapterConfigured(address indexed adapter, bool allowed, uint64 configEpoch);
    event PolicyConfigured(address indexed policy, uint64 configEpoch);

    // -----------------------------------------------------------------------
    // Intent
    // -----------------------------------------------------------------------

    /// @notice A fully bound authorisation to settle one trade.
    /// @dev Every field is covered by the EIP-712 hash. `chainId` and `gateway` are
    ///      carried explicitly as well as being in the domain separator, so a replay
    ///      onto a different chain or a redeployed gateway fails a plain equality
    ///      check even before signature recovery.
    ///
    ///      `policy` and `configEpoch` exist because `policyId` + `policyVersion`
    ///      are NOT sufficient. Both are values the policy contract reports about
    ///      itself, so a replacement contract can present the same pair while
    ///      enforcing looser rules; an intent signed under the old policy would then
    ///      still authorise. Binding the policy's *address* and a gateway-owned
    ///      epoch closes that. See `test/unit/ReviewRegressions.t.sol`.
    struct ExecutionIntent {
        uint256 chainId;
        address gateway;
        address owner; // supplies tokenIn and authorises the trade
        address recipient; // receives tokenOut
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 userMinOut;
        address adapter;
        bytes32 routeHash;
        address policy; // exact policy contract the signer agreed to
        bytes32 policyId;
        uint64 policyVersion;
        uint64 configEpoch; // gateway configuration generation
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant EXECUTION_INTENT_TYPEHASH = keccak256(
        "ExecutionIntent(uint256 chainId,address gateway,address owner,address recipient,address tokenIn,address tokenOut,uint256 amountIn,uint256 userMinOut,address adapter,bytes32 routeHash,address policy,bytes32 policyId,uint64 policyVersion,uint64 configEpoch,uint256 nonce,uint256 deadline)"
    );

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IExecutionPolicy public policy;
    mapping(address => bool) public allowedAdapters;
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    /// @notice Monotonic generation counter for gateway-level configuration.
    /// @dev Incremented on any change that could alter what a previously signed
    ///      intent means: swapping the policy contract, or enabling/disabling an
    ///      adapter. In-flight intents signed against an older epoch stop being
    ///      valid, which is the intended behaviour - an operator must not be able
    ///      to silently loosen terms a user already signed.
    uint64 public configEpoch;

    /// @dev Scratch space for one settlement. Held in memory, never storage.
    struct Measurement {
        uint256 floor;
        uint256 recipientBefore;
        uint256 ownerBefore;
        uint256 gatewayBefore;
        uint256 amountOutReceived;
        uint256 amountInSpent;
        uint256 multiplierBefore;
    }

    constructor(address owner_, IExecutionPolicy policy_) Ownable(owner_) EIP712("HookFence", "1") {
        if (address(policy_) == address(0)) revert ZeroAddress();
        policy = policy_;
    }

    // -----------------------------------------------------------------------
    // Administration
    // -----------------------------------------------------------------------

    function setPolicy(IExecutionPolicy policy_) external onlyOwner {
        if (address(policy_) == address(0)) revert ZeroAddress();
        policy = policy_;
        uint64 epoch = ++configEpoch;
        emit PolicyConfigured(address(policy_), epoch);
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        allowedAdapters[adapter] = allowed;
        uint64 epoch = ++configEpoch;
        emit AdapterConfigured(adapter, allowed, epoch);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function hashIntent(ExecutionIntent memory intent) public view returns (bytes32) {
        return _hashTypedDataV4(_structHash(intent));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Preview the floor the gateway would enforce right now.
    /// @dev Read-only mirror of the enforcement path, for the SDK and demo. A preview
    ///      is NOT a guarantee: the floor is recomputed at settlement time from the
    ///      feed state in that block, which is the entire point of the design.
    function previewFloor(address tokenIn, address tokenOut, uint256 amountIn, uint256 userMinOut)
        external
        view
        returns (uint256 floor, IExecutionPolicy.ReferenceEvidence memory evidence)
    {
        return policy.requiredMinOut(tokenIn, tokenOut, amountIn, userMinOut);
    }

    // -----------------------------------------------------------------------
    // Settlement
    // -----------------------------------------------------------------------

    /// @notice Settle an intent authorised by the caller itself.
    /// @dev The vault integration path: `msg.sender` is the owner, so no signature is
    ///      needed. This is the surface `ReferenceVault` uses.
    function settle(ExecutionIntent calldata intent, PoolKey calldata key, bool zeroForOne)
        external
        nonReentrant
        returns (uint256 amountOutReceived)
    {
        if (msg.sender != intent.owner) revert UnauthorisedCaller(msg.sender, intent.owner);
        return _settle(intent, key, zeroForOne);
    }

    /// @notice Settle an intent authorised by an EIP-712 signature from the owner.
    /// @dev Lets a relayer or keeper submit on the owner's behalf. Accepts ERC-1271
    ///      signatures too, so a contract owner (e.g. a vault) can authorise offline.
    function settleWithSignature(
        ExecutionIntent calldata intent,
        PoolKey calldata key,
        bool zeroForOne,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amountOutReceived) {
        bytes32 digest = _hashTypedDataV4(_structHash(intent));
        if (!SignatureChecker.isValidSignatureNow(intent.owner, digest, signature)) {
            revert InvalidSignature();
        }
        return _settle(intent, key, zeroForOne);
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _settle(ExecutionIntent calldata intent, PoolKey calldata key, bool zeroForOne)
        internal
        returns (uint256)
    {
        _validate(intent);

        // --- Effects before interactions: burn the nonce first. -------------
        nonceUsed[intent.owner][intent.nonce] = true;

        Measurement memory m = _measureAndExecute(intent, key, zeroForOne);

        // --- Enforcement ----------------------------------------------------
        if (m.amountOutReceived < m.floor) revert OutputBelowFloor(m.amountOutReceived, m.floor);
        if (m.amountInSpent > intent.amountIn) revert InputOverspent(m.amountInSpent, intent.amountIn);

        return m.amountOutReceived;
    }

    function _validate(ExecutionIntent calldata intent) internal view {
        if (intent.chainId != block.chainid) revert WrongChain(intent.chainId, block.chainid);
        if (intent.gateway != address(this)) revert WrongGateway(intent.gateway, address(this));
        if (block.timestamp > intent.deadline) revert IntentExpired(intent.deadline, block.timestamp);
        if (nonceUsed[intent.owner][intent.nonce]) revert NonceAlreadyUsed(intent.owner, intent.nonce);
        if (!allowedAdapters[intent.adapter]) revert AdapterNotAllowed(intent.adapter);
        if (intent.recipient == address(0)) revert ZeroAddress();
        if (intent.amountIn == 0) revert ZeroAmount();
        if (intent.tokenIn == intent.tokenOut) revert SameToken(intent.tokenIn);

        IExecutionPolicy p = policy;
        // Bind the exact policy CONTRACT, not just the identity it claims. A
        // replacement contract can report the same policyId/policyVersion while
        // enforcing a looser floor; without this check an intent signed under the
        // previous policy would still authorise against the new one.
        if (intent.policy != address(p)) revert PolicyContractMismatch(intent.policy, address(p));
        if (intent.configEpoch != configEpoch) revert ConfigEpochMismatch(intent.configEpoch, configEpoch);

        bytes32 pid = p.policyId();
        if (intent.policyId != pid) revert PolicyIdMismatch(intent.policyId, pid);
        uint64 pv = p.policyVersion();
        if (intent.policyVersion != pv) revert PolicyVersionMismatch(intent.policyVersion, pv);
    }

    /// @dev Takes the balance snapshots, runs the adapter, and re-measures. Split out
    ///      of `_settle` to keep both frames within the stack limit.
    function _measureAndExecute(ExecutionIntent calldata intent, PoolKey calldata key, bool zeroForOne)
        internal
        returns (Measurement memory m)
    {
        IExecutionPolicy.ReferenceEvidence memory evidence;
        (m.floor, evidence) = policy.requiredMinOut(intent.tokenIn, intent.tokenOut, intent.amountIn, intent.userMinOut);
        m.multiplierBefore = evidence.uiMultiplier;

        m.recipientBefore = IERC20(intent.tokenOut).balanceOf(intent.recipient);
        m.ownerBefore = IERC20(intent.tokenIn).balanceOf(intent.owner);
        m.gatewayBefore = IERC20(intent.tokenIn).balanceOf(address(this));

        // Pull the exact input from the owner, then grant the adapter an allowance of
        // exactly that amount and nothing more.
        IERC20(intent.tokenIn).safeTransferFrom(intent.owner, address(this), intent.amountIn);
        IERC20(intent.tokenIn).forceApprove(intent.adapter, intent.amountIn);

        IExecutionAdapter(intent.adapter).executeExactInput(
            key, zeroForOne, intent.amountIn, intent.tokenIn, intent.tokenOut, intent.recipient, intent.routeHash
        );

        // Revoke unconditionally, whatever the adapter did or did not spend.
        IERC20(intent.tokenIn).forceApprove(intent.adapter, 0);

        // Return unspent input to the owner, without touching any balance that was
        // sitting here before this call.
        uint256 gatewayNow = IERC20(intent.tokenIn).balanceOf(address(this));
        if (gatewayNow > m.gatewayBefore) {
            IERC20(intent.tokenIn).safeTransfer(intent.owner, gatewayNow - m.gatewayBefore);
        }

        // Measure reality rather than believing the adapter's return values.
        m.amountOutReceived = IERC20(intent.tokenOut).balanceOf(intent.recipient) - m.recipientBefore;
        m.amountInSpent = m.ownerBefore - IERC20(intent.tokenIn).balanceOf(intent.owner);

        // The Stock Token is the INPUT when selling and the OUTPUT when buying, so
        // ask the policy rather than assuming. Jayo funds baskets by buying.
        _assertInstrumentUnchanged(policy.instrumentOf(intent.tokenIn, intent.tokenOut), m.multiplierBefore);

        _emitReceipt(intent, m, evidence);
    }

    /// @dev Isolated purely so the receipt's field count does not blow the stack in
    ///      `_measureAndExecute`.
    function _emitReceipt(
        ExecutionIntent calldata intent,
        Measurement memory m,
        IExecutionPolicy.ReferenceEvidence memory evidence
    ) internal {
        emit SettlementExecuted(
            _hashTypedDataV4(_structHash(intent)),
            intent.owner,
            intent.recipient,
            SettlementReceipt({
                tokenIn: intent.tokenIn,
                tokenOut: intent.tokenOut,
                amountInSpent: m.amountInSpent,
                amountOutReceived: m.amountOutReceived,
                enforcedFloor: m.floor,
                policyId: intent.policyId,
                policyVersion: intent.policyVersion
            }),
            evidence
        );
    }

    /// @dev The external call could, in principle, land in the same block as a
    ///      corporate action or an issuer pause. The floor was derived before that
    ///      call, so re-read the instrument state afterwards and refuse to settle
    ///      against a floor that is no longer the one that applies.
    ///
    ///      The multiplier comparison works on any ERC-8056 instrument. The pause
    ///      read does not exist everywhere - the equity tokens on Robinhood Chain
    ///      testnet revert on it - so it runs only where the policy established at
    ///      registration that the instrument answers. An instrument that answered
    ///      then and refuses now is treated as a change, not as an all-clear.
    function _assertInstrumentUnchanged(address tokenIn, uint256 multiplierBefore) internal view {
        if (IStockToken(tokenIn).uiMultiplier() != multiplierBefore) {
            revert InstrumentStateChangedDuringExecution(tokenIn);
        }
        if (!policy.instrumentAnswersPause(tokenIn)) return;

        (bool ok, bytes memory ret) = tokenIn.staticcall(abi.encodeCall(IStockToken.oraclePaused, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bool))) {
            revert InstrumentStateChangedDuringExecution(tokenIn);
        }
    }

    function _structHash(ExecutionIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXECUTION_INTENT_TYPEHASH,
                intent.chainId,
                intent.gateway,
                intent.owner,
                intent.recipient,
                intent.tokenIn,
                intent.tokenOut,
                intent.amountIn,
                intent.userMinOut,
                intent.adapter,
                intent.routeHash,
                intent.policy,
                intent.policyId,
                intent.policyVersion,
                intent.configEpoch,
                intent.nonce,
                intent.deadline
            )
        );
    }
}
