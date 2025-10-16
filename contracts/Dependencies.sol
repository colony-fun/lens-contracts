// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "./interfaces/IDependencies.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IAvatars.sol";

contract Dependencies is IDependencies, OwnableUpgradeable, UUPSUpgradeable {


    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    struct Dependency {
        string name;
        address _addr;
    }

    modifier onlyGameManager() {
        require(msg.sender == address(gameManager), "Only game manager");
        _;
    }

    IToken public token;
    IGameManager public gameManager;
    ILands public lands;
    address public backendSigner;
    address public multisig;
    IAvatars public avatars;

    function owner() public view override(OwnableUpgradeable, IDependencies) returns (address) {
        return super.owner();
    }

    function setToken(IToken addr) external onlyOwner {
        token = addr;
    }

    function setTokenByGameManager(IToken addr) external onlyGameManager {
        token = addr;
    }

    function setGameManager(IGameManager addr) external onlyOwner {
        gameManager = addr;
    }

    function setLands(ILands addr) external onlyOwner {
        lands = addr;
    }

    function setBackendSigner(address addr) external onlyOwner {
        backendSigner = addr;
    }

    function setMultisig(address addr) external onlyOwner {
        multisig = addr;
    }

    function setAvatars(IAvatars addr) external onlyOwner {
        avatars = addr;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
