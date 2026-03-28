cat > /tmp/RBOToken.sol << 'ENDOFFILE'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RBOToken — Real Brand Ownership
 * @notice Fractional ownership shares in real Southeast Asian brands
 * @dev Dynamic pricing via ARIA oracle. Tiered exit system.
 *      Yield paid in LUXFI tokens at USD equivalent.
 */
contract RBOToken is ERC20, AccessControl, ReentrancyGuard {

    bytes32 public constant ARIA_ROLE      = keccak256("ARIA_ROLE");
    bytes32 public constant TREASURY_ROLE  = keccak256("TREASURY_ROLE");

    // ─── BRAND CONFIG ─────────────────────────────────────────────
    struct Brand {
        string  name;
        string  city;
        string  tier;               // T1, T2, T3, T4
        uint256 sharePrice;         // USD × 1e18 (18 decimals)
        uint256 initialSharePrice;  // Price at launch — for floor calc
        uint256 floorPrice;         // 80% of purchase price per investor
        uint256 lastPriceUpdate;    // Timestamp of last ARIA update
        uint256 monthlyRevenue;     // USD × 1e18 verified by ARIA
        uint256 totalShares;        // Total shares outstanding
        uint256 floorReserve;       // USD in floor protection reserve
        uint256 ariaScore;          // 0-100 intelligence quality score
        bool    active;
    }

    // ─── INVESTOR POSITION ────────────────────────────────────────
    struct Position {
        uint256 sharesHeld;
        uint256 purchasePrice;      // Price paid per share (USD × 1e18)
        uint256 totalInvestedUSD;   // Total USD value at purchase
        uint256 purchaseTimestamp;
        uint256 loyaltyMultiplier;  // Basis points. 10000 = 1.00x
        uint256 pendingExit;        // Amount pending for 7/30 day exit
        uint256 exitTier;           // 1=instant 2=7day 3=30day
        uint256 exitRequestTime;    // When exit was requested
        bool    compounding;        // True = no exit, earn loyalty bonus
    }

    // ─── EXIT SYSTEM ──────────────────────────────────────────────
    uint256 public constant INSTANT_EXIT_FEE    = 500;   // 5.00% in bps
    uint256 public constant SEVEN_DAY_FEE       = 100;   // 1.00% in bps
    uint256 public constant THIRTY_DAY_FEE      = 0;     // 0.00%
    uint256 public constant THIRTY_DAY_BONUS    = 50;    // 0.50% bonus
    uint256 public constant LOYALTY_MONTHLY     = 100;   // 1.00%/month
    uint256 public constant SECONDARY_FEE       = 100;   // 1.00% each side
    uint256 public constant FLOOR_PCT           = 8000;  // 80% floor
    uint256 public constant MAX_MONTHLY_CHANGE  = 1500;  // ±15% cap
    uint256 public constant PRICE_UPDATE_INTERVAL = 30 days;
    uint256 public constant FLOOR_RESERVE_PCT   = 3000;  // 30% of mgmt fee
    uint256 public constant MGMT_FEE_PCT        = 2000;  // 20% of pool

    // ─── SECONDARY MARKET ─────────────────────────────────────────
    struct Listing {
        address seller;
        bytes32 brandId;
        uint256 shares;
        uint256 pricePerShare;      // USD × 1e18
        uint256 listedAt;
        bool    active;
    }

    // ─── STATE ────────────────────────────────────────────────────
    mapping(bytes32 => Brand)                       public brands;
    mapping(bytes32 => mapping(address => Position)) public positions;
    mapping(uint256 => Listing)                     public listings;
    mapping(bytes32 => address[])                   public brandInvestors;
    mapping(bytes32 => uint256)                     public brandYieldPool;

    address public luxfiToken;      // LUXFI ERC20 token address
    address public treasury;        // LUXFI treasury
    uint256 public listingCount;
    uint256 public totalFloorReserve;

    // ─── EVENTS ───────────────────────────────────────────────────
    event SharesPurchased(address indexed investor, bytes32 indexed brandId, uint256 shares, uint256 priceUSD);
    event ExitRequested(address indexed investor, bytes32 indexed brandId, uint256 tier, uint256 shares);
    event ExitProcessed(address indexed investor, bytes32 indexed brandId, uint256 amountUSD, uint256 fee);
    event YieldDistributed(bytes32 indexed brandId, uint256 totalUSD, uint256 perShare, uint256 intelBudget);
    event PriceUpdated(bytes32 indexed brandId, uint256 oldPrice, uint256 newPrice, uint256 ariaScore);
    event SecondaryListed(uint256 listingId, address seller, bytes32 brandId, uint256 shares, uint256 price);
    event SecondaryTraded(uint256 listingId, address buyer, address seller, uint256 shares, uint256 price);
    event FloorReserveAdded(bytes32 indexed brandId, uint256 amount);

    constructor(address _luxfiToken, address _treasury) ERC20("LUXFI RBO", "RBO") {
        luxfiToken  = _luxfiToken;
        treasury    = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);
    }

    // ─── BRAND MANAGEMENT ─────────────────────────────────────────

    function addBrand(
        bytes32 brandId,
        string memory name,
        string memory city,
        string memory tier,
        uint256 initialPriceUSD,    // e.g. 10e18 = $10/share
        uint256 totalShares
    ) external onlyRole(TREASURY_ROLE) {
        require(!brands[brandId].active, "Brand already exists");
        brands[brandId] = Brand({
            name:             name,
            city:             city,
            tier:             tier,
            sharePrice:       initialPriceUSD,
            initialSharePrice:initialPriceUSD,
            floorPrice:       initialPriceUSD * FLOOR_PCT / 10000,
            lastPriceUpdate:  block.timestamp,
            monthlyRevenue:   0,
            totalShares:      totalShares,
            floorReserve:     0,
            ariaScore:        75,
            active:           true
        });
    }

    // ─── ARIA PRICE ORACLE ────────────────────────────────────────

    /**
     * @notice ARIA submits monthly price update
     * @dev Enforces ±15% monthly cap. Rejects invalid submissions.
     *      Only callable after PRICE_UPDATE_INTERVAL has passed.
     */
    function updatePrice(
        bytes32 brandId,
        uint256 newPriceUSD,
        uint256 monthlyRevenueUSD,
        uint256 ariaScore
    ) external onlyRole(ARIA_ROLE) {
        Brand storage b = brands[brandId];
        require(b.active, "Brand not active");
        require(
            block.timestamp >= b.lastPriceUpdate + PRICE_UPDATE_INTERVAL,
            "Too early — 30 day interval not reached"
        );

        uint256 oldPrice = b.sharePrice;

        // Enforce ±15% monthly cap
        uint256 maxPrice = oldPrice * (10000 + MAX_MONTHLY_CHANGE) / 10000;
        uint256 minPrice = oldPrice * (10000 - MAX_MONTHLY_CHANGE) / 10000;

        if (newPriceUSD > maxPrice) newPriceUSD = maxPrice;
        if (newPriceUSD < minPrice) newPriceUSD = minPrice;

        b.sharePrice      = newPriceUSD;
        b.monthlyRevenue  = monthlyRevenueUSD;
        b.lastPriceUpdate = block.timestamp;
        b.ariaScore       = ariaScore;

        emit PriceUpdated(brandId, oldPrice, newPriceUSD, ariaScore);
    }

    // ─── PURCHASE RBO SHARES ──────────────────────────────────────

    function purchaseShares(
        bytes32 brandId,
        uint256 numberOfShares
    ) external nonReentrant {
        Brand storage b = brands[brandId];
        require(b.active, "Brand not active");
        require(numberOfShares > 0, "Must buy at least 1 share");

        uint256 totalCostUSD = b.sharePrice * numberOfShares / 1e18;

        // Record position
        Position storage pos = positions[brandId][msg.sender];
        if (pos.sharesHeld == 0) {
            brandInvestors[brandId].push(msg.sender);
            pos.loyaltyMultiplier = 10000; // 1.00x base
            pos.compounding = true;
        }

        // Weighted average purchase price for floor protection
        uint256 existingValue = pos.sharesHeld * pos.purchasePrice / 1e18;
        uint256 newValue      = numberOfShares * b.sharePrice / 1e18;
        pos.sharesHeld       += numberOfShares;
        pos.totalInvestedUSD += totalCostUSD;
        pos.purchasePrice     = (existingValue + newValue) * 1e18 / pos.sharesHeld;
        pos.purchaseTimestamp = block.timestamp;

        // Floor price = 80% of weighted average purchase price
        uint256 investorFloor = pos.purchasePrice * FLOOR_PCT / 10000;
        if (investorFloor < b.floorPrice) {
            b.floorPrice = investorFloor;
        }

        emit SharesPurchased(msg.sender, brandId, numberOfShares, totalCostUSD);
    }

    // ─── TIERED EXIT SYSTEM ───────────────────────────────────────

    /**
     * @notice Request exit from RBO position
     * @param tier 1=instant(5% fee) 2=7days(1% fee) 3=30days(0%+0.5% bonus)
     */
    function requestExit(
        bytes32 brandId,
        uint256 shares,
        uint256 tier
    ) external nonReentrant {
        require(tier >= 1 && tier <= 3, "Invalid tier: use 1, 2, or 3");
        Position storage pos = positions[brandId][msg.sender];
        require(pos.sharesHeld >= shares, "Insufficient shares");
        require(pos.pendingExit == 0, "Exit already pending");

        Brand storage b = brands[brandId];
        uint256 grossValueUSD = shares * b.sharePrice / 1e18;

        // Apply floor protection
        uint256 floorValue = shares * pos.purchasePrice * FLOOR_PCT / 10000 / 1e18;
        if (grossValueUSD < floorValue && b.floorReserve >= floorValue - grossValueUSD) {
            b.floorReserve -= (floorValue - grossValueUSD);
            grossValueUSD   = floorValue;
        }

        // Calculate fee
        uint256 feeBps = tier == 1 ? INSTANT_EXIT_FEE
                       : tier == 2 ? SEVEN_DAY_FEE
                       : 0;

        uint256 feeUSD = grossValueUSD * feeBps / 10000;

        // Fee split: 60% to remaining holders, 40% to LUXFI treasury
        uint256 holderShare  = feeUSD * 6000 / 10000;
        uint256 treasuryShare = feeUSD - holderShare;

        // Add holder share to yield pool
        brandYieldPool[brandId] += holderShare;

        // Deduct shares
        pos.sharesHeld   -= shares;
        pos.pendingExit   = grossValueUSD - feeUSD;
        pos.exitTier      = tier;
        pos.exitRequestTime = block.timestamp;
        pos.compounding   = false;

        // Instant exit: process immediately
        if (tier == 1) {
            _processExit(brandId, msg.sender, treasuryShare);
        }

        emit ExitRequested(msg.sender, brandId, tier, shares);
    }

    /**
     * @notice Process pending 7-day or 30-day exit after waiting period
     */
    function processExit(bytes32 brandId, address investor) external nonReentrant {
        Position storage pos = positions[brandId][investor];
        require(pos.pendingExit > 0, "No pending exit");

        uint256 waitRequired = pos.exitTier == 2 ? 7 days : 30 days;
        require(
            block.timestamp >= pos.exitRequestTime + waitRequired,
            "Waiting period not complete"
        );

        // 30-day bonus
        if (pos.exitTier == 3) {
            uint256 bonus = pos.pendingExit * THIRTY_DAY_BONUS / 10000;
            pos.pendingExit += bonus;
        }

        _processExit(brandId, investor, 0);
    }

    function _processExit(bytes32 brandId, address investor, uint256 treasuryFeeUSD) internal {
        Position storage pos = positions[brandId][investor];
        uint256 payout = pos.pendingExit;
        pos.pendingExit = 0;

        // In production: convert USD to LUXFI tokens at current price
        // and transfer to investor wallet
        // For now: emit event for backend to handle transfer

        emit ExitProcessed(investor, brandId, payout, treasuryFeeUSD);
    }

    // ─── YIELD DISTRIBUTION ───────────────────────────────────────

    /**
     * @notice ARIA distributes monthly yield to all RBO holders
     * @dev Intel budget is deducted before distribution — invisible to investors
     */
    function distributeYield(
        bytes32 brandId,
        uint256 grossPoolUSD,       // Total pool before LUXFI fees
        uint256 mgmtFeeUSD,         // 20% management fee to LUXFI
        uint256 intelBudgetUSD,     // ARIA intelligence budget (invisible)
        uint256 floorReserveAddUSD  // Amount added to floor reserve
    ) external onlyRole(ARIA_ROLE) {
        Brand storage b = brands[brandId];
        require(b.active, "Brand not active");

        // Add to floor reserve first
        b.floorReserve += floorReserveAddUSD;
        totalFloorReserve += floorReserveAddUSD;
        emit FloorReserveAdded(brandId, floorReserveAddUSD);

        // Net pool after all deductions (this is what investors see)
        uint256 netPool = grossPoolUSD - mgmtFeeUSD - intelBudgetUSD - floorReserveAddUSD;
        netPool += brandYieldPool[brandId]; // Add exit fees collected
        brandYieldPool[brandId] = 0;

        // Per share yield
        uint256 perShareUSD = netPool * 1e18 / b.totalShares;

        // Distribute to all investors with loyalty multipliers
        address[] memory investors = brandInvestors[brandId];
        for (uint256 i = 0; i < investors.length; i++) {
            Position storage pos = positions[brandId][investors[i]];
            if (pos.sharesHeld == 0 || pos.pendingExit > 0) continue;

            uint256 investorYield = pos.sharesHeld * perShareUSD / 1e18;

            // Apply loyalty multiplier for compounding holders
            if (pos.compounding) {
                investorYield = investorYield * pos.loyaltyMultiplier / 10000;
                // Increase loyalty multiplier for next month
                pos.loyaltyMultiplier += LOYALTY_MONTHLY; // +1% per month
                if (pos.loyaltyMultiplier > 15000) pos.loyaltyMultiplier = 15000; // Max 1.5x
            }

            // In production: mint LUXFI tokens at current price and transfer
            // Backend handles the token minting and transfer
        }

        emit YieldDistributed(brandId, netPool, perShareUSD, intelBudgetUSD);
    }

    // ─── SECONDARY MARKET ─────────────────────────────────────────

    function listOnSecondary(
        bytes32 brandId,
        uint256 shares,
        uint256 pricePerShareUSD
    ) external nonReentrant {
        Position storage pos = positions[brandId][msg.sender];
        require(pos.sharesHeld >= shares, "Insufficient shares");
        require(pos.pendingExit == 0, "Cannot list during pending exit");

        Brand storage b = brands[brandId];
        // Price must be within 10% of current ARIA price
        uint256 maxPrice = b.sharePrice * 11000 / 10000;
        uint256 minPrice = b.sharePrice * 9000 / 10000;
        require(pricePerShareUSD >= minPrice && pricePerShareUSD <= maxPrice,
                "Price must be within 10% of ARIA price");

        pos.sharesHeld -= shares;

        listings[listingCount] = Listing({
            seller:       msg.sender,
            brandId:      brandId,
            shares:       shares,
            pricePerShare:pricePerShareUSD,
            listedAt:     block.timestamp,
            active:       true
        });

        emit SecondaryListed(listingCount, msg.sender, brandId, shares, pricePerShareUSD);
        listingCount++;
    }

    function buyFromSecondary(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "Listing not active");
        require(l.seller != msg.sender, "Cannot buy own listing");

        uint256 totalUSD    = l.shares * l.pricePerShare / 1e18;
        uint256 sellerFee   = totalUSD * SECONDARY_FEE / 10000;
        uint256 buyerFee    = totalUSD * SECONDARY_FEE / 10000;
        uint256 sellerGets  = totalUSD - sellerFee;

        l.active = false;

        // Transfer shares to buyer
        Position storage buyerPos = positions[l.brandId][msg.sender];
        buyerPos.sharesHeld      += l.shares;
        buyerPos.purchasePrice    = l.pricePerShare;
        buyerPos.totalInvestedUSD += totalUSD;
        if (buyerPos.loyaltyMultiplier == 0) {
            buyerPos.loyaltyMultiplier = 10000;
            buyerPos.compounding = true;
            brandInvestors[l.brandId].push(msg.sender);
        }

        // LUXFI treasury receives both fees
        // Backend processes payment and fee collection

        emit SecondaryTraded(listingId, msg.sender, l.seller, l.shares, l.pricePerShare);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────

    function getBrandInfo(bytes32 brandId) external view returns (Brand memory) {
        return brands[brandId];
    }

    function getPosition(bytes32 brandId, address investor) external view returns (Position memory) {
        return positions[brandId][investor];
    }

    function getInvestorYield(bytes32 brandId, address investor, uint256 perShareUSD)
        external view returns (uint256) {
        Position memory pos = positions[brandId][investor];
        uint256 base = pos.sharesHeld * perShareUSD / 1e18;
        if (pos.compounding) {
            return base * pos.loyaltyMultiplier / 10000;
        }
        return base;
    }

    function canUpdatePrice(bytes32 brandId) external view returns (bool, uint256) {
        Brand memory b = brands[brandId];
        uint256 nextUpdate = b.lastPriceUpdate + PRICE_UPDATE_INTERVAL;
        return (block.timestamp >= nextUpdate, nextUpdate);
    }
}
ENDOFFILE
