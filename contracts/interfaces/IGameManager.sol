// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IGameManager {
    struct AttributeData {
        uint256 speed; // CLNY earning speed
        uint256 earned;
        uint8 level; // 1 - 10
        uint64 lastUpgradeTime;
    }

    function getAttributesMany(uint256[] calldata tokenIds) external view returns (AttributeData[] memory);
}
