    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

// Standard OpenZeppelin ERC721 Wizard Code
// - receive accessoriesERC1155 to mint
// - mint is public / nft owner controled
// - user have power to set URI - ( TO be FIXed )
contract AviArt is ERC721, ERC721URIStorage, IERC1155Receiver {
    using Counters for Counters.Counter;

    Counters.Counter private TokenIdCounter;
    address public accessoriesContract;
    uint256 public constant MAX_SUPPLY_PER_TYPE = 1000;
    // this id is considered as a NULL
    uint256 public constant NULL_ID = 987654321;

    constructor(address _acsContract) ERC721("AviArts", "AA") {
        accessoriesContract = _acsContract;
    }

    mapping(uint256 => uint256[]) private Accessories;

    modifier isTokenOwner(uint256 _tokenId) {
        require(ownerOf(_tokenId) == msg.sender, "not owner");
        _;
    }

    modifier validAccessories(uint256[] memory _acs) {
        require(_acs.length > 1, "Min. 2 accessory required");
        for (uint256 i = 0; i < _acs.length; ++i) {
            uint256 accessoryId = _acs[i];
            if (accessoryId != NULL_ID) {
                // each array element should have a unique accessory type
                require((accessoryId / MAX_SUPPLY_PER_TYPE) == i, "not valid accessory");
            }
        }
        _;
    }

    function getTotalSupply() external view returns (uint256) {
        return TokenIdCounter.current();
    }

    function getAccessories(uint256 _tokenId) external view returns (uint256[] memory) {
        return Accessories[_tokenId];
    }

    function safeMint(uint256[] memory _acs, string memory _uri) public validAccessories(_acs) {
        uint256 tokenId = TokenIdCounter.current();
        TokenIdCounter.increment();

        // take owner ship of accessory to create a combimed NFT
        for (uint256 i = 0; i < _acs.length; ++i) {
            uint256 accessoryId = _acs[i];
            if (accessoryId != NULL_ID) {
                IERC1155(accessoriesContract).safeTransferFrom(
                    msg.sender,
                    address(this),
                    accessoryId,
                    1, // only 1
                    ""
                );
            }
        }
        Accessories[tokenId] = _acs;
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, _uri);
    }

    function updateComponents(uint256 _tokenId, uint256[] memory _acs, string memory _uri)
        public
        validAccessories(_acs)
        isTokenOwner(_tokenId)
    {
        uint256 length = _acs.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 newAcsId = _acs[i];
            uint256 ogAcsId = Accessories[_tokenId][i];
            if (newAcsId != ogAcsId) {
                if (newAcsId != NULL_ID) {
                    // receive the new component
                    IERC1155(accessoriesContract).safeTransferFrom(msg.sender, address(this), uint256(newAcsId), 1, "");
                }
                if (ogAcsId != NULL_ID) {
                    // return the og component
                    IERC1155(accessoriesContract).safeTransferFrom(address(this), msg.sender, uint256(ogAcsId), 1, "");
                }
            }
        }
        Accessories[_tokenId] = _acs;
        _setTokenURI(_tokenId, _uri);
    }

    // The following functions are overrides required by Solidity.
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return (bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")));
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return (bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)")));
    }
}
