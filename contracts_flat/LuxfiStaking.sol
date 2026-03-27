// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IFeeDistributor {
    function registerStaker(address staker, uint256 amount) external;
    function unregisterStaker(address staker) external;
}

contract LuxfiStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable luxfiToken;
    IFeeDistributor public feeDistributor;

    mapping(address => uint256) public staked;
    uint256 public totalStaked;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);

    constructor(address _token, address _feeDistributor) Ownable(msg.sender) {
        require(_token != address(0), "Invalid token");
        require(_feeDistributor != address(0), "Invalid distributor");
        luxfiToken = IERC20(_token);
        feeDistributor = IFeeDistributor(_feeDistributor);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");
        luxfiToken.safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
        feeDistributor.registerStaker(msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");
        require(staked[msg.sender] >= amount, "Insufficient stake");
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        if (staked[msg.sender] == 0) {
            feeDistributor.unregisterStaker(msg.sender);
        } else {
            feeDistributor.registerStaker(msg.sender, staked[msg.sender]);
        }
        luxfiToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function setFeeDistributor(address newFeeDistributor) external onlyOwner {
        require(newFeeDistributor != address(0), "Invalid address");
        feeDistributor = IFeeDistributor(newFeeDistributor);
    }
}
