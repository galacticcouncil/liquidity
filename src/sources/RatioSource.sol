// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IAggregatorV3} from "./ChainlinkSource.sol";
import {TokenDecimals} from "./TokenDecimals.sol";

/// @notice Price from the ratio of two same-quote feeds. Built from the pool's two tokens, each
/// with the USD feed that prices it, in any order: the source sorts them by address (the lower
/// is the pool's token0, whose feed is the numerator) and reads their decimals. For an ETH/HDX
/// pool that is ETH/USD ÷ HDX/USD, which gives HDX per ETH. A feed named with the wrong token
/// inverts the price. Staleness is the older of the two.
contract RatioSource is IPriceSource {
    IAggregatorV3 public immutable feedBase; // prices pool token0 in USD
    IAggregatorV3 public immutable feedQuote; // prices pool token1 in USD
    uint256 public immutable baseScale;
    uint256 public immutable quoteScale;
    uint256 public immutable decimalsScaleNum; // 10^(18+dec1)
    uint256 public immutable decimalsScaleDen; // 10^dec0

    constructor(address tokenA, IAggregatorV3 feedA, address tokenB, IAggregatorV3 feedB) {
        // v4 sorts currencies by address: the lower is token0
        (address token0, IAggregatorV3 feed0, address token1, IAggregatorV3 feed1) =
            tokenA < tokenB ? (tokenA, feedA, tokenB, feedB) : (tokenB, feedB, tokenA, feedA);
        feedBase = feed0;
        feedQuote = feed1;
        baseScale = 10 ** feed0.decimals();
        quoteScale = 10 ** feed1.decimals();
        decimalsScaleNum = 10 ** (18 + uint256(TokenDecimals.read(token1)));
        decimalsScaleDen = 10 ** uint256(TokenDecimals.read(token0));
    }

    function priceX18() external view returns (uint256, uint256) {
        (, int256 aB,, uint256 uB,) = feedBase.latestRoundData();
        (, int256 aQ,, uint256 uQ,) = feedQuote.latestRoundData();
        if (aB <= 0 || aQ <= 0) return (0, 0);
        // human ratio = (aB/baseScale) / (aQ/quoteScale); raw-unit X18 applies token decimals
        uint256 p = uint256(aB) * quoteScale * decimalsScaleNum / (uint256(aQ) * baseScale) / decimalsScaleDen;
        return (p, uB < uQ ? uB : uQ);
    }
}
