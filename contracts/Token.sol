// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDependencies.sol";

contract Token is ERC20Pausable {
    using SafeERC20 for IERC20;

    IDependencies public d;

    constructor(IDependencies _d, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        d = _d;
    }

    modifier onlyOwner() {
        require(msg.sender == d.owner(), "Only owner");
        _;
    }

    modifier onlyGameManager() {
        require(msg.sender == address(d.gameManager()), "Only game manager");
        _;
    }

    function setDependencies(IDependencies addr) external onlyOwner {
        d = addr;
    }

    uint256 public burnedStats;
    uint256 public mintedStats;

    function burn(address _address, uint256 _amount) external onlyGameManager whenNotPaused {
        _burn(_address, _amount);
        burnedStats += _amount;
    }

    function mint(address _address, uint256 _amount) external onlyGameManager whenNotPaused {
        _mint(_address, _amount);
        mintedStats += _amount;
    }

    function pause() external onlyGameManager {
        _pause();
    }

    function unpause() external onlyGameManager {
        _unpause();
    }

    function withdrawToken(address _tokenContract, address _whereTo, uint256 _amount) external onlyOwner {
        IERC20 tokenContract = IERC20(_tokenContract);
        tokenContract.safeTransfer(_whereTo, _amount);
    }
}
