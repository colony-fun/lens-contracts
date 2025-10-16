// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "./IDependencies.sol";

interface IAvatars {
    function setDependencies(IDependencies addr) external;

    function owner() external view returns (address);

    function mint(address receiver) external returns (uint256);

    function withdrawToken(address _tokenContract, address _whereTo, uint256 _amount) external;
}
