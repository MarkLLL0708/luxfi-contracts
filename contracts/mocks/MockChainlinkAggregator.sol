// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockChainlinkAggregator {
    int256  private _price;
    uint256 private _updatedAt;

    constructor(int256 price_, uint256 updatedAt_) {
        _price     = price_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        return (1, _price, block.timestamp, _updatedAt, 1);
    }

    function decimals() external pure returns (uint8) { return 8; }
}
