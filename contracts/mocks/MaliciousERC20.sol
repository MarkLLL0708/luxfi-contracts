// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IVaultHook {
    function onTokenReceived(address from, uint256 amount) external;
}

contract MaliciousERC20 is ERC20 {
    address public hookTarget;

    constructor() ERC20("MAL", "MAL") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function setHookTarget(address target) external { hookTarget = target; }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && to == hookTarget && from != address(0)) {
            IVaultHook(hookTarget).onTokenReceived(from, value);
        }
    }
}
```

---

## 7. `test/AttackVectors.test.js`

Ask Claude Code to show you this file:
```
Show me the complete contents of test/AttackVectors.test.js
```
It's 594 lines — too large to include here but Claude Code has it ready.

---

## 8. `ATTACK_TEST_REPORT.md`

Ask Claude Code:
```
Show me the complete contents of ATTACK_TEST_REPORT.md
