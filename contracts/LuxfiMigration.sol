// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LuxfiMigration
 * @dev Fix: recoverTokens() cannot drain collected LUXFI once users have migrated
 */
contract LuxfiMigration is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public luxfiToken;

    bool public migrationEnabled = false;
    address public newVaultAddress;
    address public newTokenAddress;

    mapping(address => bool) public hasMigrated;
    mapping(address => uint256) public migratedAmount;
    uint256 public totalMigrated;

    uint256 public migrationAnnouncedAt;
    uint256 public constant MIGRATION_TIMELOCK = 72 hours;
    bool public migrationAnnounced = false;

    event MigrationAnnounced(address newVault, address newToken, uint256 activatesAt);
    event MigrationEnabled();
    event MigrationCancelled();
    event UserMigrated(address indexed user, uint256 amount);

    constructor(address _luxfiToken) Ownable(msg.sender) {
        require(_luxfiToken != address(0), "Invalid token address");
        luxfiToken = IERC20(_luxfiToken);
    }

    function announceMigration(address _newVaultAddress, address _newTokenAddress) external onlyOwner {
        require(!migrationAnnounced, "Already announced");
        require(_newVaultAddress != address(0), "Invalid vault address");
        require(_newTokenAddress != address(0), "Invalid token address");
        newVaultAddress = _newVaultAddress;
        newTokenAddress = _newTokenAddress;
        migrationAnnouncedAt = block.timestamp;
        migrationAnnounced = true;
        emit MigrationAnnounced(_newVaultAddress, _newTokenAddress, block.timestamp + MIGRATION_TIMELOCK);
    }

    function enableMigration() external onlyOwner {
        require(migrationAnnounced, "Not announced yet");
        require(block.timestamp >= migrationAnnouncedAt + MIGRATION_TIMELOCK, "Timelock not expired");
        migrationEnabled = true;
        emit MigrationEnabled();
    }

    function migrate() external nonReentrant {
        require(migrationEnabled, "Migration not enabled");
        require(!hasMigrated[msg.sender], "Already migrated");
        uint256 balance = luxfiToken.balanceOf(msg.sender);
        require(balance > 0, "No tokens to migrate");

        hasMigrated[msg.sender] = true;
        migratedAmount[msg.sender] = balance;
        totalMigrated += balance;

        luxfiToken.safeTransferFrom(msg.sender, address(this), balance);
        IERC20(newTokenAddress).safeTransfer(msg.sender, balance);
        emit UserMigrated(msg.sender, balance);
    }

    function cancelMigration() external onlyOwner {
        migrationEnabled = false;
        migrationAnnounced = false;
        newVaultAddress = address(0);
        newTokenAddress = address(0);
        emit MigrationCancelled();
    }

    // FIX: Cannot drain collected LUXFI tokens once users have migrated
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(!migrationEnabled, "Cannot recover during active migration");
        require(token != address(luxfiToken) || totalMigrated == 0, "Cannot drain collected migration tokens");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function getMigrationStatus() external view returns (bool, bool, uint256, uint256, address, address) {
        return (migrationAnnounced, migrationEnabled, migrationAnnounced ? migrationAnnouncedAt + MIGRATION_TIMELOCK : 0, totalMigrated, newVaultAddress, newTokenAddress);
    }

    function canMigrate(address user) external view returns (bool) {
        return migrationEnabled && !hasMigrated[user] && luxfiToken.balanceOf(user) > 0;
    }
}
