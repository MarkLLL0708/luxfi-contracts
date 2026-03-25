// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPancakeRouter {
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}

interface ILuxfiToken {
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title LuxfiFeeDistributor
 * @dev Fixes: slippage protection on buyback, yield actually distributed to stakers
 */
contract LuxfiFeeDistributor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ILuxfiToken public luxfiToken;
    IERC20 public usdtToken;
    IPancakeRouter public pancakeRouter;

    uint256 public stakerShareBps    = 3000;
    uint256 public burnShareBps      = 2500;
    uint256 public treasuryShareBps  = 2000;
    uint256 public aiMissionShareBps = 1500;
    uint256 public loyaltyShareBps   = 1000;
    uint256 public constant TOTAL_BPS = 10000;
    uint256 public minBuybackSlippageBps = 500;

    address public treasuryWallet;
    address public aiMissionPool;
    address public loyaltyPool;
    address public stakingPool;

    mapping(address => bool) public whitelistedSenders;

    uint256 public totalFeesReceived;
    uint256 public totalBurned;
    uint256 public totalStakerYield;
    uint256 public totalTreasuryFees;
    uint256 public totalAIMissionFees;
    uint256 public totalLoyaltyFees;

    uint256 public pendingBurnAmount;
    uint256 public minBurnThreshold = 0.01 ether;

    uint256 public lastDistributionTime;
    uint256 public constant DISTRIBUTION_INTERVAL = 7 days;
    uint256 public pendingStakerYield;

    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public stakeSince;
    mapping(address => uint256) public pendingYield;
    mapping(address => uint256) public totalYieldClaimed;
    uint256 public totalStaked;

    address[] public stakerList;
    mapping(address => bool) public isStaker;

    uint256 public constant TIER2_DAYS = 90;
    uint256 public constant TIER3_DAYS = 180;
    uint256 public constant TIER4_DAYS = 365;
    uint256 public constant TIER5_DAYS = 730;

    event FeesReceived(uint256 amount, string source);
    event BuybackAndBurn(uint256 bnbUsed, uint256 luxfiBurned);
    event YieldDistributed(uint256 totalAmount, uint256 stakerCount);
    event YieldClaimed(address indexed staker, uint256 amount);
    event StakerRegistered(address indexed staker, uint256 amount);
    event StakerUnregistered(address indexed staker);
    event SplitUpdated(uint256 staker, uint256 burn, uint256 treasury, uint256 ai, uint256 loyalty);
    event AIMissionFunded(uint256 amount);
    event LoyaltyPoolFunded(uint256 amount);
    event WhitelistedSenderUpdated(address sender, bool status);

    modifier onlyWhitelisted() {
        require(whitelistedSenders[msg.sender] || msg.sender == owner(), "Not whitelisted sender");
        _;
    }

    constructor(
        address _luxfiToken, address _usdtToken, address _pancakeRouter,
        address _treasuryWallet, address _aiMissionPool, address _loyaltyPool, address _stakingPool
    ) Ownable(msg.sender) {
        require(_luxfiToken != address(0), "Invalid token");
        require(_usdtToken != address(0), "Invalid USDT");
        require(_pancakeRouter != address(0), "Invalid router");
        require(_treasuryWallet != address(0), "Invalid treasury");
        require(_aiMissionPool != address(0), "Invalid AI pool");
        require(_loyaltyPool != address(0), "Invalid loyalty pool");
        require(_stakingPool != address(0), "Invalid staking pool");

        luxfiToken = ILuxfiToken(_luxfiToken);
        usdtToken = IERC20(_usdtToken);
        pancakeRouter = IPancakeRouter(_pancakeRouter);
        treasuryWallet = _treasuryWallet;
        aiMissionPool = _aiMissionPool;
        loyaltyPool = _loyaltyPool;
        stakingPool = _stakingPool;
        lastDistributionTime = block.timestamp;
        whitelistedSenders[msg.sender] = true;
    }

    receive() external payable { _distributeFees(msg.value, "BNB"); }

    function receiveFees(string calldata source) external payable nonReentrant onlyWhitelisted {
        require(msg.value > 0, "No fees sent");
        _distributeFees(msg.value, source);
    }

    function _distributeFees(uint256 amount, string memory source) internal {
        totalFeesReceived += amount;
        emit FeesReceived(amount, source);

        uint256 stakerShare   = (amount * stakerShareBps)    / TOTAL_BPS;
        uint256 burnShare     = (amount * burnShareBps)      / TOTAL_BPS;
        uint256 treasuryShare = (amount * treasuryShareBps)  / TOTAL_BPS;
        uint256 aiShare       = (amount * aiMissionShareBps) / TOTAL_BPS;
        uint256 loyaltyShare  = amount - stakerShare - burnShare - treasuryShare - aiShare;

        pendingStakerYield += stakerShare;
        totalStakerYield   += stakerShare;
        pendingBurnAmount  += burnShare;
        totalTreasuryFees  += treasuryShare;
        totalAIMissionFees += aiShare;
        totalLoyaltyFees   += loyaltyShare;

        if (treasuryShare > 0) {
            (bool s1,) = payable(treasuryWallet).call{value: treasuryShare}("");
            if (!s1) { pendingStakerYield += treasuryShare; totalTreasuryFees -= treasuryShare; }
        }
        if (aiShare > 0) {
            (bool s2,) = payable(aiMissionPool).call{value: aiShare}("");
            if (!s2) { pendingStakerYield += aiShare; totalAIMissionFees -= aiShare; }
            emit AIMissionFunded(aiShare);
        }
        if (loyaltyShare > 0) {
            (bool s3,) = payable(loyaltyPool).call{value: loyaltyShare}("");
            if (!s3) { pendingStakerYield += loyaltyShare; totalLoyaltyFees -= loyaltyShare; }
            emit LoyaltyPoolFunded(loyaltyShare);
        }
        if (pendingBurnAmount >= minBurnThreshold) _executeBuybackAndBurn();
    }

    function _executeBuybackAndBurn() internal {
        uint256 bnbToBurn = pendingBurnAmount;
        pendingBurnAmount = 0;

        uint256 minLuxfiOut = 0;
        try pancakeRouter.getAmountsOut(bnbToBurn, _getBuyPath()) returns (uint[] memory quoted) {
            minLuxfiOut = quoted[quoted.length - 1] * (TOTAL_BPS - minBuybackSlippageBps) / TOTAL_BPS;
        } catch {}

        address[] memory path = new address[](2);
        path[0] = pancakeRouter.WETH();
        path[1] = address(luxfiToken);

        try pancakeRouter.swapExactETHForTokens{value: bnbToBurn}(minLuxfiOut, path, address(this), block.timestamp + 300)
        returns (uint[] memory amounts) {
            uint256 luxfiBought = amounts[amounts.length - 1];
            try luxfiToken.burn(luxfiBought) {
                totalBurned += luxfiBought;
                emit BuybackAndBurn(bnbToBurn, luxfiBought);
            } catch {
                luxfiToken.transfer(address(0xdead), luxfiBought);
                totalBurned += luxfiBought;
                emit BuybackAndBurn(bnbToBurn, luxfiBought);
            }
        } catch { pendingBurnAmount += bnbToBurn; }
    }

    function triggerBuybackAndBurn() external onlyOwner {
        require(pendingBurnAmount > 0, "Nothing to burn");
        _executeBuybackAndBurn();
    }

    function distributeWeeklyYield() external nonReentrant {
        require(block.timestamp >= lastDistributionTime + DISTRIBUTION_INTERVAL, "Too early");
        require(pendingStakerYield > 0, "No yield");
        require(totalStaked > 0, "No stakers");

        uint256 yieldToDistribute = pendingStakerYield;
        pendingStakerYield = 0;
        lastDistributionTime = block.timestamp;

        uint256 totalWeighted = _calculateTotalWeightedStake();
        if (totalWeighted == 0) return;

        for (uint256 i = 0; i < stakerList.length; i++) {
            address staker = stakerList[i];
            if (stakedAmount[staker] == 0) continue;
            uint256 multiplier = getLoyaltyMultiplier(staker);
            uint256 weightedStake = (stakedAmount[staker] * multiplier) / 100;
            uint256 stakerYield = (yieldToDistribute * weightedStake) / totalWeighted;
            if (stakerYield > 0) pendingYield[staker] += stakerYield;
        }

        emit YieldDistributed(yieldToDistribute, stakerList.length);
    }

    function claimYield(address staker, uint256 amount) external nonReentrant {
        require(msg.sender == stakingPool || msg.sender == owner(), "Not authorized");
        require(amount > 0, "Nothing to claim");
        require(pendingYield[staker] >= amount, "Exceeds pending yield");
        require(address(this).balance >= amount, "Insufficient balance");

        pendingYield[staker] -= amount;
        totalYieldClaimed[staker] += amount;

        (bool success,) = payable(staker).call{value: amount}("");
        require(success, "Transfer failed");
        emit YieldClaimed(staker, amount);
    }

    function registerStaker(address staker, uint256 amount) external {
        require(msg.sender == stakingPool || msg.sender == owner(), "Not authorized");
        require(staker != address(0), "Zero address");
        require(amount > 0, "Zero amount");
        if (!isStaker[staker]) {
            stakerList.push(staker);
            isStaker[staker] = true;
            stakeSince[staker] = block.timestamp;
        }
        stakedAmount[staker] += amount;
        totalStaked += amount;
        emit StakerRegistered(staker, amount);
    }

    function unregisterStaker(address staker) external {require(msg.sender == stakingPool, "Only staking contract");
        totalStaked -= stakedAmount[staker];
        stakedAmount[staker] = 0;
        isStaker[staker] = false;
        emit StakerUnregistered(staker);
    }

    function getLoyaltyMultiplier(address staker) public view returns (uint256) {
        uint256 daysHeld = (block.timestamp - stakeSince[staker]) / 1 days;
        if (daysHeld >= TIER5_DAYS) return 250;
        if (daysHeld >= TIER4_DAYS) return 200;
        if (daysHeld >= TIER3_DAYS) return 150;
        if (daysHeld >= TIER2_DAYS) return 125;
        return 100;
    }

    function _calculateTotalWeightedStake() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < stakerList.length; i++) {
            if (stakedAmount[stakerList[i]] == 0) continue;
            total += (stakedAmount[stakerList[i]] * getLoyaltyMultiplier(stakerList[i])) / 100;
        }
        return total;
    }

    function setWhitelistedSender(address sender, bool status) external onlyOwner {
        whitelistedSenders[sender] = status;
        emit WhitelistedSenderUpdated(sender, status);
    }

    function setMinBuybackSlippage(uint256 bps) external onlyOwner {
        require(bps <= 2000, "Max 20% slippage");
        minBuybackSlippageBps = bps;
    }

    function updateSplit(uint256 _s, uint256 _b, uint256 _t, uint256 _a, uint256 _l) external onlyOwner {
        require(_s + _b + _t + _a + _l == TOTAL_BPS, "Must equal 10000");
        require(_b >= 1000, "Min 10% burn");
        require(_s >= 1000, "Min 10% staker yield");
        require(_a >= 500, "Min 5% AI missions");
        stakerShareBps = _s; burnShareBps = _b; treasuryShareBps = _t; aiMissionShareBps = _a; loyaltyShareBps = _l;
        emit SplitUpdated(_s, _b, _t, _a, _l);
    }

    function setMinBurnThreshold(uint256 threshold) external onlyOwner { minBurnThreshold = threshold; }

    function updateAddresses(address _treasury, address _aiPool, address _loyaltyPoolAddr, address _stakingPoolAddr) external onlyOwner {
        if (_treasury != address(0)) treasuryWallet = _treasury;
        if (_aiPool != address(0)) aiMissionPool = _aiPool;
        if (_loyaltyPoolAddr != address(0)) loyaltyPool = _loyaltyPoolAddr;
        if (_stakingPoolAddr != address(0)) stakingPool = _stakingPoolAddr;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getDistributionStats() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (totalFeesReceived, totalBurned, totalStakerYield, totalTreasuryFees, totalAIMissionFees, totalLoyaltyFees, pendingBurnAmount, pendingStakerYield, lastDistributionTime + DISTRIBUTION_INTERVAL);
    }

    function _getBuyPath() internal view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = pancakeRouter.WETH();
        path[1] = address(luxfiToken);
        return path;
    }
}
