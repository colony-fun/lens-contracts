// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ILands.sol";
import "./interfaces/IDependencies.sol";

contract Lands is ILands, ERC721EnumerableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    string private nftBaseURI;
    IDependencies public d;

    function initialize(string memory _nftBaseURI, IDependencies _d, string memory _name, string memory _symbol)
        public
        initializer
    {
        __ERC721_init(_name, _symbol);
        __ERC721Enumerable_init();
        __UUPSUpgradeable_init();
        d = _d;
        nftBaseURI = _nftBaseURI;
    }

    modifier onlyOwner() {
        require(msg.sender == d.owner(), "Only owner");
        _;
    }

    modifier onlyGameManager() {
        require(msg.sender == address(d.gameManager()), "Only game manager");
        _;
    }

    function owner() public view returns (address) {
        return d.owner();
    }

    function setDependencies(IDependencies addr) external onlyOwner {
        d = addr;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return nftBaseURI;
    }

    function setBaseURI(string memory newURI) external onlyOwner {
        nftBaseURI = newURI;
    }

    function mint(address receiver, uint256 tokenId) external onlyGameManager nonReentrant {
        _safeMint(receiver, tokenId);
    }

    function allMyTokens() external view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(msg.sender);
        if (tokenCount == 0) {
            return new uint256[](0);
        } else {
            uint256[] memory result = new uint256[](tokenCount);
            for (uint256 i = 0; i < tokenCount; i++) {
                result[i] = tokenOfOwnerByIndex(msg.sender, i);
            }
            return result;
        }
    }

    function allTokensByAddress(address _address) external view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_address);
        if (tokenCount == 0) {
            return new uint256[](0);
        } else {
            uint256[] memory result = new uint256[](tokenCount);
            for (uint256 i = 0; i < tokenCount; i++) {
                result[i] = tokenOfOwnerByIndex(_address, i);
            }
            return result;
        }
    }

    function allMyTokensPaginate(uint256 _from, uint256 _to) external view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(msg.sender);
        if (tokenCount <= _from || _from > _to || tokenCount == 0) {
            return new uint256[](0);
        }
        uint256 to = (tokenCount - 1 > _to) ? _to : tokenCount - 1;
        uint256[] memory result = new uint256[](to - _from + 1);
        for (uint256 i = _from; i <= to; i++) {
            result[i - _from] = tokenOfOwnerByIndex(msg.sender, i);
        }
        return result;
    }

    function allTokensPaginate(uint256 _from, uint256 _to) external view returns (uint256[] memory) {
        uint256 tokenCount = ERC721EnumerableUpgradeable.totalSupply();
        if (tokenCount <= _from || _from > _to || tokenCount == 0) {
            return new uint256[](0);
        }
        uint256 to = (tokenCount - 1 > _to) ? _to : tokenCount - 1;
        uint256[] memory result = new uint256[](to - _from + 1);
        for (uint256 i = _from; i <= to; i++) {
            result[i - _from] = tokenByIndex(i);
        }
        return result;
    }

    function withdrawToken(address _tokenContract, address _whereTo, uint256 _amount) external onlyOwner nonReentrant {
        IERC20 tokenContract = IERC20(_tokenContract);
        tokenContract.safeTransfer(_whereTo, _amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
