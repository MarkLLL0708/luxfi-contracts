// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract ParticipationVault is Ownable, Pausable, ReentrancyGuard {
IERC20 public luxfiToken;

struct Participation {
    uint256 brandId;
    uint256 amount;
    uint256 stakedAt;
    uint256 lockPeriod;
    bool active;
}

mapping(address => Participation[]) public participations;
mapping(address => mapping(uint256 => uint256)) public brandStake;
mapping(uint256 => uint256) public totalBrandStake;

uint256 public constant MIN_STAKE = 100 * 1e18;
uint256 public constant LOCK_30_DAYS = 30 days;
uint256 public constant LOCK_90_DAYS = 90 days;
uint256 public constant LOCK_180_DAYS = 180 days;

event Staked(address indexed user, uint256 indexed brandId, uint256 amount, uint256 lockPeriod);
event Unstaked(address indexed user, uint256 indexed brandId, uint256 amount);

constructor(address _luxfiToken) Ownable(msg.sender) {
    luxfiToken = IERC20(_luxfiToken);
}

function stake(uint256 brandId, uint256 amount, uint256 lockPeriod) external whenNotPaused nonReentrant {
    require(amount >= MIN_STAKE, "Below minimum stake");
    require(lockPeriod == LOCK_30_DAYS || lockPeriod == LOCK_90_DAYS || lockPeriod == LOCK_180_DAYS, "Invalid lock period");
    require(luxfiToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
    participations[msg.sender].push(Participation(brandId, amount, block.timestamp, lockPeriod, true));
    brandStake[msg.sender][brandId] += amount;
    totalBrandStake[brandId] += amount;
    emit Staked(msg.sender, brandId, amount, lockPeriod);
}

function unstake(uint256 participationIndex) external nonReentrant {
    Participation storage p = participations[msg.sender][participationIndex];
    require(p.active, "Not active");
    require(block.timestamp >= p.stakedAt + p.lockPeriod, "Still locked");
    p.active = false;
    brandStake[msg.sender][p.brandId] -= p.amount;
    totalBrandStake[p.brandId] -= p.amount;
    require(luxfiToken.transfer(msg.sender, p.amount), "Transfer failed");
    emit Unstaked(msg.sender, p.brandId, p.amount);
}

function getParticipations(address user) external view returns (Participation[] memory) {
    return participations[user];
}

function getBrandStake(address user, uint256 brandId) external view returns (uint256) {
    return brandStake[user][brandId];
}

function getTotalBrandStake(uint256 brandId) external view returns (uint256) {
    return totalBrandStake[brandId];
}

function getSharePercentage(address user, uint256 brandId) external view returns (uint256) {
    if (totalBrandStake[brandId] == 0) return 0;
    return (brandStake[user][brandId] * 10000) / totalBrandStake[brandId];
}

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
}
