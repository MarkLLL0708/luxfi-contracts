// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
contract LuxfiToken is ERC20, Ownable, ReentrancyGuard, Pausable {
struct Asset {
    string  name;
    string  category;
    uint256 valuation;
    uint256 totalTokens;
    uint256 soldTokens;
    uint256 tokenPriceCents;
    uint256 monthlyRevenue;
    bool    active;
}

uint256 public assetCount;
uint256 public constant MAX_PURCHASE = 1000000;
uint256 public constant BNB_PRICE_USD = 600;

mapping(uint256 => Asset) public assets;
mapping(address => mapping(uint256 => uint256)) public assetHoldings;
mapping(address => mapping(uint256 => uint256)) public yieldEarned;
mapping(address => uint256) public totalSpentBNB;

event AssetRegistered(uint256 id, string name);
event TokensPurchased(address indexed buyer, uint256 indexed assetId, uint256 amount, uint256 bnbPaid);
event YieldDistributed(uint256 indexed assetId, uint256 total);
event EmergencyWithdraw(address indexed owner, uint256 amount);

constructor() ERC20("LUXFI", "LUXFI") Ownable(msg.sender) {}

function registerAsset(string calldata name, string calldata category, uint256 valuation, uint256 totalTokens, uint256 tokenPriceCents) external onlyOwner returns (uint256) {
    require(bytes(name).length > 0, "Empty name");
    require(totalTokens > 0, "Zero tokens");
    require(tokenPriceCents > 0, "Zero price");
    uint256 id = assetCount++;
    assets[id] = Asset(name, category, valuation, totalTokens, 0, tokenPriceCents, 0, true);
    emit AssetRegistered(id, name);
    return id;
}

function setAssetActive(uint256 assetId, bool active) external onlyOwner {
    assets[assetId].active = active;
}

function updateRevenue(uint256 assetId, uint256 revenue) external onlyOwner {
    assets[assetId].monthlyRevenue = revenue;
}

function distributeYield(uint256 assetId, address[] calldata holders, uint256[] calldata amounts) external onlyOwner {
    require(holders.length == amounts.length, "Mismatch");
    require(holders.length <= 500, "Too many");
    uint256 total;
    for (uint256 i; i < holders.length; i++) {
        require(holders[i] != address(0), "Zero address");
        yieldEarned[holders[i]][assetId] += amounts[i];
        total += amounts[i];
    }
    emit YieldDistributed(assetId, total);
}

function pause() external onlyOwner {
    _pause();
}

function unpause() external onlyOwner {
    _unpause();
}

function withdraw() external onlyOwner {
    uint256 balance = address(this).balance;
    require(balance > 0, "Nothing to withdraw");
    (bool success, ) = payable(owner()).call{value: balance}("");
require(success, "Withdraw failed");
    emit EmergencyWithdraw(owner(), balance);
}

function buyTokens(uint256 assetId, uint256 tokenAmount) external payable nonReentrant whenNotPaused {
    require(tokenAmount > 0, "Zero amount");
    require(tokenAmount <= MAX_PURCHASE, "Exceeds max purchase");
    Asset storage a = assets[assetId];
    require(a.active, "Asset not active");
    require(a.soldTokens + tokenAmount <= a.totalTokens, "Sold out");
    uint256 costBNB = (tokenAmount * a.tokenPriceCents * 1e18) / (BNB_PRICE_USD * 100);
    require(msg.value >= costBNB, "Not enough BNB");
    _mint(msg.sender, tokenAmount * 1e18);
    assetHoldings[msg.sender][assetId] += tokenAmount;
    a.soldTokens += tokenAmount;
    totalSpentBNB[msg.sender] += costBNB;
    if (msg.value > costBNB) {
       (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - costBNB}("");
require(refundSuccess, "Refund failed");
    }
    emit TokensPurchased(msg.sender, assetId, tokenAmount, costBNB);
}

function getAsset(uint256 id) external view returns (Asset memory) {
    return assets[id];
}

function getAllAssets() external view returns (Asset[] memory) {
    Asset[] memory list = new Asset[](assetCount);
    for (uint256 i; i < assetCount; i++) {
        list[i] = assets[i];
    }
    return list;
}

function getHolding(address holder, uint256 assetId) external view returns (uint256) {
    return assetHoldings[holder][assetId];
}

function getYield(address holder, uint256 assetId) external view returns (uint256) {
    return yieldEarned[holder][assetId];
}

function getCostBNB(uint256 assetId, uint256 tokenAmount) external view returns (uint256) {
    return (tokenAmount * assets[assetId].tokenPriceCents * 1e18) / (BNB_PRICE_USD * 100);
}
}
