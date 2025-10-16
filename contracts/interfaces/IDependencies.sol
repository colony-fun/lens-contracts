// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "./IToken.sol";
import "./IGameManager.sol";
import "./ILands.sol";
import "./IAvatars.sol";

interface IDependencies {
    function owner() external view returns (address);

    function token() external view returns (IToken);

    function setTokenByGameManager(IToken addr) external;

    function gameManager() external view returns (IGameManager);

    function setGameManager(IGameManager addr) external;

    function lands() external view returns (ILands);

    function setLands(ILands addr) external;

    function multisig() external view returns (address);

    function setMultisig(address addr) external;

    function avatars() external view returns (IAvatars);

    function setAvatars(IAvatars addr) external;
}
