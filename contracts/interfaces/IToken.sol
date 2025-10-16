// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IToken is IERC20 {
    function burnedStats() external view returns (uint256);

    function mintedStats() external view returns (uint256);

    function pause() external;

    function unpause() external;

    function mint(address receiver, uint256 _amount) external;

    function burn(address _address, uint256 _amount) external;

    function paused() external view returns (bool);
}
