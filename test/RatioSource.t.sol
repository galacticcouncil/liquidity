// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RatioSource} from "../src/sources/RatioSource.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {MockAggregator} from "./mocks/SourceMocks.sol";

/// RatioSource prices a pool from two USD feeds. Its argument order decides which way up the
/// price comes out, and nothing in the hook can tell, so the order is pinned here.
contract RatioSourceTest is Test {
    MockAggregator ethUsd; // prices ETH, the ETH/HDX pool's token0, in USD
    MockAggregator hdxUsd; // prices HDX, the pool's token1, in USD

    uint8 constant ETH_DECIMALS = 18;
    uint8 constant HDX_DECIMALS = 12;

    function setUp() public {
        vm.warp(1_000_000);
        ethUsd = new MockAggregator(8, 2400e8); // $2,400
        hdxUsd = new MockAggregator(8, 1e6); // $0.01
    }

    function _ethHdx() internal returns (RatioSource) {
        return
            new RatioSource(IAggregatorV3(address(ethUsd)), IAggregatorV3(address(hdxUsd)), ETH_DECIMALS, HDX_DECIMALS);
    }

    /// 1. ETH/USD first gives 240,000 HDX per ETH: in raw units, 0.24 raw HDX per raw ETH.
    function test_ethHdx_isTheRightWayUp() public {
        (uint256 p,) = _ethHdx().priceX18();
        assertEq(p, 2.4e17);
    }

    /// 2. The issue's order, HDX/USD first, turns the price upside down: 57.6 billion times
    /// smaller, about 248,000 ticks off.
    function test_swappedFeeds_invertThePrice() public {
        RatioSource swapped =
            new RatioSource(IAggregatorV3(address(hdxUsd)), IAggregatorV3(address(ethUsd)), ETH_DECIMALS, HDX_DECIMALS);
        (uint256 right,) = _ethHdx().priceX18();
        (uint256 wrong,) = swapped.priceX18();
        assertEq(wrong, 4_166_666, "about 4.2e-12 raw HDX per raw ETH");
        assertApproxEqRel(right / wrong, 57_600_000_000, 1e12, "57.6 billion times smaller");
    }

    /// 3. Staleness is the older of the two feeds, whichever one it is.
    function test_staleness_isTheOlderFeed() public {
        RatioSource src = _ethHdx();
        hdxUsd.set(1e6, block.timestamp - 1000);
        (, uint256 updatedAt) = src.priceX18();
        assertEq(updatedAt, block.timestamp - 1000, "HDX/USD is the older one");

        hdxUsd.set(1e6, block.timestamp);
        ethUsd.set(2400e8, block.timestamp - 2000);
        (, updatedAt) = src.priceX18();
        assertEq(updatedAt, block.timestamp - 2000, "ETH/USD is the older one");
    }

    /// 4. A zero or negative answer on either feed is "no price", which the hook reads as stale.
    function test_nonPositiveAnswer_isNoPrice() public {
        RatioSource src = _ethHdx();
        hdxUsd.set(0, block.timestamp);
        (uint256 p, uint256 updatedAt) = src.priceX18();
        assertEq(p, 0, "HDX/USD at zero");
        assertEq(updatedAt, 0);

        hdxUsd.set(1e6, block.timestamp);
        ethUsd.set(-1, block.timestamp);
        (p, updatedAt) = src.priceX18();
        assertEq(p, 0, "ETH/USD negative");
        assertEq(updatedAt, 0);
    }

    /// 5. Feed decimals are normalised: HDX/USD as an 18-decimal feed gives the same price.
    function test_feedDecimals_areNormalised() public {
        MockAggregator hdxUsd18 = new MockAggregator(18, 1e16); // $0.01 with 18 decimals
        RatioSource src = new RatioSource(
            IAggregatorV3(address(ethUsd)), IAggregatorV3(address(hdxUsd18)), ETH_DECIMALS, HDX_DECIMALS
        );
        (uint256 p,) = src.priceX18();
        assertEq(p, 2.4e17);
    }

    /// 6. Token decimals that scale the price below one raw unit give a zero price, which the
    /// hook treats as stale instead of trusting it.
    function test_priceBelowOneRawUnit_isZero() public {
        RatioSource src = new RatioSource(IAggregatorV3(address(hdxUsd)), IAggregatorV3(address(ethUsd)), 36, 0);
        (uint256 p,) = src.priceX18();
        assertEq(p, 0);
    }

    /// 7. With HOLLAR at exactly $1, RatioSource and ChainlinkSource agree on ETH/HOLLAR.
    function test_matchesChainlinkSource_forADollarQuote() public {
        MockAggregator hollarUsd = new MockAggregator(8, 1e8); // $1
        RatioSource ratio = new RatioSource(IAggregatorV3(address(ethUsd)), IAggregatorV3(address(hollarUsd)), 18, 18);
        ChainlinkSource single = new ChainlinkSource(IAggregatorV3(address(ethUsd)), false, 18, 18);
        (uint256 fromRatio,) = ratio.priceX18();
        (uint256 fromSingle,) = single.priceX18();
        assertEq(fromRatio, fromSingle, "the two sources agree");
        assertEq(fromRatio, 2400e18, "2,400 HOLLAR per ETH");
    }
}
