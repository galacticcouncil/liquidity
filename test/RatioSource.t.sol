// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RatioSource} from "../src/sources/RatioSource.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {MockAggregator} from "./mocks/SourceMocks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// RatioSource prices a pool from two USD feeds, each named with the token it prices. The pairing
/// decides which way up the price comes out and nothing in the hook can tell, so it is pinned
/// here; the order the pairs are given in no longer matters.
contract RatioSourceTest is Test {
    address constant ETH = address(0); // native ETH, the ETH/HDX pool's token0
    address hdx; // 12 decimals, as on Hydration; the pool's token1
    MockAggregator ethUsd; // prices ETH in USD
    MockAggregator hdxUsd; // prices HDX in USD

    function setUp() public {
        vm.warp(1_000_000);
        hdx = address(new MockERC20("HydraDX", "HDX", 12));
        ethUsd = new MockAggregator(8, 2400e8); // $2,400
        hdxUsd = new MockAggregator(8, 1e6); // $0.01
    }

    function _ethHdx() internal returns (RatioSource) {
        return new RatioSource(ETH, IAggregatorV3(address(ethUsd)), hdx, IAggregatorV3(address(hdxUsd)));
    }

    /// 1. 240,000 HDX per ETH: in raw units, 0.24 raw HDX per raw ETH.
    function test_ethHdx_isTheRightWayUp() public {
        (uint256 p,) = _ethHdx().priceX18();
        assertEq(p, 2.4e17);
    }

    /// 2. The same two pairs named the other way round give the same source.
    function test_theOrderOfThePairs_doesNotMatter() public {
        RatioSource hdxFirst = new RatioSource(hdx, IAggregatorV3(address(hdxUsd)), ETH, IAggregatorV3(address(ethUsd)));
        (uint256 p,) = hdxFirst.priceX18();
        assertEq(p, 2.4e17, "the same price");
        assertEq(address(hdxFirst.feedBase()), address(ethUsd), "ETH's feed is the numerator: ETH is token0");
    }

    /// 3. The one mistake left: a feed named with the wrong token turns the price upside down,
    /// 57.6 billion times smaller, about 248,000 ticks off. EXPECTED_TICK catches it.
    function test_feedsNamedWithTheWrongTokens_invertThePrice() public {
        RatioSource wrong = new RatioSource(ETH, IAggregatorV3(address(hdxUsd)), hdx, IAggregatorV3(address(ethUsd)));
        (uint256 right,) = _ethHdx().priceX18();
        (uint256 w,) = wrong.priceX18();
        assertEq(w, 4_166_666, "about 4.2e-12 raw HDX per raw ETH");
        assertApproxEqRel(right / w, 57_600_000_000, 1e12, "57.6 billion times smaller");
    }

    /// 4. Staleness is the older of the two feeds, whichever one it is.
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

    /// 5. A zero or negative answer on either feed is "no price", which the hook reads as stale.
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

    /// 6. Feed decimals are normalised: HDX/USD as an 18-decimal feed gives the same price.
    function test_feedDecimals_areNormalised() public {
        MockAggregator hdxUsd18 = new MockAggregator(18, 1e16); // $0.01 with 18 decimals
        RatioSource src = new RatioSource(ETH, IAggregatorV3(address(ethUsd)), hdx, IAggregatorV3(address(hdxUsd18)));
        (uint256 p,) = src.priceX18();
        assertEq(p, 2.4e17);
    }

    /// 7. Token decimals that scale the price below one raw unit give a zero price, which the
    /// hook treats as stale instead of trusting it: a 36-decimal token0 priced in a 0-decimal token1.
    function test_priceBelowOneRawUnit_isZero() public {
        address token0 = _token(address(0x1000), 36);
        address token1 = _token(address(0x2000), 0);
        RatioSource src =
            new RatioSource(token0, IAggregatorV3(address(hdxUsd)), token1, IAggregatorV3(address(ethUsd)));
        (uint256 p,) = src.priceX18();
        assertEq(p, 0);
    }

    /// 8. With HOLLAR at exactly $1, RatioSource and ChainlinkSource agree on ETH/HOLLAR.
    function test_matchesChainlinkSource_forADollarQuote() public {
        MockAggregator hollarUsd = new MockAggregator(8, 1e8); // $1
        address hollar = address(new MockERC20("Hollar", "HOLLAR", 18));
        RatioSource ratio =
            new RatioSource(ETH, IAggregatorV3(address(ethUsd)), hollar, IAggregatorV3(address(hollarUsd)));
        ChainlinkSource single = new ChainlinkSource(IAggregatorV3(address(ethUsd)), ETH, hollar);
        (uint256 fromRatio,) = ratio.priceX18();
        (uint256 fromSingle,) = single.priceX18();
        assertEq(fromRatio, fromSingle, "the two sources agree");
        assertEq(fromRatio, 2400e18, "2,400 HOLLAR per ETH");
    }

    /// @dev A token with `d` decimals at a chosen address, so a test decides which sorts first.
    function _token(address at, uint8 d) internal returns (address) {
        vm.etch(at, address(new MockERC20("T", "T", d)).code);
        return at;
    }
}
