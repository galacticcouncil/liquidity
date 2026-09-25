// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {TokenDecimals} from "./TokenDecimals.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Single Chainlink feed priced in a USD-stable quote token (e.g. ETH/HOLLAR
/// via the ETH/USD feed, treating HOLLAR as $1). Built from the two pool tokens: the one
/// the feed prices and the other. Decimals come from the tokens, and `invert` is worked out
/// from their addresses: it flips the feed when the token it prices is the pool's token1.
contract ChainlinkSource is IPriceSource {
    IAggregatorV3 public immutable feed;
    bool public immutable invert;
    /// @dev 10**(18 + quoteDecimals - baseDecimals) pre-invert; fixed at deploy
    uint256 public immutable scaleNum;
    uint256 public immutable feedScale;

    /// @notice The token decimals given would scale every price to zero.
    error BadDecimals();

    constructor(IAggregatorV3 _feed, address pricedToken, address otherToken) {
        feed = _feed;
        invert = pricedToken > otherToken; // v4 sorts currencies by address: the higher is token1
        feedScale = 10 ** _feed.decimals();
        // price of one raw base unit in raw quote units, X18:
        // human price * 10^quoteDec / 10^baseDec * 1e18
        scaleNum = 10 ** (18 + TokenDecimals.read(otherToken)) / 10 ** TokenDecimals.read(pricedToken);
        if (scaleNum == 0) revert BadDecimals();
    }

    /// @dev A price that scales to zero is reported as "no price", the same as a
    /// non-positive answer. Reverting here would stop every swap in the pool, and the
    /// hook already treats (0, 0) as stale.
    function priceX18() external view returns (uint256, uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) return (0, 0);
        uint256 p = uint256(answer) * scaleNum / feedScale;
        if (p == 0) return (0, 0);
        if (invert) p = 1e36 / p;
        return (p, updatedAt);
    }
}
