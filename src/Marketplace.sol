// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

/// @title NFT Marketplace for AviArte Collections
/// @author Simranjeet Singh
/// @notice Buy and Sell ERC721 or ERC1155 NFTs with any ERC20 or native token.
/// Two ways to buy - either instant buy at specified price or make an offer to seller.
/// @dev Buy and Sell fundamentally simillar to Escrow operations
/// i.e NFT locked in the contract on sell, until bought for a specific amount
contract AviArteMarketPlace is
    ReentrancyGuardUpgradeable,
    IERC1155ReceiverUpgradeable,
    IERC721ReceiverUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public orderNonce;
    uint256 public platformFees;

    struct Order {
        uint256 tokenId;
        uint256 pricePerNFT;
        uint16 copies;
        address seller;
        uint256 startTime;
        uint256 endTime;
        address paymentToken;
        address nftContract;
    }

    struct Bid {
        address bidder;
        uint256 pricePerNFT;
        uint16 copies;
        uint256 startTime;
        uint256 endTime;
        BidStatus status;
    }

    mapping(uint256 => Order) public order;
    mapping(uint256 => Bid[]) public bids; // many-to-one relationship with Order , orderId => Bid[]
    mapping(address => bool) public nftContracts;
    mapping(address => bool) public tokensSupport;

    struct Fee {
        uint256 feeGenerated;
        uint256 feeClaimed;
    }

    mapping(address => Fee) public feeCollected;

    enum BidStatus {
        Placed,
        Accepted,
        Rejected,
        Withdraw
    }

    event OrderCreated(
        uint256 indexed orderId,
        uint256 indexed tokenId,
        uint256 pricePerNFT,
        address seller,
        uint16 copies,
        uint256 startTime,
        uint256 endTime,
        address paymentToken,
        address nftContract
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderPurchased(uint256 indexed orderId, address buyer, uint16 copies);
    event BidPlaced(
        uint256 indexed orderId,
        uint256 bidIndex,
        address bidder,
        uint16 copies,
        uint256 pricePerNFT,
        uint256 startTime,
        uint256 endTime
    );
    event BidWithdraw(uint256 indexed orderId, uint256 bidId);
    event BidRejected(uint256 indexed orderId, uint256 bidId);
    event BidAccepted(uint256 indexed orderId, uint256 bidId, uint16 copies);
    event AddNFTSupport(address indexed nftAddress);
    event AddTokenSupport(address indexed tokenAddress);
    event FeeClaimed(address indexed tokenAddress, address to, uint256 amount);

    function initialize(uint256 _platformFees) external initializer {
        platformFees = _platformFees;
        __Ownable_init();
    }

    /// @dev add NFT contract to whitelist by owner
    function addNftContractSupport(address nftAddress) public onlyOwner {
        nftContracts[nftAddress] = true;
        emit AddNFTSupport(nftAddress);
    }

    /// @dev add Token contract whitelis by owner
    function addTokenSupport(address tokenAddress) public onlyOwner {
        tokensSupport[tokenAddress] = true;
        emit AddTokenSupport(tokenAddress);
    }

    /// @dev owner can set/change Platform Fees
    /// @param fee is in multiple of 100  i.e. for 0.01% -> fee = 100 (max 5%)
    function setPlatformFees(uint256 fee) external onlyOwner {
        require(fee <= 50000, "High fee");
        platformFees = fee;
    }

    /// @notice Place a Sell NFT Order
    /// @dev when Order is placed, seller transfer NFT to this contract (escrow lock)
    /// @param tokenId - tokenId from the specified collection
    /// @param nftContract whitelisted NFT collection
    /// @param copies == 0 means it's ERC721 NFT order
    /// @param pricePerNFT specify prefered price for a single NFT in wei
    /// @param paymentToken == 0x address means sale with Native Token i.e eth
    /// @param endTime  datetime in seconds after which order is expired.
    function placeOrderForSell(
        uint256 tokenId,
        address nftContract,
        uint16 copies, // = 0 means 721 NFT
        uint256 pricePerNFT,
        address paymentToken,
        uint256 endTime
    ) external {
        require(nftContract != address(0) && nftContracts[nftContract], "Invalid NFT Contract");
        require((paymentToken == address(0) || tokensSupport[paymentToken]), "Invalid token Contract");
        require(endTime > block.timestamp, "endTime should be in future");
        require(pricePerNFT > 0, "Invalid price");
        order[orderNonce] =
            Order(tokenId, pricePerNFT, copies, msg.sender, block.timestamp, endTime, paymentToken, nftContract);
        orderNonce++;
        if (copies == 0) {
            IERC721Upgradeable(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
        } else {
            IERC1155Upgradeable(nftContract).safeTransferFrom(msg.sender, address(this), tokenId, copies, "");
        }
        emit OrderCreated(
            orderNonce - 1,
            tokenId,
            pricePerNFT,
            msg.sender,
            copies,
            block.timestamp,
            endTime,
            paymentToken,
            nftContract
        );
    }

    /// @notice Cancels the order and receive NFT back
    /// @dev Transfer NFT back to seller, reject all existing bids for the order, delete order storage
    /// @param orderId Id of an existing Order (caller should be the seller)
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage _order = order[orderId];
        require(_order.seller == msg.sender, "Invalid request");

        if (_order.copies == 0) {
            IERC721Upgradeable(_order.nftContract).safeTransferFrom(address(this), msg.sender, _order.tokenId);
        } else {
            IERC1155Upgradeable(_order.nftContract).safeTransferFrom(
                address(this), msg.sender, _order.tokenId, _order.copies, ""
            );
        }

        returnAmountToRemainingBidder(orderId);

        delete order[orderId];
        emit OrderCancelled(orderId);
    }

    /// @notice buy NFT instantly at seller specified price
    /// @dev buy amount sent to seller after deducting fees, and locked NFT transfered to buyer
    /// If No NFT left after this sale, remaining bids are refunded and Order storage deleted
    /// @param orderId Id of an existing Sell Order
    /// @param copies no. of copies to buy (== 0 -> required if order is of 721 NFT)
    function buyNow(
        uint256 orderId,
        uint16 copies // copies = 0 if 721 token
    ) public payable nonReentrant {
        Order storage _order = order[orderId];
        require(_order.seller != address(0), "Invalid order request"); // if order is deleted
        require(_order.endTime > block.timestamp, "Order expired");
        require(copies <= _order.copies, "not enough quantity");

        bool isNative = _order.paymentToken == address(0);

        uint256 totalAmount = _order.pricePerNFT * (copies == 0 ? 1 : copies);
        uint256 feeValue = (platformFees * totalAmount) / 10000;
        feeCollected[_order.paymentToken].feeGenerated += feeValue;

        if (isNative) {
            require(msg.value >= totalAmount, "Not sufficient funds");
            (bool success,) = payable(_order.seller).call{value: totalAmount - feeValue}("");
            require(success, "Transfer Failed");
        } else {
            IERC20Upgradeable ERC20Interface = IERC20Upgradeable(_order.paymentToken);
            ERC20Interface.safeTransferFrom(msg.sender, address(this), totalAmount);

            ERC20Interface.safeTransfer((_order.seller), totalAmount - feeValue);
        }
        if (_order.copies == 0) {
            IERC721Upgradeable(_order.nftContract).safeTransferFrom(address(this), msg.sender, _order.tokenId);
        } else {
            IERC1155Upgradeable(_order.nftContract).safeTransferFrom(
                address(this), msg.sender, _order.tokenId, copies, ""
            );
        }

        if (_order.copies == copies) {
            returnAmountToRemainingBidder(orderId);
            delete (order[orderId]);
        } else {
            order[orderId].copies -= copies;
        }
        emit OrderPurchased(orderId, msg.sender, copies);
    }

    /// @notice buy multiple NFT/Order at seller specified price
    /// @param orderIds array of Sell OrderIds
    /// @param amounts array of no. of copies to buy  ( 0 -> required if order is of 721 NFT )
    function bulkBuy(uint256[] calldata orderIds, uint16[] calldata amounts) external payable {
        require(orderIds.length == amounts.length, "Not same length input");
        for (uint256 i = 0; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            uint16 copies = amounts[i];
            buyNow(orderId, copies);
        }
    }

    /// @notice Make on offer to the seller for an order (can be less than or even grater than seller specified price)
    /// @dev Offer amount (Token) is locked in the contract until any action is taken on the offer i.e (Accept/Reject/Withdraw)
    /// @param orderId Id of an existing Sell Order
    /// @param copies no. of copies to buy (== 0 -> required if order is of 721 NFT)
    /// @param pricePerNFT your offer price (per 1 NFT)
    /// @param endTime datetime in seconds after which offer is expired i.e can't be accepted
    function placeOfferForOrder(
        uint256 orderId,
        uint16 copies, // 0 for 721
        uint256 pricePerNFT,
        uint256 endTime
    ) external payable {
        Order storage _order = order[orderId];
        require(_order.seller != address(0), "Invalid order request");
        require(_order.seller != msg.sender, "Invalid request");
        require(endTime > block.timestamp, "endTime should be in future");
        require(_order.endTime > block.timestamp, "Order expired ");
        require(copies <= _order.copies, "not enough quantity");

        uint256 totalBids = bids[orderId].length;

        bool isNative = _order.paymentToken == address(0);

        uint256 totalAmount = pricePerNFT * (copies == 0 ? 1 : copies);
        if (isNative) {
            require(msg.value >= totalAmount, "not enough balance");
        } else {
            IERC20Upgradeable ERC20Interface = IERC20Upgradeable(_order.paymentToken);
            ERC20Interface.safeTransferFrom(msg.sender, address(this), totalAmount);
        }
        bids[orderId].push(Bid(msg.sender, pricePerNFT, copies, block.timestamp, endTime, BidStatus.Placed));

        emit BidPlaced(orderId, totalBids, msg.sender, copies, pricePerNFT, block.timestamp, endTime);
    }

    /// @notice Seller can accept the bid on his order
    /// @dev offer amount sent to seller after deducting fees, and locked NFT transfered to buyer
    /// If No NFT left after this sale, remaining bids are refunded and Order storage deleted
    /// @param orderId Id of an existing Sell Order
    /// @param bidId   Id of the bid placed on specified order
    function acceptBid(uint256 orderId, uint256 bidId) external nonReentrant {
        Order storage _order = order[orderId];
        Bid storage _bid = bids[orderId][bidId];
        require(_order.seller == msg.sender, "not invlid request");
        require(_order.copies >= _bid.copies, "Nft not available");
        require(_bid.endTime > block.timestamp, "Bid expired");
        require(_bid.status == BidStatus.Placed, "Bid not valid anymore");

        bool isNative = _order.paymentToken == address(0);

        uint256 totalAmount = _bid.pricePerNFT * (_bid.copies == 0 ? 1 : _bid.copies);
        uint256 feeValue = (platformFees * totalAmount) / 10000;
        feeCollected[_order.paymentToken].feeGenerated += feeValue;

        if (_order.copies == 0) {
            IERC721Upgradeable(_order.nftContract).safeTransferFrom(address(this), _bid.bidder, _order.tokenId);
        } else {
            IERC1155Upgradeable(_order.nftContract).safeTransferFrom(
                address(this), _bid.bidder, _order.tokenId, _bid.copies, ""
            );
        }
        if (isNative) {
            (bool success,) = payable(_order.seller).call{value: totalAmount - feeValue}("");
            require(success, "Transfer Failed");
        } else {
            safeTransferAmount(_order.paymentToken, _order.seller, (totalAmount - feeValue));
        }
        bids[orderId][bidId].status = BidStatus.Accepted;
        _order.copies = _order.copies - _bid.copies;
        if (_order.copies == 0) {
            returnAmountToRemainingBidder(orderId);
            delete order[orderId];
        }
        emit BidAccepted(orderId, bidId, _bid.copies);
    }

    /// @notice Seller Or Bidder can Reject or Withdraw the bid on the order respectivcecly
    /// @dev locked tokens/bid amount is sent back to the bidder
    /// @param orderId Id of an existing Sell Order
    /// @param bidId   Id of the bid placed on specified order
    /// @param isReject  if caller is seller = true (i.e Reject Bid) else if bidder = false (i.e. Withdraw)
    function withdrawRejectBid(uint256 orderId, uint256 bidId, bool isReject) external nonReentrant {
        Order storage _order = order[orderId];
        Bid storage _bid = bids[orderId][bidId];
        require(_bid.status == BidStatus.Placed, "cant process");

        if (isReject) {
            require(_order.seller == msg.sender, "cant process");
        } else {
            require(_bid.bidder == msg.sender, "cant process");
        }

        if (isReject) {
            bids[orderId][bidId].status = BidStatus.Rejected;
            emit BidRejected(orderId, bidId);
        } else {
            bids[orderId][bidId].status = BidStatus.Withdraw;
            emit BidWithdraw(orderId, bidId);
        }

        bool isNative = _order.paymentToken == address(0);

        uint256 totalAmount = _bid.pricePerNFT * (_bid.copies == 0 ? 1 : _bid.copies);

        if (isNative) {
            (bool success,) = payable(_bid.bidder).call{value: totalAmount}("");
            require(success, "Transfer Failed");
        } else {
            safeTransferAmount(_order.paymentToken, _bid.bidder, totalAmount);
        }
    }

    /// @notice Owner Can withdraw a particular token and amount collected as a platform fees
    /// needs to be used carefully, calls will fail if no enough balance in contract for escrow operations
    function collectAdminFees(address tokenAddress, address to) external onlyOwner {
        Fee memory availableTokens = feeCollected[tokenAddress];
        uint256 feeToBeCollected = availableTokens.feeGenerated - availableTokens.feeClaimed;

        if (tokenAddress == address(0)) {
            payable(to).transfer(feeToBeCollected);
        } else {
            require(tokensSupport[tokenAddress], "unsupported token address");
            IERC20Upgradeable ERC20Interface = IERC20Upgradeable(tokenAddress);
            ERC20Interface.safeTransfer(to, feeToBeCollected);
        }
        feeCollected[tokenAddress].feeClaimed += feeToBeCollected;
        emit FeeClaimed(tokenAddress, to, feeToBeCollected);
    }

    /// @dev Utils fn for ERC20 transfer
    function safeTransferAmount(address token, address to, uint256 amount) private {
        IERC20Upgradeable ERC20Interface = IERC20Upgradeable(token);
        ERC20Interface.safeTransfer(to, amount);
    }

    /// @dev Utils fn for tranfering bid amounts back after order is fulfilled
    function returnAmountToRemainingBidder(uint256 orderId) private {
        Order storage _order = order[orderId];
        bool isNative = _order.paymentToken == address(0);
        for (uint256 i = 0; i < bids[orderId].length; ++i) {
            if (bids[orderId][i].status == BidStatus.Placed) {
                uint256 amount =
                    (bids[orderId][i].copies == 0 ? 1 : bids[orderId][i].copies) * bids[orderId][i].pricePerNFT;

                bids[orderId][i].status = BidStatus.Rejected;
                emit BidRejected(orderId, i);
                if (isNative) {
                    (bool success,) = payable(bids[orderId][i].bidder).call{value: amount}("");
                    require(success, "Transfer Failed");
                } else {
                    safeTransferAmount(_order.paymentToken, bids[orderId][i].bidder, amount);
                }
            }
        }
    }

    /// @dev The following function is overrides required by Solidity.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return (bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")));
    }

    /// @dev The following function is overrides required by Solidity.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return (bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)")));
    }

    /// @dev The following function is overrides required by Solidity.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return (bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
    }

    /// @dev The following function is overrides required by Solidity.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155ReceiverUpgradeable).interfaceId
            || interfaceId == type(IERC721ReceiverUpgradeable).interfaceId;
    }
}
