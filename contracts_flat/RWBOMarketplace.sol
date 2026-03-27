// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract RWBOMarketplace is Ownable, Pausable, ReentrancyGuard {
IERC20 public luxfiToken;

struct Listing {
    address seller;
    uint256 brandId;
    uint256 tokenAmount;
    uint256 pricePerToken;
    bool active;
    uint256 listedAt;
}

uint256 public listingCount;
uint256 public platformFeeBps = 250;
uint256 public constant MAX_FEE_BPS = 1000;
address public feeRecipient;

mapping(uint256 => Listing) public listings;
mapping(address => uint256[]) public userListings;
mapping(uint256 => uint256[]) public brandListings;

event Listed(uint256 indexed listingId, address indexed seller, uint256 indexed brandId, uint256 amount, uint256 price);
event Purchased(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 total);
event ListingCancelled(uint256 indexed listingId, address indexed seller);
event FeeUpdated(uint256 newFeeBps);

constructor(address _luxfiToken, address _feeRecipient) Ownable(msg.sender) {
    luxfiToken = IERC20(_luxfiToken);
    feeRecipient = _feeRecipient;
}

function listTokens(uint256 brandId, uint256 tokenAmount, uint256 pricePerToken) external whenNotPaused nonReentrant returns (uint256) {
    require(tokenAmount > 0, "Zero amount");
    require(pricePerToken > 0, "Zero price");
    require(luxfiToken.transferFrom(msg.sender, address(this), tokenAmount), "Transfer failed");
    uint256 id = listingCount++;
    listings[id] = Listing(msg.sender, brandId, tokenAmount, pricePerToken, true, block.timestamp);
    userListings[msg.sender].push(id);
    brandListings[brandId].push(id);
    emit Listed(id, msg.sender, brandId, tokenAmount, pricePerToken);
    return id;
}

function buyTokens(uint256 listingId, uint256 tokenAmount) external payable nonReentrant whenNotPaused {
    Listing storage l = listings[listingId];
    require(l.active, "Not active");
    require(tokenAmount > 0, "Zero amount");
    require(tokenAmount <= l.tokenAmount, "Exceeds listing");
    uint256 totalCost = tokenAmount * l.pricePerToken;
    require(msg.value >= totalCost, "Insufficient BNB");
    uint256 fee = (totalCost * platformFeeBps) / 10000;
    uint256 sellerAmount = totalCost - fee;
    l.tokenAmount -= tokenAmount;
    if (l.tokenAmount == 0) l.active = false;
    require(luxfiToken.transfer(msg.sender, tokenAmount), "Token transfer failed");
    (bool feeSuccess, ) = payable(feeRecipient).call{value: fee}("");
    require(feeSuccess, "Fee transfer failed");
    (bool sellerSuccess, ) = payable(l.seller).call{value: sellerAmount}("");
    require(sellerSuccess, "Seller transfer failed");
    if (msg.value > totalCost) {
        (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - totalCost}("");
        require(refundSuccess, "Refund failed");
    }
    emit Purchased(listingId, msg.sender, tokenAmount, totalCost);
}

function cancelListing(uint256 listingId) external nonReentrant {
    Listing storage l = listings[listingId];
    require(l.seller == msg.sender || msg.sender == owner(), "Not authorized");
    require(l.active, "Not active");
    l.active = false;
    require(luxfiToken.transfer(l.seller, l.tokenAmount), "Refund failed");
    emit ListingCancelled(listingId, l.seller);
}

function setFee(uint256 feeBps) external onlyOwner {
    require(feeBps <= MAX_FEE_BPS, "Fee too high");
    platformFeeBps = feeBps;
    emit FeeUpdated(feeBps);
}

function setFeeRecipient(address _feeRecipient) external onlyOwner {
    require(_feeRecipient != address(0), "Zero address");
    feeRecipient = _feeRecipient;
}

function getListing(uint256 listingId) external view returns (Listing memory) {
    return listings[listingId];
}

function getUserListings(address user) external view returns (uint256[] memory) {
    return userListings[user];
}

function getBrandListings(uint256 brandId) external view returns (uint256[] memory) {
    return brandListings[brandId];
}

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
}
