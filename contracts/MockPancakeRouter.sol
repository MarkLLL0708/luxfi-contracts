// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPancakeRouter {
    function WETH() external pure returns (address) {
        return address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
    }

    function getAmountsOut(uint amountIn, address[] calldata) external pure returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    function swapExactTokensForETH(uint amountIn, uint, address[] calldata, address to, uint) external returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
        (bool ok,) = payable(to).call{value: amountIn}("");
        require(ok, "MockRouter: BNB send failed");
    }

    receive() external payable {}
}
