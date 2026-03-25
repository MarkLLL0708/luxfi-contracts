// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IVaultHook {
    function onTokenReceived(address from, uint256 amount) external;
}

contract MaliciousERC20 is ERC20 {
    address public hookTarget;

    constructor() ERC20("MAL", "MAL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHookTarget(address target) external {
        hookTarget = target;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && to == hookTarget && from != address(0)) {
            IVaultHook(hookTarget).onTokenReceived(from, value);
        }
    }
}
```

Commit message:
```
fix: remove markdown artifacts from MaliciousERC20.sol
