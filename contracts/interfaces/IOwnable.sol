// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IOwnable {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}
