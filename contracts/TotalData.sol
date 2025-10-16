// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract TotalData is OwnableUpgradeable, UUPSUpgradeable {

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    mapping(address => bool) public freeAvatarMinted;
    address public gameManager;

    mapping(address => bool) public whitelisted;

    mapping(address => bool) public freeLandMinted;

    mapping(address => bool) public gameManagers;

    modifier onlyOwnerOrGameManager() {
        require(msg.sender == owner() || gameManagers[msg.sender], "Not owner or game manager");
        _;
    }

    function setFreeAvatarMinted(address _address) external onlyOwnerOrGameManager {
        freeAvatarMinted[_address] = true;
    }

    function setFreeLandMinted(address _address) external onlyOwnerOrGameManager {
        freeLandMinted[_address] = true;
    }

    function unsetFreeLandMinted(address _address) external onlyOwnerOrGameManager {
        freeLandMinted[_address] = false;
    }

    function setFreeAvatarMintedBatch(address[] calldata _addresses) external onlyOwnerOrGameManager {
        for (uint256 i = 0; i < _addresses.length; i++) {
            freeAvatarMinted[_addresses[i]] = true;
        }
    }

    function setGameManager(address _gameManager) external onlyOwner {
        gameManagers[_gameManager] = true;
    }

    function setWhitelisted(address _address, bool _whitelisted) external onlyOwner {
        whitelisted[_address] = _whitelisted;
    }

    function setWhitelistedBatch(address[] calldata _addresses, bool[] calldata _whitelisted) external onlyOwner {
        for (uint256 i = 0; i < _addresses.length; i++) {
            whitelisted[_addresses[i]] = _whitelisted[i];
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
