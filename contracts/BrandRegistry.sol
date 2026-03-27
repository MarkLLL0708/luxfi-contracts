// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
contract BrandRegistry is Ownable, Pausable {
enum BrandStatus { Pending, Active, Suspended, Removed }

struct Brand {
    string name;
    string category;
    string country;
    address brandWallet;
    BrandStatus status;
    uint256 registeredAt;
    uint256 monthlyRevenue;
    bool posConnected;
}

uint256 public brandCount;
mapping(uint256 => Brand) public brands;
mapping(address => uint256) public walletToBrandId;
mapping(address => bool) public isVerifiedBrand;

event BrandRegistered(uint256 indexed id, string name, address wallet);
event BrandStatusUpdated(uint256 indexed id, BrandStatus status);
event BrandRevenueUpdated(uint256 indexed id, uint256 revenue);
event POSConnected(uint256 indexed id, bool connected);

constructor() Ownable(msg.sender) {}

function registerBrand(string calldata name, string calldata category, string calldata country, address brandWallet) external onlyOwner returns (uint256) {
    require(bytes(name).length > 0, "Empty name");
    require(brandWallet != address(0), "Zero address");
    require(!isVerifiedBrand[brandWallet], "Already registered");
    uint256 id = brandCount++;
    brands[id] = Brand(name, category, country, brandWallet, BrandStatus.Pending, block.timestamp, 0, false);
    walletToBrandId[brandWallet] = id;
    emit BrandRegistered(id, name, brandWallet);
    return id;
}

function activateBrand(uint256 id) external onlyOwner {
    brands[id].status = BrandStatus.Active;
    isVerifiedBrand[brands[id].brandWallet] = true;
    emit BrandStatusUpdated(id, BrandStatus.Active);
}

function suspendBrand(uint256 id) external onlyOwner {
    brands[id].status = BrandStatus.Suspended;
    isVerifiedBrand[brands[id].brandWallet] = false;
    emit BrandStatusUpdated(id, BrandStatus.Suspended);
}

function updateRevenue(uint256 id, uint256 revenue) external onlyOwner {
    brands[id].monthlyRevenue = revenue;
    emit BrandRevenueUpdated(id, revenue);
}

function setPOSConnected(uint256 id, bool connected) external onlyOwner {
    brands[id].posConnected = connected;
    emit POSConnected(id, connected);
}

function getBrand(uint256 id) external view returns (Brand memory) {
    return brands[id];
}

function getAllBrands() external view returns (Brand[] memory) {
    Brand[] memory list = new Brand[](brandCount);
    for (uint256 i; i < brandCount; i++) {
        list[i] = brands[i];
    }
    return list;
}

function isBrandActive(uint256 id) external view returns (bool) {
    return brands[id].status == BrandStatus.Active;
}

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
}
