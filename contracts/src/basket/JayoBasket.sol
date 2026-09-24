// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {ExecutionGateway} from "../core/ExecutionGateway.sol";
import {IExecutionPolicy} from "../interfaces/IExecutionPolicy.sol";

/// @title JayoBasket
/// @notice A funded token basket you own as a single ERC-721 position: create it
///         with USDG, transfer it whole, copy its allocation with your own money,
///         and redeem the underlying tokens in kind.
///
/// @dev DESIGN DECISIONS THAT MATTER FOR REVIEW
///
///      1. **Liabilities, not equality.** The solvency invariant is
///         `totalLiabilities[asset] <= balanceOf(address(this))`, never equality.
///         Anyone can transfer tokens to this contract unsolicited; an equality
///         invariant would be broken by a donation, i.e. by a griefer paying us.
///         Surplus is tracked, never assignable to a position, and recoverable by
///         the operator only down to the liability line.
///
///      2. **In-kind redemption never touches the policy.** `redeem` reads no feed,
///         calls no oracle and asks no price. A position whose exit depended on a
///         reference that sleeps 24/5 would not be reliably redeemable, which is
///         the contradiction the sell-only design could not resolve. Redemption is
///         therefore pure bookkeeping plus ERC-20 transfers, and works while every
///         feed is stale. Asserted in `test/unit/BasketRedemption.t.sol` against a
///         policy that reverts on every call.
///
///      3. **Dust is rejected, not silently accepted.** A funded leg that would
///         acquire zero tokens fails with a named error. A zero floor is not
///         protection, so a leg whose reference floor rounds to zero is refused
///         rather than executed against `minOut = 0`. See `_assertLegIsMeaningful`.
///
///      4. **Transfer revokes delegated authority.** Position management is bound to
///         a version that increments on every transfer, so a manager appointed by a
///         previous owner cannot act after the sale, and an authorisation signed
///         before it is dead.
///
///      5. **Holdings are per-position and isolated.** `holdings[tokenId][asset]` is
///         the only way value is attributed. No code path lets one position spend
///         another's assets; redemption transfers exactly the recorded amount and
///         decrements exactly that amount.
///
///      NOT IMPLEMENTED, deliberately: rebalancing. It is a fee pump, it enables a
///      sale/rebalance race, and it is the largest source of accounting bugs. A
///      holder who wants a different allocation redeems and creates.
contract JayoBasket is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error AssetNotSupported(address asset);
    error WeightsMustSumToBps(uint256 got);
    error TooManyLegs(uint256 got, uint256 max);
    error NoLegs();
    error DuplicateAsset(address asset);
    error LegBelowMinimum(address asset, uint256 amountIn, uint256 minimum);
    error LegWouldAcquireNothing(address asset, uint256 amountIn);
    error LegAcquiredNothing(address asset, uint256 amountIn);
    error NotPositionOwner(uint256 tokenId, address caller);
    error NotOwnerOrManager(uint256 tokenId, address caller);
    error PositionDoesNotExist(uint256 tokenId);
    error ZeroAddress();
    error ZeroAmount();
    error NothingToRecover(address asset);
    error AssetNotHeld(uint256 tokenId, address asset);
    error FractionOutOfRange(uint16 bps);
    error FractionWouldDeliverNothing(uint256 tokenId, uint16 bps);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted once per created position, after every leg has settled.
    event BasketCreated(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 usdgFunded,
        uint256 usdgSpent,
        uint256 usdgReturned,
        uint256 legCount
    );

    /// @notice Emitted per leg with what was actually acquired, not what was quoted.
    event LegSettled(
        uint256 indexed tokenId, address indexed asset, uint16 weightBps, uint256 usdgSpent, uint256 acquired
    );

    /// @notice Emitted when unspent USDG is returned, so a remainder is never silent.
    event UnspentReturned(uint256 indexed tokenId, address indexed to, uint256 amount, string reason);

    event BasketRedeemed(uint256 indexed tokenId, address indexed to, uint256 legCount);
    event AssetRedeemed(uint256 indexed tokenId, address indexed asset, address indexed to, uint256 amount);
    /// @notice A position survived the withdrawal; `legsLeft` is what it still holds.
    event PartiallyRedeemed(uint256 indexed tokenId, address indexed to, uint256 legsLeft);

    event AllocationCopied(uint256 indexed sourceTokenId, uint256 indexed newTokenId, address indexed creator);

    /// @notice Emitted on every transfer, recording that prior authority is dead.
    event AuthorityRevoked(uint256 indexed tokenId, address indexed from, address indexed to, uint64 newVersion);

    event ManagerSet(uint256 indexed tokenId, address indexed manager, uint64 positionVersion);
    event AssetRouteConfigured(address indexed asset, bool enabled);
    event MinLegInputConfigured(uint256 minLegInput);
    event SurplusRecovered(address indexed asset, address indexed to, uint256 amount);

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @notice One line of a basket recipe: which asset, and what share of the funding.
    struct Allocation {
        address asset;
        uint16 weightBps;
    }

    /// @notice How this contract buys one supported asset with USDG.
    /// @dev Stored rather than passed by the caller so a user supplies only weights,
    ///      and so a caller cannot point a leg at an unreviewed pool.
    struct AssetRoute {
        PoolKey key;
        bool zeroForOne; // direction that BUYS this asset with USDG
        address adapter;
        bool enabled;
    }

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    ExecutionGateway public immutable gateway;
    IERC20 public immutable usdg;

    uint16 public constant BPS = 10_000;
    uint8 public constant MAX_LEGS = 8;

    /// @notice Smallest USDG a single leg may be funded with.
    /// @dev Guards the low end of the dust range before pricing is even consulted.
    ///      Defaults to 1.000000 USDG. See `_assertLegIsMeaningful` for the check
    ///      that matters more: that the leg would actually acquire something.
    uint256 public minLegInput;

    uint256 private _nextTokenId = 1;
    uint256 private _nextGatewayNonce;

    mapping(address asset => AssetRoute) private _routes;

    /// @notice Per-position, per-asset holdings. The only attribution of value.
    mapping(uint256 tokenId => mapping(address asset => uint256)) public holdings;
    /// @notice Assets held by a position, for enumeration at redemption.
    mapping(uint256 tokenId => address[]) private _assetsOf;
    /// @notice The recipe, kept so an allocation can be copied without copying value.
    mapping(uint256 tokenId => Allocation[]) private _allocationOf;

    /// @notice Sum of `holdings[*][asset]` across every live position.
    /// @dev Must never exceed this contract's balance of that asset. Surplus above
    ///      it is a donation and belongs to no position.
    mapping(address asset => uint256) public totalLiabilities;

    /// @notice Increments on every transfer. Anything authorised against an older
    ///         version is no longer valid.
    mapping(uint256 tokenId => uint64) public positionVersion;
    /// @notice A recorded delegate address for a position. Cleared on transfer.
    /// @dev GRANTS NOTHING TODAY. No function in this contract accepts it as
    ///      authority: create, copy, transfer and every withdrawal check the owner
    ///      alone. It is kept, and kept revoked on transfer, so that a future
    ///      delegated action cannot inherit a stale delegate from a previous owner.
    ///      The interface does not offer it, because offering a permission that
    ///      permits nothing would mislead.
    mapping(uint256 tokenId => address) public positionManager;

    constructor(ExecutionGateway gateway_, IERC20 usdg_, address owner_)
        ERC721("Jayo Basket", "JAYO")
        Ownable(owner_)
    {
        if (address(gateway_) == address(0) || address(usdg_) == address(0)) revert ZeroAddress();
        gateway = gateway_;
        usdg = usdg_;
        minLegInput = 1_000000; // 1.000000 USDG
    }

    // -----------------------------------------------------------------------
    // Administration
    // -----------------------------------------------------------------------

    function setAssetRoute(address asset, PoolKey calldata key, bool zeroForOne, address adapter, bool enabled)
        external
        onlyOwner
    {
        if (asset == address(0) || adapter == address(0)) revert ZeroAddress();
        _routes[asset] = AssetRoute({key: key, zeroForOne: zeroForOne, adapter: adapter, enabled: enabled});
        emit AssetRouteConfigured(asset, enabled);
    }

    function setMinLegInput(uint256 v) external onlyOwner {
        if (v == 0) revert ZeroAmount();
        minLegInput = v;
        emit MinLegInputConfigured(v);
    }

    /// @notice Recover tokens donated to this contract above the liability line.
    /// @dev Cannot touch anything a position is owed: the amount is computed as
    ///      balance minus liabilities, so a bug here cannot make a basket insolvent.
    function recoverSurplus(address asset, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 owed = totalLiabilities[asset];
        if (balance <= owed) revert NothingToRecover(asset);
        amount = balance - owed;
        IERC20(asset).safeTransfer(to, amount);
        emit SurplusRecovered(asset, to, amount);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function assetRoute(address asset) external view returns (AssetRoute memory) {
        return _routes[asset];
    }

    function assetsOf(uint256 tokenId) external view returns (address[] memory) {
        return _assetsOf[tokenId];
    }

    function allocationOf(uint256 tokenId) external view returns (Allocation[] memory) {
        return _allocationOf[tokenId];
    }

    /// @notice Actual token balances attributed to a position.
    function holdingsOf(uint256 tokenId)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = _assetsOf[tokenId];
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            amounts[i] = holdings[tokenId][assets[i]];
        }
    }

    /// @notice Surplus of an asset held above what positions are owed.
    function surplusOf(address asset) external view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 owed = totalLiabilities[asset];
        return balance > owed ? balance - owed : 0;
    }

    /// @notice What each leg would cost and acquire, before committing funds.
    /// @dev Reference amounts, NOT executed amounts - the pool charges a fee and
    ///      moves on impact. `BuyExecution.t.sol` measures the gap. A preview is a
    ///      forecast; only a settled transaction is a result.
    function previewCreate(Allocation[] calldata allocation, uint256 usdgIn)
        external
        view
        returns (uint256[] memory legInputs, uint256[] memory referenceOut, uint256[] memory floors, uint256 unspent)
    {
        _validateAllocationShape(allocation);
        uint256 n = allocation.length;
        legInputs = new uint256[](n);
        referenceOut = new uint256[](n);
        floors = new uint256[](n);

        IExecutionPolicy p = gateway.policy();
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            uint256 amountIn = Math.mulDiv(usdgIn, allocation[i].weightBps, BPS);
            legInputs[i] = amountIn;
            spent += amountIn;
            if (amountIn == 0) continue;
            referenceOut[i] = p.referenceValue(address(usdg), allocation[i].asset, amountIn);
            (floors[i],) = p.requiredMinOut(address(usdg), allocation[i].asset, amountIn, 0);
        }
        unspent = usdgIn - spent;
    }

    // -----------------------------------------------------------------------
    // Create
    // -----------------------------------------------------------------------

    /// @notice Fund a new basket with USDG and acquire its assets.
    /// @dev All or nothing. Any leg that cannot be priced, is too small to acquire
    ///      anything, or fills below its floor reverts the entire creation - no
    ///      partially-built position can exist.
    function create(Allocation[] calldata allocation, uint256 usdgIn, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        return _create(allocation, usdgIn, deadline, 0);
    }

    /// @notice Create a new position using another position's allocation.
    /// @dev Copies the RECIPE only. The new position is funded entirely by the
    ///      caller and starts with no history and no holdings of the source. The
    ///      source owner keeps their position and receives nothing.
    function copyAllocation(uint256 sourceTokenId, uint256 usdgIn, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (_ownerOf(sourceTokenId) == address(0)) revert PositionDoesNotExist(sourceTokenId);
        Allocation[] memory recipe = _allocationOf[sourceTokenId];
        tokenId = _createFromMemory(recipe, usdgIn, deadline, sourceTokenId);
        emit AllocationCopied(sourceTokenId, tokenId, msg.sender);
    }

    function _create(Allocation[] calldata allocation, uint256 usdgIn, uint256 deadline, uint256 copiedFrom)
        internal
        returns (uint256)
    {
        _validateAllocationShape(allocation);
        Allocation[] memory mem = new Allocation[](allocation.length);
        for (uint256 i; i < allocation.length; ++i) {
            mem[i] = allocation[i];
        }
        return _createFromMemory(mem, usdgIn, deadline, copiedFrom);
    }

    function _createFromMemory(Allocation[] memory allocation, uint256 usdgIn, uint256 deadline, uint256)
        internal
        returns (uint256 tokenId)
    {
        if (usdgIn == 0) revert ZeroAmount();

        tokenId = _nextTokenId++;
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);

        uint256 spent;
        for (uint256 i; i < allocation.length; ++i) {
            uint256 amountIn = Math.mulDiv(usdgIn, allocation[i].weightBps, BPS);
            spent += amountIn;
            _settleLeg(tokenId, allocation[i], amountIn, deadline);
            _allocationOf[tokenId].push(allocation[i]);
        }

        // Integer division of the weights leaves a remainder. Return it rather than
        // keeping it: an unexplained retention is how a contract quietly accrues
        // other people's money.
        uint256 unspent = usdgIn - spent;
        if (unspent > 0) {
            usdg.safeTransfer(msg.sender, unspent);
            emit UnspentReturned(tokenId, msg.sender, unspent, "weight rounding remainder");
        }

        _safeMint(msg.sender, tokenId);
        emit BasketCreated(tokenId, msg.sender, usdgIn, spent, unspent, allocation.length);
    }

    function _settleLeg(uint256 tokenId, Allocation memory leg, uint256 amountIn, uint256 deadline) internal {
        AssetRoute memory route = _routes[leg.asset];
        if (!route.enabled) revert AssetNotSupported(leg.asset);

        _assertLegIsMeaningful(leg.asset, amountIn);

        uint256 before = IERC20(leg.asset).balanceOf(address(this));

        usdg.forceApprove(address(gateway), amountIn);
        gateway.settle(_buildIntent(leg.asset, amountIn, route, deadline), route.key, route.zeroForOne);
        usdg.forceApprove(address(gateway), 0);

        // Credit what actually arrived, not what any quote or return value claimed.
        uint256 acquired = IERC20(leg.asset).balanceOf(address(this)) - before;
        if (acquired == 0) revert LegAcquiredNothing(leg.asset, amountIn);

        if (holdings[tokenId][leg.asset] == 0) {
            _assetsOf[tokenId].push(leg.asset);
        }
        holdings[tokenId][leg.asset] += acquired;
        totalLiabilities[leg.asset] += acquired;

        emit LegSettled(tokenId, leg.asset, leg.weightBps, amountIn, acquired);
    }

    /// @notice Refuse a leg that is funded but would acquire nothing meaningful.
    ///
    /// @dev Three distinct failures, each named separately so a user is told which
    ///      one they hit:
    ///
    ///      - `LegBelowMinimum` - the allocation is smaller than the operator's
    ///        configured floor, before pricing is even consulted.
    ///      - `LegWouldAcquireNothing` - the reference value of this input rounds to
    ///        zero raw units of the asset. Executing would spend real USDG for
    ///        nothing.
    ///      - a zero enforced floor - the policy would derive no protection at all,
    ///        so `minOut = 0` and any fill, including a zero fill, would pass.
    ///        A zero minimum is not protection; refuse rather than pretend.
    ///
    ///      `LegAcquiredNothing` in `_settleLeg` is the belt-and-braces version,
    ///      checked against the real post-trade balance rather than a forecast.
    function _assertLegIsMeaningful(address asset, uint256 amountIn) internal view {
        if (amountIn < minLegInput) revert LegBelowMinimum(asset, amountIn, minLegInput);

        IExecutionPolicy p = gateway.policy();
        if (p.referenceValue(address(usdg), asset, amountIn) == 0) {
            revert LegWouldAcquireNothing(asset, amountIn);
        }
        (uint256 floor,) = p.requiredMinOut(address(usdg), asset, amountIn, 0);
        if (floor == 0) revert LegWouldAcquireNothing(asset, amountIn);
    }

    function _buildIntent(address asset, uint256 amountIn, AssetRoute memory route, uint256 deadline)
        internal
        returns (ExecutionGateway.ExecutionIntent memory)
    {
        IExecutionPolicy p = gateway.policy();
        return ExecutionGateway.ExecutionIntent({
            chainId: block.chainid,
            gateway: address(gateway),
            owner: address(this),
            recipient: address(this),
            tokenIn: address(usdg),
            tokenOut: asset,
            amountIn: amountIn,
            // Zero defers to the policy's own reference floor, which
            // `_assertLegIsMeaningful` has already proven is non-zero.
            userMinOut: 0,
            adapter: route.adapter,
            routeHash: keccak256(abi.encode(route.key, route.zeroForOne)),
            policy: address(p),
            policyId: p.policyId(),
            policyVersion: p.policyVersion(),
            configEpoch: gateway.configEpoch(),
            nonce: _nextGatewayNonce++,
            deadline: deadline
        });
    }

    function _validateAllocationShape(Allocation[] calldata allocation) internal pure {
        uint256 n = allocation.length;
        if (n == 0) revert NoLegs();
        if (n > MAX_LEGS) revert TooManyLegs(n, MAX_LEGS);

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += allocation[i].weightBps;
            for (uint256 j = i + 1; j < n; ++j) {
                if (allocation[i].asset == allocation[j].asset) revert DuplicateAsset(allocation[i].asset);
            }
        }
        if (sum != BPS) revert WeightsMustSumToBps(sum);
    }

    // -----------------------------------------------------------------------
    // Redeem — in kind, no pricing
    // -----------------------------------------------------------------------

    /// @notice Burn a position and receive its underlying tokens.
    ///
    /// @dev Reads no price, calls no oracle, consults no policy. A holder can always
    ///      get their assets out provided the assets themselves are transferable -
    ///      which is the only dependency we cannot remove, since a token-level
    ///      freeze is the token's decision, not ours.
    ///
    ///      This is why the promise "withdraw its underlying assets" survives a
    ///      weekend when every equity feed is stale.
    function redeem(uint256 tokenId) external nonReentrant {
        address owner_ = _requireOwned(tokenId);
        if (msg.sender != owner_) revert NotPositionOwner(tokenId, msg.sender);

        address[] memory assets = _assetsOf[tokenId];
        uint256 n = assets.length;

        // Effects before interactions: clear the ledger, then transfer.
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 amount = holdings[tokenId][assets[i]];
            amounts[i] = amount;
            holdings[tokenId][assets[i]] = 0;
            totalLiabilities[assets[i]] -= amount;
        }
        delete _assetsOf[tokenId];
        delete _allocationOf[tokenId];
        delete positionManager[tokenId];
        _burn(tokenId);

        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(assets[i]).safeTransfer(owner_, amounts[i]);
            emit AssetRedeemed(tokenId, assets[i], owner_, amounts[i]);
        }

        emit BasketRedeemed(tokenId, owner_, n);
    }

    /// @notice Withdraw one asset and keep the position.
    ///
    /// @dev Same guarantee as `redeem`: reads no price, calls no oracle, consults
    ///      no policy. Wanting one leg back should not cost you the position, its
    ///      allocation record, or the manager you appointed - and it should not
    ///      have to wait for a market to open.
    ///
    ///      The allocation record is deliberately left alone. It is the recipe the
    ///      basket was built from and what `copyAllocation` copies; it is not a
    ///      claim about what the position currently holds. `holdingsOf` answers
    ///      that, and it is read straight from the ledger.
    function redeemAsset(uint256 tokenId, address asset) external nonReentrant {
        address owner_ = _requireOwned(tokenId);
        if (msg.sender != owner_) revert NotPositionOwner(tokenId, msg.sender);

        uint256 amount = holdings[tokenId][asset];
        if (amount == 0) revert AssetNotHeld(tokenId, asset);

        // Effects before interactions.
        holdings[tokenId][asset] = 0;
        totalLiabilities[asset] -= amount;
        uint256 legsLeft = _dropAsset(tokenId, asset);

        IERC20(asset).safeTransfer(owner_, amount);
        emit AssetRedeemed(tokenId, asset, owner_, amount);
        emit PartiallyRedeemed(tokenId, owner_, legsLeft);
    }

    /// @notice Withdraw the same fraction of every holding and keep the position.
    ///
    /// @dev Rounding truncates, so the position keeps the remainder rather than
    ///      the caller - a withdrawal can never take out more than its share, and
    ///      `totalLiabilities` therefore stays at or below the real balance.
    ///
    ///      A leg whose share rounds to zero is left untouched rather than
    ///      silently dropped. Refusing when NOTHING would be delivered is the
    ///      honest response to a fraction too small to matter; delivering nothing
    ///      and emitting success is not.
    function redeemFraction(uint256 tokenId, uint16 bps) external nonReentrant {
        address owner_ = _requireOwned(tokenId);
        if (msg.sender != owner_) revert NotPositionOwner(tokenId, msg.sender);
        if (bps == 0 || bps > BPS) revert FractionOutOfRange(bps);

        address[] memory assets = _assetsOf[tokenId];
        uint256 n = assets.length;
        uint256[] memory amounts = new uint256[](n);
        uint256 delivered;

        for (uint256 i; i < n; ++i) {
            uint256 amount = Math.mulDiv(holdings[tokenId][assets[i]], bps, BPS);
            if (amount == 0) continue;
            amounts[i] = amount;
            delivered += amount;
            holdings[tokenId][assets[i]] -= amount;
            totalLiabilities[assets[i]] -= amount;
        }
        if (delivered == 0) revert FractionWouldDeliverNothing(tokenId, bps);

        // Only now can a leg have reached zero, and only then is it dropped.
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0 && holdings[tokenId][assets[i]] == 0) _dropAsset(tokenId, assets[i]);
        }
        uint256 legsLeft = _assetsOf[tokenId].length;

        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(assets[i]).safeTransfer(owner_, amounts[i]);
            emit AssetRedeemed(tokenId, assets[i], owner_, amounts[i]);
        }
        emit PartiallyRedeemed(tokenId, owner_, legsLeft);
    }

    /// @dev Remove `asset` from a position's leg list. Order is not meaningful, so
    ///      the last entry fills the hole rather than shifting the tail.
    function _dropAsset(uint256 tokenId, address asset) internal returns (uint256 legsLeft) {
        address[] storage list = _assetsOf[tokenId];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] != asset) continue;
            list[i] = list[n - 1];
            list.pop();
            break;
        }
        return list.length;
    }

    // -----------------------------------------------------------------------
    // Management delegation
    // -----------------------------------------------------------------------

    /// @notice Record a delegate for a position. Cleared automatically on transfer.
    /// @dev See `positionManager`: recording one currently authorises no action.
    function setManager(uint256 tokenId, address manager) external {
        address owner_ = _requireOwned(tokenId);
        if (msg.sender != owner_) revert NotPositionOwner(tokenId, msg.sender);
        positionManager[tokenId] = manager;
        emit ManagerSet(tokenId, manager, positionVersion[tokenId]);
    }

    /// @notice True only for the current owner or their current delegate.
    /// @dev A view for off-chain readers. Nothing in this contract calls it.
    function isAuthorised(uint256 tokenId, address who) public view returns (bool) {
        address owner_ = _ownerOf(tokenId);
        if (owner_ == address(0)) return false;
        return who == owner_ || who == positionManager[tokenId];
    }

    /// @dev Transfer revokes everything the previous owner arranged.
    ///
    ///      ERC-721 already clears the single-token approval, and
    ///      `setApprovalForAll` is scoped to the granting owner so it cannot reach a
    ///      token they no longer hold. What that does NOT cover is authority this
    ///      contract grants itself - a manager appointment, or anything signed
    ///      against a position version. Both are invalidated here.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);

        // Only on a real transfer; a mint has no prior owner and a burn has no next.
        if (from != address(0) && to != address(0)) {
            delete positionManager[tokenId];
            uint64 v;
            unchecked {
                v = ++positionVersion[tokenId];
            }
            emit AuthorityRevoked(tokenId, from, to, v);
        }
    }
}
