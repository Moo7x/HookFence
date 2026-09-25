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
import {IJayoRenderer} from "../interfaces/IJayoRenderer.sol";

/// @title JayoBasket (version 3)
/// @notice A basket of Stock Tokens owned as a single ERC-721 position. You start
///         it with USDG, or with Stock Tokens you already hold. After that,
///         anyone - you, or someone giving to you - can add money to that same
///         position, bought by its own plan, or add Stock Tokens they hold. You
///         can hand the whole position on, copy its plan with your own money,
///         change the plan for future money, and take the underlying tokens out
///         in kind: everything, a fraction, or one asset.
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
///      2. **In-kind redemption never touches the policy.** Every withdrawal path
///         reads no feed, calls no oracle and asks no price, so a position can be
///         emptied while every feed is stale. Buying - `create`, `contribute`,
///         `copyAllocation` - is the only thing that needs a price.
///
///      3. **Dust is rejected, not silently accepted.** A funded leg that would
///         acquire zero tokens fails with a named error. A zero floor is not
///         protection. See `_assertLegIsMeaningful`.
///
///      4. **Holdings are per-position and isolated.** `holdings[tokenId][asset]` is
///         the only way value is attributed. No code path lets one position spend
///         another's assets. A contribution is credited to exactly the position it
///         names and to no other.
///
///      5. **The plan is for future money, and is versioned.** `allocationOf` is
///         the split that the NEXT purchase into a position uses - a contribution,
///         or someone's copy. It is not a claim about what the position holds
///         (`holdingsOf` is). The owner may change it; existing holdings are never
///         rebalanced. Every change bumps `allocationVersion`, and `contribute` and
///         `copyAllocation` take the version the caller saw, so a plan changed
///         while a contribution is in flight makes that contribution revert
///         instead of buying something the contributor did not choose.
///
///      6. **No empty position can exist.** Withdrawing the last holding, by any
///         path, closes the position and burns the token. A V1 position could be
///         emptied one asset at a time and still be handed on as if it held
///         something.
///
///      7. **Metadata is rendered on-chain, by a replaceable renderer.** The
///         renderer reads this contract's public views. Replacing it is the
///         operator's only power over positions, and it reaches what a wallet
///         DISPLAYS, never what a position holds or who may withdraw it.
///
///      8. **Additions name the owner they were meant for.** `contribute` and
///         `depositInKind` take the owner the caller saw, as well as the plan
///         version. Version 2 bound only the plan, so a contribution mined after
///         a hand-over reached the new owner; a gift to the person on screen
///         must reach that person or not happen.
///
///      9. **In-kind additions need no price.** `createInKind` and
///         `depositInKind` move Stock Tokens the caller already holds into a
///         position and credit exactly what arrived (a balance difference, not
///         the requested amount). No feed, pool or policy is consulted, so a
///         basket can be started, added to, handed on and emptied while buying
///         is paused. Only assets with an enabled route are accepted, the same
///         set a purchase could buy.
///
///      NOT IMPLEMENTED, deliberately: rebalancing. It is a fee pump, it enables a
///      sale/rebalance race, and it is the largest source of accounting bugs. A
///      holder who wants a different mix changes the plan for new money, or
///      withdraws and creates.
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
    error PositionDoesNotExist(uint256 tokenId);
    error AllocationChangedSinceQuote(uint256 tokenId, uint64 expected, uint64 current);
    error OwnerChangedSinceQuote(uint256 tokenId, address expected, address current);
    error LengthMismatch(uint256 assets, uint256 amounts);
    error NothingReceived(address asset, uint256 requested);
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

    /// @notice Money added to an existing position, by its owner or anyone else.
    event Contributed(
        uint256 indexed tokenId, address indexed contributor, uint256 usdgFunded, uint256 usdgSpent, uint64 allocationVersion
    );

    /// @notice Stock Tokens moved into a position in kind, by its owner or anyone else.
    ///         `amount` is what arrived, which is what the position is credited.
    event DepositedInKind(uint256 indexed tokenId, address indexed depositor, address indexed asset, uint256 amount);

    /// @notice Emitted per leg with what was actually acquired, not what was quoted.
    ///         Every purchase into a position - creation or contribution - emits one
    ///         per leg.
    event LegSettled(
        uint256 indexed tokenId, address indexed asset, uint16 weightBps, uint256 usdgSpent, uint256 acquired
    );

    /// @notice Emitted when unspent USDG is returned, so a remainder is never silent.
    event UnspentReturned(uint256 indexed tokenId, address indexed to, uint256 amount, string reason);

    /// @notice The plan for future money changed. Carries the new plan in full.
    event AllocationChanged(uint256 indexed tokenId, uint64 version, Allocation[] allocation);

    event BasketRedeemed(uint256 indexed tokenId, address indexed to, uint256 legCount);
    event AssetRedeemed(uint256 indexed tokenId, address indexed asset, address indexed to, uint256 amount);
    /// @notice A position survived the withdrawal; `legsLeft` is what it still holds.
    event PartiallyRedeemed(uint256 indexed tokenId, address indexed to, uint256 legsLeft);
    /// @notice The position no longer exists. Emitted by every path that empties it.
    event PositionClosed(uint256 indexed tokenId, address indexed lastOwner);

    event AllocationCopied(uint256 indexed sourceTokenId, uint256 indexed newTokenId, address indexed creator);

    /// @notice ERC-4906: a wallet showing this token should re-read its metadata.
    event MetadataUpdate(uint256 _tokenId);

    event AssetRouteConfigured(address indexed asset, bool enabled);
    event MinLegInputConfigured(uint256 minLegInput);
    event SurplusRecovered(address indexed asset, address indexed to, uint256 amount);
    event RendererSet(address indexed renderer);

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @notice One line of a plan: which asset, and what share of each purchase.
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
    /// @notice The first id this contract minted. Ids run from here to
    ///         `nextTokenId() - 1`; closed positions leave gaps.
    uint256 public immutable firstTokenId;

    uint16 public constant BPS = 10_000;
    uint8 public constant MAX_LEGS = 8;
    /// @notice Contract generation. Version 1 is deployed separately and stays live.
    uint8 public constant CONTRACT_VERSION = 3;
    /// @dev ERC-4906 interface id.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    /// @notice Smallest USDG a single leg may be funded with.
    uint256 public minLegInput;

    /// @notice Draws what a wallet displays for a position. See design note 7.
    IJayoRenderer public renderer;

    uint256 private _nextTokenId;
    uint256 private _nextGatewayNonce;

    mapping(address asset => AssetRoute) private _routes;

    /// @notice Per-position, per-asset holdings. The only attribution of value.
    mapping(uint256 tokenId => mapping(address asset => uint256)) public holdings;
    /// @notice Assets held by a position, for enumeration at redemption.
    mapping(uint256 tokenId => address[]) private _assetsOf;
    /// @notice The plan for future money into this position. See design note 5.
    mapping(uint256 tokenId => Allocation[]) private _allocationOf;
    /// @notice Starts at 1 when a position is created; bumped on every plan change.
    mapping(uint256 tokenId => uint64) public allocationVersion;
    /// @notice USDG actually spent buying into this position, across all purchases.
    ///         In-kind deposits are not priced and do not count here.
    mapping(uint256 tokenId => uint256) public totalFunded;
    /// @notice How many times anything has been added: purchases and in-kind
    ///         deposits, creation included.
    mapping(uint256 tokenId => uint32) public fundingCount;

    /// @notice Sum of `holdings[*][asset]` across every live position.
    /// @dev Must never exceed this contract's balance of that asset.
    mapping(address asset => uint256) public totalLiabilities;

    /// @param firstTokenId_ The first id this contract mints. Set above the last id
    ///        of the version-1 contract on the same network, so a basket number
    ///        names exactly one position across both.
    constructor(ExecutionGateway gateway_, IERC20 usdg_, address owner_, uint256 firstTokenId_)
        ERC721("Jayo Basket", "JAYO")
        Ownable(owner_)
    {
        if (address(gateway_) == address(0) || address(usdg_) == address(0)) revert ZeroAddress();
        if (firstTokenId_ == 0) revert ZeroAmount();
        gateway = gateway_;
        usdg = usdg_;
        minLegInput = 1_000000; // 1.000000 USDG
        firstTokenId = firstTokenId_;
        _nextTokenId = firstTokenId_;
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

    /// @notice Replace what wallets display. Cannot touch holdings or ownership.
    function setRenderer(IJayoRenderer renderer_) external onlyOwner {
        renderer = renderer_;
        emit RendererSet(address(renderer_));
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

    /// @notice The id the next created position will get.
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @notice True while the position exists (it has been created and not closed).
    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Surplus of an asset held above what positions are owed.
    function surplusOf(address asset) external view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 owed = totalLiabilities[asset];
        return balance > owed ? balance - owed : 0;
    }

    /// @notice What each leg would cost and acquire for a new position.
    /// @dev Reference amounts, NOT executed amounts - the pool charges a fee and
    ///      moves on impact. A preview is a forecast; only a settled transaction is
    ///      a result.
    function previewCreate(Allocation[] calldata allocation, uint256 usdgIn)
        external
        view
        returns (uint256[] memory legInputs, uint256[] memory referenceOut, uint256[] memory floors, uint256 unspent)
    {
        _validateAllocationShape(allocation);
        return _preview(_toMemory(allocation), usdgIn);
    }

    /// @notice The same forecast for money added to an existing position by its plan.
    function previewContribute(uint256 tokenId, uint256 usdgIn)
        external
        view
        returns (uint256[] memory legInputs, uint256[] memory referenceOut, uint256[] memory floors, uint256 unspent)
    {
        _requireOwned(tokenId);
        return _preview(_allocationOf[tokenId], usdgIn);
    }

    function _preview(Allocation[] memory allocation, uint256 usdgIn)
        internal
        view
        returns (uint256[] memory legInputs, uint256[] memory referenceOut, uint256[] memory floors, uint256 unspent)
    {
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

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        IJayoRenderer r = renderer;
        return address(r) == address(0) ? "" : r.tokenURI(address(this), tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    // -----------------------------------------------------------------------
    // Buy: create, contribute, copy
    // -----------------------------------------------------------------------

    /// @notice Fund a new basket with USDG and acquire its assets.
    /// @dev All or nothing. Any leg that cannot be priced, is too small to acquire
    ///      anything, or fills below its floor reverts the entire creation.
    function create(Allocation[] calldata allocation, uint256 usdgIn, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        _validateAllocationShape(allocation);
        return _createFrom(_toMemory(allocation), usdgIn, deadline);
    }

    /// @notice Add money to an existing position, bought by that position's plan.
    ///
    /// @dev Open to anyone: the owner topping up, or someone giving to the owner.
    ///      The contributor pays; the position's owner receives everything bought,
    ///      and the contributor gains no claim on it. `expectedOwner` and
    ///      `expectedAllocationVersion` are what the contributor was shown: if the
    ///      position has changed hands, or the owner has changed the plan, this
    ///      reverts rather than give to someone else or buy a different mix. All
    ///      or nothing, with the same per-leg floors as `create`.
    function contribute(
        uint256 tokenId,
        uint256 usdgIn,
        address expectedOwner,
        uint64 expectedAllocationVersion,
        uint256 deadline
    ) external nonReentrant {
        _checkOwner(tokenId, expectedOwner);
        _checkAllocationVersion(tokenId, expectedAllocationVersion);

        uint256 spent = _fund(tokenId, _allocationOf[tokenId], usdgIn, deadline);
        emit Contributed(tokenId, msg.sender, usdgIn, spent, expectedAllocationVersion);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Create a new position using another position's current plan.
    /// @dev Copies the PLAN only. The new position is funded entirely by the
    ///      caller and starts with no holdings of the source. The source owner
    ///      keeps their position and receives nothing.
    function copyAllocation(uint256 sourceTokenId, uint256 usdgIn, uint64 expectedAllocationVersion, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (_ownerOf(sourceTokenId) == address(0)) revert PositionDoesNotExist(sourceTokenId);
        _checkAllocationVersion(sourceTokenId, expectedAllocationVersion);
        tokenId = _createFrom(_allocationOf[sourceTokenId], usdgIn, deadline);
        emit AllocationCopied(sourceTokenId, tokenId, msg.sender);
    }

    /// @notice Start a position with Stock Tokens you already hold. Nothing is
    ///         bought, so no price, pool or feed is needed.
    /// @param allocation The plan for money added later (validated like any plan).
    /// @param assets     Stock Tokens to move in; each needs an enabled route.
    /// @param amounts    How much of each to move; the position is credited with
    ///                   what actually arrives.
    function createInKind(Allocation[] calldata allocation, address[] calldata assets, uint256[] calldata amounts)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        _validateAllocationShape(allocation);
        for (uint256 i; i < allocation.length; ++i) {
            if (!_routes[allocation[i].asset].enabled) revert AssetNotSupported(allocation[i].asset);
        }
        Allocation[] memory plan = _toMemory(allocation);
        tokenId = _nextTokenId++;
        uint64 v = _storeAllocation(tokenId, plan);
        _depositInKind(tokenId, assets, amounts);

        _safeMint(msg.sender, tokenId);
        emit BasketCreated(tokenId, msg.sender, 0, 0, 0, assets.length);
        emit AllocationChanged(tokenId, v, plan);
    }

    /// @notice Move Stock Tokens you hold into an existing position - your own, or
    ///         someone else's as a gift. The position's owner receives them; the
    ///         depositor gains no claim. Reverts if the position has changed hands
    ///         since the depositor saw `expectedOwner`.
    function depositInKind(uint256 tokenId, address expectedOwner, address[] calldata assets, uint256[] calldata amounts)
        external
        nonReentrant
    {
        _checkOwner(tokenId, expectedOwner);
        _depositInKind(tokenId, assets, amounts);
        emit MetadataUpdate(tokenId);
    }

    /// @dev Pull each asset from the caller and credit what arrived. Same asset
    ///      set and size limit as a plan, so a position cannot be stuffed with
    ///      tokens no purchase could buy or with more legs than a redemption
    ///      handles.
    function _depositInKind(uint256 tokenId, address[] calldata assets, uint256[] calldata amounts) internal {
        uint256 n = assets.length;
        if (n != amounts.length) revert LengthMismatch(n, amounts.length);
        if (n == 0) revert NoLegs();
        if (n > MAX_LEGS) revert TooManyLegs(n, MAX_LEGS);
        for (uint256 i; i < n; ++i) {
            address asset = assets[i];
            if (!_routes[asset].enabled) revert AssetNotSupported(asset);
            if (amounts[i] == 0) revert ZeroAmount();
            for (uint256 j = i + 1; j < n; ++j) {
                if (asset == assets[j]) revert DuplicateAsset(asset);
            }
            uint256 before = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amounts[i]);
            // Credit what arrived, never what was asked for: a token that takes a
            // fee on transfer must not leave a position owed more than exists.
            uint256 received = IERC20(asset).balanceOf(address(this)) - before;
            if (received == 0) revert NothingReceived(asset, amounts[i]);

            if (holdings[tokenId][asset] == 0) _assetsOf[tokenId].push(asset);
            holdings[tokenId][asset] += received;
            totalLiabilities[asset] += received;
            emit DepositedInKind(tokenId, msg.sender, asset, received);
        }
        if (_assetsOf[tokenId].length > MAX_LEGS * 2) revert TooManyLegs(_assetsOf[tokenId].length, MAX_LEGS * 2);
        unchecked {
            ++fundingCount[tokenId];
        }
    }

    /// @notice Change the plan that future money into this position is split by.
    /// @dev Owner only. Holdings are not touched - nothing is bought or sold. Every
    ///      asset must have an enabled route now, so a plan cannot be set that no
    ///      contribution could ever buy.
    function setAllocation(uint256 tokenId, Allocation[] calldata allocation) external nonReentrant {
        address owner_ = _requireOwned(tokenId);
        if (msg.sender != owner_) revert NotPositionOwner(tokenId, msg.sender);
        _validateAllocationShape(allocation);
        for (uint256 i; i < allocation.length; ++i) {
            if (!_routes[allocation[i].asset].enabled) revert AssetNotSupported(allocation[i].asset);
        }
        Allocation[] memory plan = _toMemory(allocation);
        uint64 v = _storeAllocation(tokenId, plan);
        emit AllocationChanged(tokenId, v, plan);
        emit MetadataUpdate(tokenId);
    }

    function _createFrom(Allocation[] memory plan, uint256 usdgIn, uint256 deadline)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _nextTokenId++;
        uint64 v = _storeAllocation(tokenId, plan);
        uint256 spent = _fund(tokenId, plan, usdgIn, deadline);

        _safeMint(msg.sender, tokenId);
        emit BasketCreated(tokenId, msg.sender, usdgIn, spent, usdgIn - spent, plan.length);
        emit AllocationChanged(tokenId, v, plan);
    }

    /// @dev Take `usdgIn` from the caller, buy every leg of `plan` into `tokenId`,
    ///      and return the weight-rounding remainder to the caller.
    function _fund(uint256 tokenId, Allocation[] memory plan, uint256 usdgIn, uint256 deadline)
        internal
        returns (uint256 spent)
    {
        if (usdgIn == 0) revert ZeroAmount();
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);

        for (uint256 i; i < plan.length; ++i) {
            uint256 amountIn = Math.mulDiv(usdgIn, plan[i].weightBps, BPS);
            spent += amountIn;
            _settleLeg(tokenId, plan[i], amountIn, deadline);
        }

        // Integer division of the weights leaves a remainder. Return it rather than
        // keeping it: an unexplained retention is how a contract quietly accrues
        // other people's money.
        uint256 unspent = usdgIn - spent;
        if (unspent > 0) {
            usdg.safeTransfer(msg.sender, unspent);
            emit UnspentReturned(tokenId, msg.sender, unspent, "weight rounding remainder");
        }

        totalFunded[tokenId] += spent;
        unchecked {
            ++fundingCount[tokenId];
        }
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

    function _checkOwner(uint256 tokenId, address expected) internal view {
        address current = _requireOwned(tokenId);
        if (current != expected) revert OwnerChangedSinceQuote(tokenId, expected, current);
    }

    function _checkAllocationVersion(uint256 tokenId, uint64 expected) internal view {
        uint64 current = allocationVersion[tokenId];
        if (current != expected) revert AllocationChangedSinceQuote(tokenId, expected, current);
    }

    /// @dev Replace a position's plan and return its new version (1 on creation).
    function _storeAllocation(uint256 tokenId, Allocation[] memory plan) internal returns (uint64 v) {
        delete _allocationOf[tokenId];
        for (uint256 i; i < plan.length; ++i) {
            _allocationOf[tokenId].push(plan[i]);
        }
        unchecked {
            v = ++allocationVersion[tokenId];
        }
    }

    function _toMemory(Allocation[] calldata allocation) internal pure returns (Allocation[] memory mem) {
        mem = new Allocation[](allocation.length);
        for (uint256 i; i < allocation.length; ++i) {
            mem[i] = allocation[i];
        }
    }

    // -----------------------------------------------------------------------
    // Redeem — in kind, no pricing
    // -----------------------------------------------------------------------

    /// @notice Close a position and receive every underlying token.
    ///
    /// @dev Reads no price, calls no oracle, consults no policy. A holder can always
    ///      get their assets out provided the assets themselves are transferable -
    ///      which is the only dependency we cannot remove, since a token-level
    ///      freeze is the token's decision, not ours.
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
        _close(tokenId, owner_);

        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(assets[i]).safeTransfer(owner_, amounts[i]);
            emit AssetRedeemed(tokenId, assets[i], owner_, amounts[i]);
        }

        emit BasketRedeemed(tokenId, owner_, n);
    }

    /// @notice Withdraw one asset in full. The position survives if anything is
    ///         left in it; taking the last asset out closes it.
    ///
    /// @dev Same guarantee as `redeem`: no price, no oracle, no policy. The plan is
    ///      left alone - it describes future money, not current holdings - so the
    ///      next contribution buys the withdrawn asset again unless the owner
    ///      changes the plan.
    function redeemAsset(uint256 tokenId, address asset) external nonReentrant {
        address owner_ = _requireOwned(tokenId);
        if (msg.sender != owner_) revert NotPositionOwner(tokenId, msg.sender);

        uint256 amount = holdings[tokenId][asset];
        if (amount == 0) revert AssetNotHeld(tokenId, asset);

        // Effects before interactions.
        holdings[tokenId][asset] = 0;
        totalLiabilities[asset] -= amount;
        uint256 legsLeft = _dropAsset(tokenId, asset);
        if (legsLeft == 0) _close(tokenId, owner_);

        IERC20(asset).safeTransfer(owner_, amount);
        emit AssetRedeemed(tokenId, asset, owner_, amount);
        if (legsLeft != 0) {
            emit PartiallyRedeemed(tokenId, owner_, legsLeft);
            emit MetadataUpdate(tokenId);
        }
    }

    /// @notice Withdraw the same fraction of every holding. At 100%, or whenever
    ///         nothing would be left, the position closes.
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
        if (legsLeft == 0) _close(tokenId, owner_);

        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(assets[i]).safeTransfer(owner_, amounts[i]);
            emit AssetRedeemed(tokenId, assets[i], owner_, amounts[i]);
        }
        if (legsLeft != 0) {
            emit PartiallyRedeemed(tokenId, owner_, legsLeft);
            emit MetadataUpdate(tokenId);
        }
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

    /// @dev Burn an emptied position and forget its plan and counters. Callers
    ///      have already zeroed every holding.
    function _close(uint256 tokenId, address lastOwner) internal {
        delete _allocationOf[tokenId];
        delete allocationVersion[tokenId];
        delete totalFunded[tokenId];
        delete fundingCount[tokenId];
        _burn(tokenId);
        emit PositionClosed(tokenId, lastOwner);
    }
}
