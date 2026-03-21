// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IPancakeRouter {
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}

interface IFeeDistributor {
    function receiveFees(string calldata source) external payable;
}

/**
 * @title LuxfiToken
 * @notice LUXFI Web 4.0 Token
 * @dev Fixes: Chainlink staleness, real transfer fee, slippage, authorized burners
 */
contract LuxfiToken is ERC20, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    AggregatorV3Interface public priceFeed;
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    IPancakeRouter public pancakeRouter;
    IFeeDistributor public feeDistributor;

    address public constant USDT    = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDC    = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address public constant ETH_BSC = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address public constant CAKE    = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    struct PaymentToken {
        bool accepted;
        uint256 conversionFeeBps;
        string symbol;
    }
    mapping(address => PaymentToken) public paymentTokens;

    uint256 public constant MAX_SUPPLY          = 1_000_000_000 * 1e18;
    uint256 public constant MAX_PURCHASE        = 1_000_000 * 1e18;
    uint256 public constant MAX_WALLET_PERCENT  = 200;
    uint256 public constant PERCENT_DENOMINATOR = 10000;

    uint256 public purchaseFeeBps  = 100;
    uint256 public sellFeeBps      = 200;
    uint256 public transferFeeBps  = 10;
    uint256 public constant MAX_FEE_BPS = 500;

    uint256 public maxSlippageBps = 200;
    uint256 public constant MAX_ALLOWED_SLIPPAGE_BPS = 500;

    uint256 public totalFeesCollected;
    uint256 public totalTokensBurned;
    uint256 public tradingFeeBps = 100;

    uint256 public purchaseCooldown = 60;
    mapping(address => uint256) public lastPurchaseTime;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public authorizedBurners;

    bool public transfersEnabled = false;

    uint256 public constant VOTE_HOLDING_PERIOD = 7 days;
    mapping(address => uint256) public lastTransferTime;

    mapping(address => uint256) public yieldEarned;
    mapping(address => uint256) public yieldClaimed;
    uint256 public totalYieldEscrowed;

    mapping(address => address) public referredBy;
    mapping(address => uint256) public referralEarnings;
    mapping(address => uint256) public referralCount;
    uint256 public referralFeeBps = 50;

    event TokensPurchased(address indexed buyer, uint256 luxfiAmount, uint256 fee, address paymentToken, address referrer);
    event TokensSold(address indexed seller, uint256 luxfiAmount, uint256 fee);
    event TransfersEnabled(bool enabled);
    event Blacklisted(address indexed account, bool status);
    event YieldDistributed(address indexed recipient, uint256 amount);
    event YieldClaimed(address indexed recipient, uint256 amount);
    event FeeUpdated(string feeType, uint256 newFeeBps);
    event PaymentTokenUpdated(address token, bool accepted, uint256 feeBps);
    event ReferralEarned(address indexed referrer, address indexed buyer, uint256 amount);
    event TokensBurned(uint256 amount);
    event FeeDistributorUpdated(address newDistributor);
    event SlippageUpdated(uint256 newSlippageBps);
    event BurnerUpdated(address burner, bool status);

    constructor(
        address _priceFeed,
        address _pancakeRouter,
        address _feeDistributor
    ) ERC20("LUXFI Token", "LUXFI") Ownable(msg.sender) {
        require(_priceFeed != address(0), "Invalid price feed");
        require(_pancakeRouter != address(0), "Invalid router");

        priceFeed = AggregatorV3Interface(_priceFeed);
        pancakeRouter = IPancakeRouter(_pancakeRouter);

        if (_feeDistributor != address(0)) {
            feeDistributor = IFeeDistributor(_feeDistributor);
            authorizedBurners[_feeDistributor] = true;
        }

        paymentTokens[USDT]    = PaymentToken(true, 50,  "USDT");
        paymentTokens[USDC]    = PaymentToken(true, 50,  "USDC");
        paymentTokens[ETH_BSC] = PaymentToken(true, 100, "ETH");
        paymentTokens[CAKE]    = PaymentToken(true, 50,  "CAKE");

        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[address(this)] = true;
    }

    function purchaseWithBNB(address referrer) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Send BNB to purchase");
        _processBNBPurchase(msg.sender, msg.value, purchaseFeeBps, address(0), referrer);
    }

    function purchaseWithToken(
        address token,
        uint256 tokenAmount,
        address referrer
    ) external nonReentrant whenNotPaused {
        require(paymentTokens[token].accepted, "Token not accepted");
        require(tokenAmount > 0, "Zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).approve(address(pancakeRouter), tokenAmount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = pancakeRouter.WETH();

        uint[] memory expectedAmounts = pancakeRouter.getAmountsOut(tokenAmount, path);
        uint256 expectedBNB = expectedAmounts[expectedAmounts.length - 1];
        uint256 minBNBOut = expectedBNB * (PERCENT_DENOMINATOR - maxSlippageBps) / PERCENT_DENOMINATOR;
        require(minBNBOut > 0, "Expected output too small");

        uint[] memory amounts = pancakeRouter.swapExactTokensForETH(
            tokenAmount, minBNBOut, path, address(this), block.timestamp + 300
        );

        uint256 bnbReceived = amounts[amounts.length - 1];
        uint256 totalFeeBps = purchaseFeeBps + paymentTokens[token].conversionFeeBps;
        _processBNBPurchase(msg.sender, bnbReceived, totalFeeBps, token, referrer);
    }

    function _processBNBPurchase(
        address buyer,
        uint256 bnbAmount,
        uint256 feeBps,
        address paymentToken,
        address referrer
    ) internal {
        require(!blacklisted[buyer], "Blacklisted");
        require(block.timestamp >= lastPurchaseTime[buyer] + purchaseCooldown, "Cooldown active");

        uint256 fee = (bnbAmount * feeBps) / PERCENT_DENOMINATOR;
        uint256 referralBonus = 0;

        if (referrer != address(0) && referrer != buyer && referredBy[buyer] == address(0)) {
            referredBy[buyer] = referrer;
            referralBonus = (bnbAmount * referralFeeBps) / PERCENT_DENOMINATOR;
            referralEarnings[referrer] += referralBonus;
            referralCount[referrer]++;
            if (referralBonus > 0) {
                (bool refSuccess,) = payable(referrer).call{value: referralBonus}("");
                if (refSuccess) emit ReferralEarned(referrer, buyer, referralBonus);
            }
        }

        uint256 bnbAfterFee = bnbAmount - fee;
        uint256 protocolFee = fee - referralBonus;

        (, int256 price, , uint256 updatedAt,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price feed");
        require(block.timestamp - updatedAt <= MAX_PRICE_AGE, "Stale price feed");

        uint256 bnbPriceUSD = uint256(price) * 1e10;
        uint256 tokenAmount = (bnbAfterFee * bnbPriceUSD) / 1e18;
        require(tokenAmount > 0, "Amount too small");
        require(tokenAmount <= MAX_PURCHASE, "Exceeds max purchase");
        require(balanceOf(buyer) + tokenAmount <= (MAX_SUPPLY * MAX_WALLET_PERCENT) / PERCENT_DENOMINATOR, "Exceeds max wallet");
        require(totalSupply() + tokenAmount <= MAX_SUPPLY, "Exceeds max supply");

        if (protocolFee > 0 && address(feeDistributor) != address(0)) {
            feeDistributor.receiveFees{value: protocolFee}("TOKEN_PURCHASE");
            totalFeesCollected += protocolFee;
        }

        lastPurchaseTime[buyer] = block.timestamp;
        lastTransferTime[buyer] = block.timestamp;
        _mint(buyer, tokenAmount);

        emit TokensPurchased(buyer, tokenAmount, fee, paymentToken, referrer);
    }

    function burn(uint256 amount) external {
        require(authorizedBurners[msg.sender] || msg.sender == owner(), "Not authorized to burn");
        _burn(msg.sender, amount);
        totalTokensBurned += amount;
        emit TokensBurned(amount);
    }

    function selfBurn(uint256 amount) external {
        require(amount > 0, "Zero amount");
        _burn(msg.sender, amount);
        totalTokensBurned += amount;
        emit TokensBurned(amount);
    }

    function distributeYield(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        require(recipients.length == amounts.length, "Array mismatch");
        uint256 total = 0;
        for (uint256 i; i < amounts.length; i++) total += amounts[i];
        require(address(this).balance >= totalYieldEscrowed + total, "Insufficient BNB");
        totalYieldEscrowed += total;
        for (uint256 i; i < recipients.length; i++) {
            yieldEarned[recipients[i]] += amounts[i];
            emit YieldDistributed(recipients[i], amounts[i]);
        }
    }

    function claimYield() external nonReentrant {
        uint256 amount = yieldEarned[msg.sender] - yieldClaimed[msg.sender];
        require(amount > 0, "No yield to claim");
        require(address(this).balance >= amount, "Insufficient balance");
        yieldClaimed[msg.sender] += amount;
        totalYieldEscrowed -= amount;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        emit YieldClaimed(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(transfersEnabled, "Transfers disabled");
            require(!blacklisted[from] && !blacklisted[to], "Blacklisted");
            if (!isExcludedFromFee[from] && !isExcludedFromFee[to] && transferFeeBps > 0) {
                uint256 fee = (value * transferFeeBps) / PERCENT_DENOMINATOR;
                if (fee > 0) {
                    totalFeesCollected += fee;
                    super._update(from, address(this), fee);
                    value -= fee;
                }
            }
            lastTransferTime[from] = block.timestamp;
            lastTransferTime[to] = block.timestamp;
        }
        super._update(from, to, value);
    }

    function isEligibleToVote(address account) external view returns (bool) {
        return block.timestamp - lastTransferTime[account] >= VOTE_HOLDING_PERIOD;
    }

    function recordTokenAcquisition(address account) external {
        require(msg.sender == owner() || isExcludedFromFee[msg.sender], "Not authorized");
        if (lastTransferTime[account] == 0) lastTransferTime[account] = block.timestamp;
    }

    function setAuthorizedBurner(address burner, bool status) external onlyOwner {
        authorizedBurners[burner] = status;
        emit BurnerUpdated(burner, status);
    }

    function setPurchaseFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Fee too high");
        purchaseFeeBps = feeBps;
        emit FeeUpdated("PURCHASE", feeBps);
    }

    function setSellFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Fee too high");
        sellFeeBps = feeBps;
        emit FeeUpdated("SELL", feeBps);
    }

    function setTransferFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= 100, "Max 1% transfer fee");
        transferFeeBps = feeBps;
        emit FeeUpdated("TRANSFER", feeBps);
    }

    function setReferralFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= 200, "Max 2% referral fee");
        referralFeeBps = feeBps;
    }

    function setMaxSlippage(uint256 slippageBps) external onlyOwner {
        require(slippageBps <= MAX_ALLOWED_SLIPPAGE_BPS, "Max 5% slippage");
        require(slippageBps >= 10, "Min 0.1% slippage");
        maxSlippageBps = slippageBps;
        emit SlippageUpdated(slippageBps);
    }

    function setPaymentToken(address token, bool accepted, uint256 conversionFeeBps, string calldata symbol) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(conversionFeeBps <= 200, "Max 2% conversion fee");
        paymentTokens[token] = PaymentToken(accepted, conversionFeeBps, symbol);
        emit PaymentTokenUpdated(token, accepted, conversionFeeBps);
    }

    function setFeeDistributor(address distributor) external onlyOwner {
        require(distributor != address(0), "Invalid distributor");
        if (address(feeDistributor) != address(0)) authorizedBurners[address(feeDistributor)] = false;
        feeDistributor = IFeeDistributor(distributor);
        isExcludedFromFee[distributor] = true;
        authorizedBurners[distributor] = true;
        emit FeeDistributorUpdated(distributor);
    }

    function setTransfersEnabled(bool enabled) external onlyOwner { transfersEnabled = enabled; emit TransfersEnabled(enabled); }
    function setBlacklisted(address account, bool status) external onlyOwner { blacklisted[account] = status; emit Blacklisted(account, status); }
    function setExcludedFromFee(address account, bool excluded) external onlyOwner { isExcludedFromFee[account] = excluded; }
    function setPurchaseCooldown(uint256 cooldown) external onlyOwner { require(cooldown <= 1 hours, "Too long"); purchaseCooldown = cooldown; }
    function setPriceFeed(address feed) external onlyOwner { require(feed != address(0), "Invalid feed"); priceFeed = AggregatorV3Interface(feed); }

    function withdraw() external onlyOwner {
        uint256 available = address(this).balance - totalYieldEscrowed;
        require(available > 0, "Nothing to withdraw");
        (bool success,) = payable(owner()).call{value: available}("");
        require(success, "Failed");
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getBNBPrice() external view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }

    function getAcceptedTokens() external pure returns (address[] memory) {
        address[] memory tokens = new address[](4);
        tokens[0] = USDT; tokens[1] = USDC; tokens[2] = ETH_BSC; tokens[3] = CAKE;
        return tokens;
    }

    function estimatePurchase(uint256 bnbAmount) external view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        if (price <= 0) return 0;
        uint256 bnbPriceUSD = uint256(price) * 1e10;
        uint256 fee = (bnbAmount * purchaseFeeBps) / PERCENT_DENOMINATOR;
        return ((bnbAmount - fee) * bnbPriceUSD) / 1e18;
    }

    function getReferralStats(address referrer) external view returns (uint256 count, uint256 earnings) {
        return (referralCount[referrer], referralEarnings[referrer]);
    }

    function getTokenStats() external view returns (uint256, uint256, uint256, uint256, bool) {
        return (totalSupply(), MAX_SUPPLY, totalTokensBurned, totalFeesCollected, transfersEnabled);
    }

    receive() external payable {}
}
