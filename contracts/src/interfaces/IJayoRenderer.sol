// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Draws the ERC-721 metadata for a Jayo position. Reads only.
interface IJayoRenderer {
    function tokenURI(address basket, uint256 tokenId) external view returns (string memory);
}
