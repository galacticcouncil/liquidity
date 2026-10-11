// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Testnet stand-ins for what Robinhood testnet lacks: a mintable token for HDX and HOLLAR, and a
// price feed whose price the deployer pushes, standing in for Chainlink ETH/USD and HDX/USD.

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice A plain ERC20 with the real token's decimals; only the deployer mints.
contract TestToken is ERC20 {
    address public immutable minter;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol, decimals_) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        _mint(to, amount);
    }
}

/// @notice An AggregatorV3-shaped feed. The deployer plays the oracle: each push sets the answer
/// and stamps it with the current block time, as a real feed's update would.
contract TestFeed {
    address public immutable pusher;
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public round;

    constructor(uint8 decimals_, int256 answer_) {
        pusher = msg.sender;
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
        round = 1;
    }

    function push(int256 answer_) external {
        require(msg.sender == pusher, "not pusher");
        answer = answer_;
        updatedAt = block.timestamp;
        round++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, round);
    }
}
