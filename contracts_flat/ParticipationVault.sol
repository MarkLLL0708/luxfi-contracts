// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeDistributor {
    function receiveFees(string calldata source) external payable;
}

/**
 * @title ParticipationVault
 * @dev Fixes: slashFactorBps pool-level slash, removed O(n) loop, users never permanently locked
 */
contract ParticipationVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public luxfiToken;
    IFeeDistributor public feeDistributor;

    uint256 public constant MAX_STAKE_PER_BRAND = 1_000_000 * 1e18;
    uint256 public constant SLASH_RATE_BPS      = 1000;
    uint256 public constant DISPUTE_WINDOW      = 7 days;
    uint256 public constant PERCENT_DENOMINATOR = 10000;
    uint256 public constant BPS_BASE            = 10000;

    uint256 public stakeFeeBps   = 50;
    uint256 public unstakeFeeBps = 50;
    uint256 public claimFeeBps   = 30;
    uint256 public constant MAX_FEE_BPS = 200;

    struct Participation {
        uint256 brandId;
        uint256 tokenAmount;
        uint256 stakeAmount;
        uint256 startTime;
        uint256 lockPeriod;
        bool active;
        bool slashed;
        uint256 rewardDebt;
        uint256 lastClaimTime;
        uint256 holdingDays;
        uint256 weightScore;
    }

    struct BrandPool {
        uint256 brandId;
        uint256 totalStaked;
        uint256 rewardPool;
        uint256 rewardPerToken;
        bool active;
        bool disputed;
        uint256 disputedAt;
        uint256 slashFund;
        uint256 slashFactorBps;
    }

    mapping(address => mapping(uint256 => Participation)) public participations;
    mapping(uint256 => BrandPool) public brandPools;
    mapping(address => uint256[]) public userBrands;
    mapping(uint256 => address[]) public brandStakers;

    uint256 public totalProtocolFees;
    uint256 public totalSlashed;

    uint256 public constant TIER2_DAYS = 90;
    uint256 public constant TIER3_DAYS = 180;
    uint256 public constant TIER4_DAYS = 365;
    uint256 public constant TIER5_DAYS = 730;

    event Staked(address indexed user, uint256 indexed brandId, uint256 amount, uint256 fee);
    event Unstaked(address indexed user, uint256 indexed brandId, uint256 amount, uint256 fee);
    event RewardClaimed(address indexed user, uint256 indexed brandId, uint256 amount, uint256 fee);
    event RewardDeposited(uint256 indexed brandId, uint256 amount);
    event BrandDisputed(uint256 indexed brandId);
    event BrandSlashed(uint256 indexed brandId, uint256 slashAmount);
    event UserCompensated(address indexed user, uint256 indexed brandId, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed brandId, uint256 amount);
    event WeightScoreUpdated(address indexed user, uint256 indexed brandId, uint256 score);
    event ProtocolFeeCollected(uint256 amount, string action);

    constructor(address _luxfiToken, address _feeDistributor) Ownable(msg.sender) {
        require(_luxfiToken != address(0), "Invalid token");
        luxfiToken = IERC20(_luxfiToken);
        if (_feeDistributor != address(0)) feeDistributor = IFeeDistributor(_feeDistributor);
    }

    function addBrand(uint256 brandId) external onlyOwner {
        require(!brandPools[brandId].active, "Already exists");
        brandPools[brandId] = BrandPool({
            brandId: brandId, totalStaked: 0, rewardPool: 0, rewardPerToken: 0,
            active: true, disputed: false, disputedAt: 0, slashFund: 0,
            slashFactorBps: BPS_BASE
        });
    }

    function depositReward(uint256 brandId, uint256 amount) external onlyOwner {
        require(brandPools[brandId].active, "Brand not active");
        luxfiToken.safeTransferFrom(msg.sender, address(this), amount);
        BrandPool storage pool = brandPools[brandId];
        pool.rewardPool += amount;
        if (pool.totalStaked > 0) pool.rewardPerToken += (amount * 1e18) / pool.totalStaked;
        emit RewardDeposited(brandId, amount);
    }

    function stake(uint256 brandId, uint256 amount, uint256 lockPeriodDays) external nonReentrant whenNotPaused {
        require(brandPools[brandId].active, "Brand not active");
        require(!brandPools[brandId].disputed, "Brand disputed");
        require(amount > 0, "Zero amount");
        require(lockPeriodDays >= 1 && lockPeriodDays <= 365, "Invalid lock period");
        require(brandPools[brandId].totalStaked + amount <= MAX_STAKE_PER_BRAND, "Exceeds brand cap");

        uint256 fee = (amount * stakeFeeBps) / PERCENT_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        luxfiToken.safeTransferFrom(msg.sender, address(this), amount);
        if (fee > 0) _sendTokenFeeToDistributor(fee, "STAKE");

        Participation storage p = participations[msg.sender][brandId];
        if (!p.active) {
            userBrands[msg.sender].push(brandId);
            brandStakers[brandId].push(msg.sender);
            participations[msg.sender][brandId] = Participation({
                brandId: brandId, tokenAmount: amountAfterFee, stakeAmount: amountAfterFee,
                startTime: block.timestamp, lockPeriod: lockPeriodDays * 1 days,
                active: true, slashed: false, rewardDebt: brandPools[brandId].rewardPerToken,
                lastClaimTime: block.timestamp, holdingDays: 0, weightScore: amountAfterFee
            });
        } else {
            _claimReward(msg.sender, brandId);
            p.tokenAmount += amountAfterFee;
            p.stakeAmount += amountAfterFee;
            p.rewardDebt = brandPools[brandId].rewardPerToken;
        }

        brandPools[brandId].totalStaked += amountAfterFee;
        emit Staked(msg.sender, brandId, amountAfterFee, fee);
    }

    function unstake(uint256 brandId, uint256 amount) external nonReentrant whenNotPaused {
        Participation storage p = participations[msg.sender][brandId];
        BrandPool storage pool = brandPools[brandId];
        require(p.active, "No active participation");
        require(amount <= p.tokenAmount, "Exceeds staked amount");
        require(block.timestamp >= p.startTime + p.lockPeriod, "Still in lock period");

        _claimReward(msg.sender, brandId);

        uint256 effectiveAmount = (amount * pool.slashFactorBps) / BPS_BASE;
        uint256 fee = (effectiveAmount * unstakeFeeBps) / PERCENT_DENOMINATOR;
        uint256 amountAfterFee = effectiveAmount - fee;

        p.tokenAmount -= amount;
        p.stakeAmount -= amount;
        brandPools[brandId].totalStaked -= amount;
        if (p.tokenAmount == 0) p.active = false;

        if (fee > 0) _sendTokenFeeToDistributor(fee, "UNSTAKE");
        luxfiToken.safeTransfer(msg.sender, amountAfterFee);
        emit Unstaked(msg.sender, brandId, amountAfterFee, fee);
    }

    function claimReward(uint256 brandId) external nonReentrant whenNotPaused {
        _claimReward(msg.sender, brandId);
    }

    function _claimReward(address user, uint256 brandId) internal {
        Participation storage p = participations[user][brandId];
        BrandPool storage pool = brandPools[brandId];
        if (!p.active) return;

        uint256 multiplier = getLoyaltyMultiplier(user, brandId);
        uint256 pendingBase = (p.tokenAmount * (pool.rewardPerToken - p.rewardDebt)) / 1e18;
        uint256 pending = (pendingBase * multiplier) / 100;

        p.rewardDebt = pool.rewardPerToken;
        p.lastClaimTime = block.timestamp;
        p.holdingDays = (block.timestamp - p.startTime) / 1 days;
        p.weightScore = (p.tokenAmount * multiplier) / 100;

        if (pending == 0) return;

        uint256 fee = (pending * claimFeeBps) / PERCENT_DENOMINATOR;
        uint256 rewardAfterFee = pending - fee;
        if (fee > 0) _sendTokenFeeToDistributor(fee, "CLAIM_REWARD");

        if (rewardAfterFee > 0 && pool.rewardPool >= rewardAfterFee) {
            pool.rewardPool -= rewardAfterFee;
            luxfiToken.safeTransfer(user, rewardAfterFee);
            emit RewardClaimed(user, brandId, rewardAfterFee, fee);
        }
        emit WeightScoreUpdated(user, brandId, p.weightScore);
    }

    function _sendTokenFeeToDistributor(uint256 feeAmount, string memory action) internal {
        totalProtocolFees += feeAmount;
        emit ProtocolFeeCollected(feeAmount, action);
    }

    function settleProtocolFees(uint256 amount) external onlyOwner {
        require(amount <= totalProtocolFees, "Exceeds collected fees");
        luxfiToken.safeTransfer(owner(), amount);
        totalProtocolFees -= amount;
    }

    function disputeBrand(uint256 brandId) external onlyOwner {
        require(brandPools[brandId].active, "Brand not active");
        require(!brandPools[brandId].disputed, "Already disputed");
        brandPools[brandId].disputed = true;
        brandPools[brandId].disputedAt = block.timestamp;
        emit BrandDisputed(brandId);
    }

    function slashBrand(uint256 brandId) external onlyOwner {
        BrandPool storage pool = brandPools[brandId];
        require(pool.disputed, "Not disputed");
        require(block.timestamp <= pool.disputedAt + DISPUTE_WINDOW, "Dispute window expired");

        uint256 slashAmount = (pool.totalStaked * SLASH_RATE_BPS) / PERCENT_DENOMINATOR;
        pool.slashFactorBps = (pool.slashFactorBps * (BPS_BASE - SLASH_RATE_BPS)) / BPS_BASE;
        pool.slashFund += slashAmount;
        pool.totalStaked -= slashAmount;
        totalSlashed += slashAmount;
        emit BrandSlashed(brandId, slashAmount);
    }

    function compensateUser(address user, uint256 brandId, uint256 amount) external onlyOwner {
        BrandPool storage pool = brandPools[brandId];
        require(pool.slashFund >= amount, "Insufficient slash fund");
        pool.slashFund -= amount;
        luxfiToken.safeTransfer(user, amount);
        emit UserCompensated(user, brandId, amount);
    }

    function emergencyWithdrawAll(uint256 brandId) external nonReentrant {
        require(paused(), "Only when paused");
        Participation storage p = participations[msg.sender][brandId];
        require(p.active, "No active participation");
        BrandPool storage pool = brandPools[brandId];

        uint256 effectiveAmount = (p.tokenAmount * pool.slashFactorBps) / BPS_BASE;
        p.active = false;
        p.tokenAmount = 0;
        pool.totalStaked -= effectiveAmount;

        luxfiToken.safeTransfer(msg.sender, effectiveAmount);
        emit EmergencyWithdraw(msg.sender, brandId, effectiveAmount);
    }

    function getLoyaltyMultiplier(address user, uint256 brandId) public view returns (uint256) {
        Participation storage p = participations[user][brandId];
        if (!p.active) return 100;
        uint256 daysHeld = (block.timestamp - p.startTime) / 1 days;
        if (daysHeld >= TIER5_DAYS) return 250;
        if (daysHeld >= TIER4_DAYS) return 200;
        if (daysHeld >= TIER3_DAYS) return 150;
        if (daysHeld >= TIER2_DAYS) return 125;
        return 100;
    }

    function setFees(uint256 _s, uint256 _u, uint256 _c) external onlyOwner {
        require(_s <= MAX_FEE_BPS && _u <= MAX_FEE_BPS && _c <= MAX_FEE_BPS, "Fee too high");
        stakeFeeBps = _s; unstakeFeeBps = _u; claimFeeBps = _c;
    }

    function setFeeDistributor(address distributor) external onlyOwner {
        require(distributor != address(0), "Invalid distributor");
        feeDistributor = IFeeDistributor(distributor);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getParticipation(address user, uint256 brandId) external view returns (Participation memory) { return participations[user][brandId]; }
    function getBrandPool(uint256 brandId) external view returns (BrandPool memory) { return brandPools[brandId]; }
    function getUserBrands(address user) external view returns (uint256[] memory) { return userBrands[user]; }
    function getBrandStakers(uint256 brandId) external view returns (address[] memory) { return brandStakers[brandId]; }
}
