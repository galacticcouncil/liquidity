// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

/// @notice An AggregatorV3 feed whose decimals and answer are set by the test.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice A price source that can be made to stop answering, which is the state the
/// hook could not previously recover from.
contract ToggleRevertSource is IPriceSource {
    uint256 public price;
    uint256 public updatedAt;
    bool public dead;

    constructor(uint256 _price) {
        price = _price;
        updatedAt = block.timestamp;
    }

    function set(uint256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }

    function kill() external {
        dead = true;
    }

    function priceX18() external view returns (uint256, uint256) {
        if (dead) revert("source dead");
        return (price, updatedAt);
    }
}
