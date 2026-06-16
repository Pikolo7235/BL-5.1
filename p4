// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract AdvancedHaikuNFT is ERC721 {
    using Strings for uint256;

    struct Haiku {
        address author;
        string line1;
        string line2;
        string line3;
        uint256 timestamp;
    }

    struct Listing {
        uint256 price;
        bool isForSale;
    }

    uint256 public counter;
    
    // Główne mapowania danych
    mapping(uint256 => Haiku) private haikus;
    mapping(bytes32 => bool) private line1Hashes;
    mapping(address => uint256[]) private sharedHaikus;
    
    // System głosowania
    mapping(uint256 => uint256) public votes;
    mapping(address => mapping(uint256 => bool)) private hasVoted;

    // System ekonomiczny i marketplace
    mapping(uint256 => Listing) public marketplace;
    mapping(address => uint256) public pendingWithdrawals;

    // Definicje błędów niestandardowych (Custom Errors)
    error HaikuNotUnique();
    error NotYourHaiku(uint256 tokenId);
    error NoHaikusShared();
    error AlreadyVoted();
    error HaikuDoesNotExist();
    error NotForSale();
    error IncorrectPrice();
    error CannotBuyOwnHaiku();
    error TransferFailed();

    // Zdarzenia (Events) dla indeksowania danych (np. przez The Graph lub skrypty JS)
    event HaikuMinted(uint256 indexed id, address indexed author, string line1);
    event HaikuShared(uint256 indexed id, address indexed from, address indexed to);
    event HaikuVoted(uint256 indexed id, address indexed voter, uint256 currentVotes);
    event HaikuListed(uint256 indexed id, uint256 price);
    event HaikuSold(uint256 indexed id, address indexed from, address indexed to, uint256 price);

    constructor() ERC721("AdvancedHaikuNFT", "AHNK") {}

    // --- FUNKCJE ZAPISUJĄCE (MUTATIVE) ---

    function mintHaiku(
        string memory _line1,
        string memory _line2,
        string memory _line3
    ) external {
        bytes32 line1Hash = keccak256(abi.encodePacked(_line1));
        if (line1Hashes[line1Hash]) revert HaikuNotUnique();
        
        line1Hashes[line1Hash] = true;

        uint256 id = counter;
        haikus[id] = Haiku(msg.sender, _line1, _line2, _line3, block.timestamp);
        _mint(msg.sender, id);
        
        emit HaikuMinted(id, msg.sender, _line1);
        counter++;
    }

    function shareHaiku(uint256 _id, address _to) external {
        if (ownerOf(_id) != msg.sender) revert NotYourHaiku(_id);
        sharedHaikus[_to].push(_id);
        emit HaikuShared(_id, msg.sender, _to);
    }

    function vote(uint256 _id) external {
        if (_id >= counter) revert HaikuDoesNotExist();
        if (hasVoted[msg.sender][_id]) revert AlreadyVoted();
        
        hasVoted[msg.sender][_id] = true;
        votes[_id] += 1;

        emit HaikuVoted(_id, msg.sender, votes[_id]);
    }

    // --- NOWOŚĆ: MINI MARKETPLACE (KUPNO / SPRZEDAŻ) ---

    function listHaiku(uint256 _id, uint256 _price) external {
        if (ownerOf(_id) != msg.sender) revert NotYourHaiku(_id);
        marketplace[_id] = Listing(_price, true);
        emit HaikuListed(_id, _price);
    }

    function cancelListing(uint256 _id) external {
        if (ownerOf(_id) != msg.sender) revert NotYourHaiku(_id);
        marketplace[_id].isForSale = false;
    }

    function buyHaiku(uint256 _id) external payable {
        Listing memory listing = marketplace[_id];
        if (!listing.isForSale) revert NotForSale();
        if (msg.value != listing.price) revert IncorrectPrice();
        
        address seller = ownerOf(_id);
        if (seller == msg.sender) revert CannotBuyOwnHaiku();

        // Zamknięcie sprzedaży
        marketplace[_id].isForSale = false;

        // Naliczenie środków dla sprzedającego (Pull-over-Push pattern dla bezpieczeństwa przed reentrancy)
        pendingWithdrawals[seller] += msg.value;

        // Przekazanie tokenu NFT
        _transfer(seller, msg.sender, _id);

        emit HaikuSold(_id, seller, msg.sender, listing.price);
    }

    function withdrawFunds() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert IncorrectPrice();
        
        pendingWithdrawals[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    // --- FUNKCJE WIDOKU (VIEW / GETTERS) ---

    function getHaiku(uint256 _id) external view returns (Haiku memory) {
        if (_id >= counter) revert HaikuDoesNotExist();
        return haikus[_id];
    }

    function getMySharedHaikus() external view returns (Haiku[] memory) {
        uint256[] memory ids = sharedHaikus[msg.sender];
        if (ids.length == 0) revert NoHaikusShared();

        Haiku[] memory result = new Haiku[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = haikus[ids[i]];
        }
        return result;
    }

    // --- NOWOŚĆ: GENEROWANIE METADANYCH ON-CHAIN (DLA OPENSEA / METAMASK) ---

    function tokenURI(uint256 _id) public view override returns (string memory) {
        if (_id >= counter) revert HaikuDoesNotExist();
        Haiku memory haiku = haikus[_id];

        // Dynamiczne generowanie obrazka SVG zakodowanego w Base64
        string memory svg = string(
            abi.encodePacked(
                "<svg xmlns='http://w3.org' preserveAspectRatio='xMidYMid meet' viewBox='0 0 350 350' style='background-color:#121212; font-family:serif; fill:#ffffff; text-anchor:middle;'>",
                "<text x='175' y='130' font-size='16'>", haiku.line1, "</text>",
                "<text x='175' y='175' font-size='16'>", haiku.line2, "</text>",
                "<text x='175' y='220' font-size='16'>", haiku.line3, "</text>",
                "<text x='175' y='300' font-size='10' fill='#666666'>Glosy: ", votes[_id].toString(), "</text>",
                "</svg>"
            )
        );

        // Generowanie struktury JSON metadanych standardu ERC721
        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "Haiku #', _id.toString(), '", ',
                        '"description": "Unikalne cyfrowe poetyckie Haiku zapisane w blockchainie.", ',
                        '"image": "data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '", ',
                        '"attributes": [',
                            '{"trait_type": "Glosy", "value": ', votes[_id].toString(), '},',
                            '{"trait_type": "Autor", "value": "', uint256(uint160(haiku.author)).toHexString(20), '"}',
                        ']}'
                    )
                )
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", json));
    }
}
