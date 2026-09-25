// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The subset of the version-1 JayoBasket that remains in use after
///         version 2 was deployed beside it. Version 1 is immutable and stays live
///         on Robinhood Chain testnet so its positions can still be withdrawn and
///         handed on. Its source is tagged `jayo-v1-deployed` in git.
interface IJayoBasketV1 {
    struct Allocation {
        address asset;
        uint16 weightBps;
    }

    function create(Allocation[] calldata allocation, uint256 usdgIn, uint256 deadline) external returns (uint256);
    function copyAllocation(uint256 sourceTokenId, uint256 usdgIn, uint256 deadline) external returns (uint256);
    function holdingsOf(uint256 tokenId) external view returns (address[] memory assets, uint256[] memory amounts);
    function allocationOf(uint256 tokenId) external view returns (Allocation[] memory);
    function redeem(uint256 tokenId) external;
    function redeemAsset(uint256 tokenId, address asset) external;
    function redeemFraction(uint256 tokenId, uint16 bps) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}
