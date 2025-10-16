// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IDependencies.sol";
import "./interfaces/IAvatars.sol";

contract Avatars is ERC721EnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    string private nftBaseURI;
    IDependencies public d;
    uint256 lock;


    modifier onlyOwner() {
        require(msg.sender == d.owner(), "Only owner");
        _;
    }

    modifier onlyGameManager() {
        require(msg.sender == address(d.gameManager()), "only game manager");
        _;
    }

    function initialize(string memory _nftBaseURI, IDependencies _d, string memory _name, string memory _symbol)
        public
        initializer
    {
        __ERC721_init(_name, _symbol);
        __ERC721Enumerable_init();
        __UUPSUpgradeable_init();
        d = _d;
        nftBaseURI = _nftBaseURI;
        lock = 0;
    }

    function setDependencies(IDependencies addr) external onlyOwner {
        d = addr;
    }

    function owner() public view returns (address) {
        return d.owner();
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return nftBaseURI;
    }

    function mint(address receiver) external onlyGameManager returns (uint256) {
        require(lock == 0, "locked");
        lock = 1;
        uint256 tokenId = totalSupply() + 1; // +1 because we emit 0 and start with 1
        _safeMint(receiver, tokenId);
        lock = 0;
        return tokenId;
    }

    function withdrawToken(address _tokenAddress, address _whereTo, uint256 _amount) external onlyOwner {
        IERC20 token = IERC20(_tokenAddress);
        token.safeTransfer(_whereTo, _amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
