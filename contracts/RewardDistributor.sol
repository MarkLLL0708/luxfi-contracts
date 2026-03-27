// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract RewardDistributor is Ownable, Pausable, ReentrancyGuard {
IERC20 public luxfiToken;

struct RewardPool {
    uint256 brandId;
    uint256 totalReward;
    uint256 distributedAt;
    uint256 claimDeadline;
    bool active;
}

uint256 public poolCount;
mapping(uint256 => RewardPool) public pools;
mapping(uint256 => mapping(address => uint256)) public claimable;
mapping(uint256 => mapping(address => bool)) public claimed;
mapping(address => uint256) public totalClaimed;

event PoolCreated(uint256 indexed poolId, uint256 indexed brandId, uint256 totalReward);
event RewardAllocated(uint256 indexed poolId, address indexed user, uint256 amount);
event RewardClaimed(uint256 indexed poolId, address indexed user, uint256 amount);

constructor(address _luxfiToken) Ownable(msg.sender) {
    luxfiToken = IERC20(_luxfiToken);
}

function createPool(uint256 brandId, uint256 totalReward, uint256 claimDays) external onlyOwner returns (uint256) {
    require(totalReward > 0, "Zero reward");
    require(luxfiToken.transferFrom(msg.sender, address(this), totalReward), "Transfer failed");
    uint256 id = poolCount++;
    pools[id] = RewardPool(brandId, totalReward, block.timestamp, block.timestamp + (claimDays * 1 days), true);
    emit PoolCreated(id, brandId, totalReward);
    return id;
}

function allocateRewards(uint256 poolId, address[] calldata users, uint256[] calldata amounts) external onlyOwner {
    require(users.length == amounts.length, "Mismatch");
    require(users.length <= 500, "Too many");
    require(pools[poolId].active, "Pool not active");
    for (uint256 i; i < users.length; i++) {
        require(users[i] != address(0), "Zero address");
        claimable[poolId][users[i]] += amounts[i];
        emit RewardAllocated(poolId, users[i], amounts[i]);
    }
}

function claimReward(uint256 poolId) external nonReentrant whenNotPaused {
    require(!claimed[poolId][msg.sender], "Already claimed");
    require(block.timestamp <= pools[poolId].claimDeadline, "Claim period ended");
    uint256 amount = claimable[poolId][msg.sender];
    require(amount > 0, "Nothing to claim");
    claimed[poolId][msg.sender] = true;
    totalClaimed[msg.sender] += amount;
    require(luxfiToken.transfer(msg.sender, amount), "Transfer failed");
    emit RewardClaimed(poolId, msg.sender, amount);
}

function getClaimable(uint256 poolId, address user) external view returns (uint256) {
    return claimable[poolId][user];
}

function hasClaimed(uint256 poolId, address user) external view returns (bool) {
    return claimed[poolId][user];
}

function getPool(uint256 poolId) external view returns (RewardPool memory) {
    return pools[poolId];
}

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
}

