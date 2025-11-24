// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FrameMarket is ReentrancyGuard, Ownable, IERC721Receiver {
    struct Listing {
        address seller;
        address nft;
        uint256 tokenId;
        uint256 price;      // in wei
        bool active;
    }

    uint96 public nextListingId;
    uint16 public feeBps;          // e.g. 250 = 2.5%
    address public feeRecipient;

    mapping(uint96 => Listing) public listings;

    event Listed(uint96 indexed id, address indexed seller, address indexed nft, uint256 tokenId, uint256 price);
    event ListingUpdated(uint96 indexed id, uint256 newPrice);
    event ListingCancelled(uint96 indexed id);
    event Purchased(
        uint96 indexed id,
        address indexed buyer,
        address indexed seller,
        address nft,
        uint256 tokenId,
        uint256 price
    );
    event FeeCollected(uint96 indexed listingId, address indexed recipient, uint256 amount);
    event FeeUpdated(uint16 feeBps, address feeRecipient);

    error NotSeller();
    error NotActive();
    error InvalidPrice();
    error NotApproved();
    error TransferFailed();
    error ListingIdOverflow();
    error NotERC721();
    error FeeRecipientZero();
    error FeeTooHigh();

    constructor(uint16 _feeBps, address _feeRecipient) Ownable(msg.sender) {
        if (_feeRecipient == address(0)) revert FeeRecipientZero();
        if (_feeBps > 1000) revert FeeTooHigh(); // max 10%
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    modifier onlyActive(uint96 listingId) {
        if (!listings[listingId].active) revert NotActive();
        _;
    }

    /**
     * @notice List an NFT for sale. NFT is transferred into escrow.
     * @param nft The NFT contract address
     * @param tokenId The token ID to list
     * @param price The price in wei
     * @return listingId The ID of the created listing
     */
    function list(address nft, uint256 tokenId, uint256 price) external returns (uint96 listingId) {
        if (price == 0) revert InvalidPrice();
        
        // Check for listing ID overflow
        if (nextListingId >= type(uint96).max) revert ListingIdOverflow();
        
        // Verify the contract implements ERC721
        try IERC165(nft).supportsInterface(type(IERC721).interfaceId) returns (bool supported) {
            if (!supported) revert NotERC721();
        } catch {
            revert NotERC721();
        }

        IERC721 token = IERC721(nft);

        // Verify ownership
        require(token.ownerOf(tokenId) == msg.sender, "not owner");

        // Create listing
        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            nft: nft,
            tokenId: tokenId,
            price: price,
            active: true
        });

        // Transfer NFT into escrow
        token.safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(listingId, msg.sender, nft, tokenId, price);
    }

    /**
     * @notice Update the price of an active listing
     * @param listingId The listing ID
     * @param newPrice The new price in wei
     */
    function updatePrice(uint96 listingId, uint256 newPrice) external onlyActive(listingId) {
        Listing storage listing = listings[listingId];
        if (listing.seller != msg.sender) revert NotSeller();
        if (newPrice == 0) revert InvalidPrice();

        listing.price = newPrice;
        emit ListingUpdated(listingId, newPrice);
    }

    /**
     * @notice Cancel an active listing and return NFT to seller
     * @param listingId The listing ID to cancel
     */
    function cancel(uint96 listingId) external onlyActive(listingId) {
        Listing storage listing = listings[listingId];
        if (listing.seller != msg.sender) revert NotSeller();

        // Mark as inactive
        listing.active = false;

        // Return NFT to seller
        IERC721(listing.nft).safeTransferFrom(address(this), msg.sender, listing.tokenId);

        emit ListingCancelled(listingId);
    }

    /**
     * @notice Purchase an active listing
     * @param listingId The listing ID to purchase
     */
    function purchase(uint96 listingId) external payable nonReentrant onlyActive(listingId) {
        Listing storage listing = listings[listingId];
        if (msg.value != listing.price) revert InvalidPrice();

        // Mark as inactive first (checks-effects-interactions)
        listing.active = false;

        // Cache values to save gas
        address seller = listing.seller;
        address nft = listing.nft;
        uint256 tokenId = listing.tokenId;
        uint256 price = listing.price;

        // Calculate fees
        uint256 feeAmount = (price * feeBps) / 10_000;
        uint256 sellerProceeds = price - feeAmount;

        // Transfer NFT to buyer first (most important state change)
        IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);

        // Then handle ETH transfers
        if (feeAmount > 0) {
            (bool fSent, ) = feeRecipient.call{value: feeAmount}("");
            if (!fSent) revert TransferFailed();
            emit FeeCollected(listingId, feeRecipient, feeAmount);
        }
        
        (bool sSent, ) = seller.call{value: sellerProceeds}("");
        if (!sSent) revert TransferFailed();

        emit Purchased(listingId, msg.sender, seller, nft, tokenId, price);
    }

    /**
     * @notice Update marketplace fee (owner only)
     * @param _feeBps New fee in basis points (max 1000 = 10%)
     * @param _feeRecipient New fee recipient address
     */
    function setFee(uint16 _feeBps, address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert FeeRecipientZero();
        if (_feeBps > 1000) revert FeeTooHigh(); // max 10%
        
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeUpdated(_feeBps, _feeRecipient);
    }

    /**
     * @notice Required to receive ERC721 tokens
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Get listing details
     * @param listingId The listing ID
     * @return The listing struct
     */
    function getListing(uint96 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    /**
     * @notice Check if a listing is active
     * @param listingId The listing ID
     * @return Whether the listing is active
     */
    function isListingActive(uint96 listingId) external view returns (bool) {
        return listings[listingId].active;
    }
}