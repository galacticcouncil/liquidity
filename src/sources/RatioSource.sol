// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IAggregatorV3} from "./ChainlinkSource.sol";
import {TokenDecimals} from "./TokenDecimals.sol";

/// @notice Price from the ratio of two same-quote feeds. Built from the pool's two tokens, each
/// with the USD feed that prices it, in any order: the source sorts them by address (the lower
/// is the pool's token0, whose feed is the numerator) and reads their decimals. For an ETH/HDX
/// pool that is ETH/USD ÷ HDX/USD, which gives HDX per ETH. A feed named with the wrong token
/// inverts the price. Each feed has its own age limit, so a fast feed that stalls is caught by
/// its own heartbeat rather than hidden behind a slow one; the timestamp reported is the older.
contract RatioSource is IPriceSource {
    IAggregatorV3 public immutable feedBase; // prices pool token0 in USD
    IAggregatorV3 public immutable feedQuote; // prices pool token1 in USD
    uint256 public immutable baseScale;
    uint256 public immutable quoteScale;
    uint256 public immutable decimalsScaleNum; // 10^(18+dec1)
    uint256 public immutable decimalsScaleDen; // 10^dec0
    uint256 public immutable maxAgeBase; // seconds feedBase may lag before the price is unusable
    uint256 public immutable maxAgeQuote; // the same for feedQuote

    /// @param maxAgeA How old feedA's answer may be, in seconds; set from its heartbeat. Likewise B.
    constructor(
        address tokenA,
        IAggregatorV3 feedA,
        uint256 maxAgeA,
        address tokenB,
        IAggregatorV3 feedB,
        uint256 maxAgeB
    ) {
        // v4 sorts currencies by address: the lower is token0; each feed keeps its own limit
        bool aIs0 = tokenA < tokenB;
        (address token0, address token1) = aIs0 ? (tokenA, tokenB) : (tokenB, tokenA);
        (IAggregatorV3 feed0, IAggregatorV3 feed1) = aIs0 ? (feedA, feedB) : (feedB, feedA);
        (maxAgeBase, maxAgeQuote) = aIs0 ? (maxAgeA, maxAgeB) : (maxAgeB, maxAgeA);
        feedBase = feed0;
        feedQuote = feed1;
        baseScale = 10 ** feed0.decimals();
        quoteScale = 10 ** feed1.decimals();
        decimalsScaleNum = 10 ** (18 + uint256(TokenDecimals.read(token1)));
        decimalsScaleDen = 10 ** uint256(TokenDecimals.read(token0));
    }

    /// @dev "No price", (0, 0), when either answer is not positive, older than its feed's limit,
    /// or dated in the future. The hook reads that as no price: fee cap, nothing placed.
    function priceX18() external view returns (uint256, uint256) {
        (, int256 aB,, uint256 uB,) = feedBase.latestRoundData();
        (, int256 aQ,, uint256 uQ,) = feedQuote.latestRoundData();
        if (aB <= 0 || aQ <= 0) return (0, 0);
        if (!_fresh(uB, maxAgeBase) || !_fresh(uQ, maxAgeQuote)) return (0, 0);
        // human ratio = (aB/baseScale) / (aQ/quoteScale); raw-unit X18 applies token decimals
        uint256 p = uint256(aB) * quoteScale * decimalsScaleNum / (uint256(aQ) * baseScale) / decimalsScaleDen;
        return (p, uB < uQ ? uB : uQ);
    }

    function _fresh(uint256 updatedAt, uint256 maxAge) internal view returns (bool) {
        return updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
    }
}
