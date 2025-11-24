// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {FrameMarket} from "../src/FrameMarket.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract FrameMarketTest is Test {
    FrameMarket public market;
    MockERC721 public nft;
    
    address public owner = address(1);
    address public seller = address(2);
    address public buyer = address(3);
    address public feeRecipient = address(4);
    
    uint16 public constant FEE_BPS = 250; // 2.5%
    uint256 public constant PRICE = 1 ether;
    
    function setUp() public {
        // Deploy contracts
        vm.prank(owner);
        market = new FrameMarket(FEE_BPS, feeRecipient);
        
        nft = new MockERC721("Test NFT", "TNFT");
        
        // Mint NFT to seller
        nft.mint(seller, 1);
        
        // Give buyer some ETH
        vm.deal(buyer, 10 ether);
    }
    
    function testList() public {
        vm.startPrank(seller);
        
        // Approve marketplace
        nft.approve(address(market), 1);
        
        // List NFT
        uint96 listingId = market.list(address(nft), 1, PRICE);
        
        // Verify listing
        (address listSeller, address listNft, uint256 listTokenId, uint256 listPrice, bool active) = market.listings(listingId);
        
        assertEq(listSeller, seller);
        assertEq(listNft, address(nft));
        assertEq(listTokenId, 1);
        assertEq(listPrice, PRICE);
        assertTrue(active);
        
        // Verify NFT transferred to escrow
        assertEq(nft.ownerOf(1), address(market));
        
        vm.stopPrank();
    }
    
    function testPurchase() public {
        // Seller lists NFT
        vm.startPrank(seller);
        nft.approve(address(market), 1);
        uint96 listingId = market.list(address(nft), 1, PRICE);
        vm.stopPrank();
        
        // Buyer purchases
        uint256 sellerBalanceBefore = seller.balance;
        uint256 feeRecipientBalanceBefore = feeRecipient.balance;
        
        vm.prank(buyer);
        market.purchase{value: PRICE}(listingId);
        
        // Verify NFT transferred to buyer
        assertEq(nft.ownerOf(1), buyer);
        
        // Verify payments
        uint256 expectedFee = (PRICE * FEE_BPS) / 10_000;
        uint256 expectedSellerProceeds = PRICE - expectedFee;
        
        assertEq(seller.balance - sellerBalanceBefore, expectedSellerProceeds);
        assertEq(feeRecipient.balance - feeRecipientBalanceBefore, expectedFee);
        
        // Verify listing inactive
        (, , , , bool active) = market.listings(listingId);
        assertFalse(active);
    }
    
    function testCancel() public {
        // Seller lists NFT
        vm.startPrank(seller);
        nft.approve(address(market), 1);
        uint96 listingId = market.list(address(nft), 1, PRICE);
        
        // Cancel listing
        market.cancel(listingId);
        
        // Verify NFT returned to seller
        assertEq(nft.ownerOf(1), seller);
        
        // Verify listing inactive
        (, , , , bool active) = market.listings(listingId);
        assertFalse(active);
        
        vm.stopPrank();
    }
    
    function testUpdatePrice() public {
        vm.startPrank(seller);
        nft.approve(address(market), 1);
        uint96 listingId = market.list(address(nft), 1, PRICE);
        
        uint256 newPrice = 2 ether;
        market.updatePrice(listingId, newPrice);
        
        (, , , uint256 listPrice, ) = market.listings(listingId);
        assertEq(listPrice, newPrice);
        
        vm.stopPrank();
    }
    
    function testRevertInvalidPrice() public {
        vm.startPrank(seller);
        nft.approve(address(market), 1);
        
        vm.expectRevert(FrameMarket.InvalidPrice.selector);
        market.list(address(nft), 1, 0);
        
        vm.stopPrank();
    }
    
    function testRevertNotOwner() public {
        vm.prank(buyer);
        nft.approve(address(market), 1);
        
        vm.expectRevert("not owner");
        market.list(address(nft), 1, PRICE);
    }
    
    function testRevertInsufficientPayment() public {
        vm.startPrank(seller);
        nft.approve(address(market), 1);
        uint96 listingId = market.list(address(nft), 1, PRICE);
        vm.stopPrank();
        
        vm.prank(buyer);
        vm.expectRevert(FrameMarket.InvalidPrice.selector);
        market.purchase{value: PRICE - 1}(listingId);
    }
}