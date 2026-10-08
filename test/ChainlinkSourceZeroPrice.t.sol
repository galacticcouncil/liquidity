// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {MockAggregator} from "./mocks/SourceMocks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// A price that scales to zero must be reported as "no price", not reverted. A source
/// that reverts stops every swap in its pool, and the source used to be unreplaceable.
contract ChainlinkSourceZeroPriceTest is Test {
    address constant LOW = address(0x1000); // sorts first: the pool's token0
    address constant HIGH = address(0x2000); // sorts second: token1

    /// Feed with 18 decimals, an 18-decimal priced token and a 6-decimal other token:
    /// scaleNum is 1e6 and feedScale is 1e18, so any answer below 1e12 scales to zero. The
    /// priced token sits at HIGH when `invert` is wanted, so the source flips the price.
    function _tinyPriceSource(bool invert) internal returns (ChainlinkSource src, MockAggregator feed) {
        feed = new MockAggregator(18, 1e11);
        address priced = _token(invert ? HIGH : LOW, 18);
        address other = _token(invert ? LOW : HIGH, 6);
        src = new ChainlinkSource(IAggregatorV3(address(feed)), priced, other);
        assertEq(src.invert(), invert, "orientation follows the addresses");
    }

    /// @dev A token with `d` decimals at a chosen address, so a test decides which sorts first.
    /// The decimals are baked into the mock's code, so copying the code copies them.
    function _token(address at, uint8 d) internal returns (address) {
        vm.etch(at, address(new MockERC20("T", "T", d)).code);
        return at;
    }

    /// The case that used to revert with a division by zero.
    function test_invertedSource_withAPriceThatScalesToZero_reportsNoPrice() public {
        (ChainlinkSource src,) = _tinyPriceSource(true);
        (uint256 p, uint256 updatedAt) = src.priceX18();
        assertEq(p, 0, "reported as no price");
        assertEq(updatedAt, 0, "and no timestamp, so the hook reads it as stale");
    }

    /// The same shape without inversion already returned zero; it still does.
    function test_plainSource_withAPriceThatScalesToZero_reportsNoPrice() public {
        (ChainlinkSource src,) = _tinyPriceSource(false);
        (uint256 p,) = src.priceX18();
        assertEq(p, 0, "reported as no price");
    }

    /// One unit larger and the price is real again, so the guard is not swallowing
    /// prices it should be returning.
    function test_justAboveTheZeroThreshold_returnsARealPrice() public {
        (ChainlinkSource src, MockAggregator feed) = _tinyPriceSource(true);
        feed.set(1e12, block.timestamp);
        (uint256 p,) = src.priceX18();
        assertGt(p, 0, "a price that does not scale to zero comes through");
        console2.log(string.concat("  inverted priceX18 at answer 1e12: ", vm.toString(p)));
    }

    /// A non-positive answer is unchanged.
    function test_nonPositiveAnswer_stillReportsNoPrice() public {
        (ChainlinkSource src, MockAggregator feed) = _tinyPriceSource(true);
        feed.set(0, block.timestamp);
        (uint256 p,) = src.priceX18();
        assertEq(p, 0, "zero answer");
        feed.set(-1, block.timestamp);
        (p,) = src.priceX18();
        assertEq(p, 0, "negative answer");
    }

    // ---------- the constructor

    /// Base decimals above 18 + quote decimals make scaleNum zero, so every price would
    /// be zero for ever. The constructor now refuses rather than deploying something
    /// permanently broken.
    function test_constructor_rejectsDecimalsThatScaleEverythingToZero() public {
        MockAggregator feed = new MockAggregator(8, 2388e8);
        address priced = _token(LOW, 19);
        address other = _token(HIGH, 0);
        vm.expectRevert(ChainlinkSource.BadDecimals.selector);
        new ChainlinkSource(IAggregatorV3(address(feed)), priced, other);
    }

    /// The boundary the other way: 18 base against 0 quote gives scaleNum of exactly 1.
    function test_constructor_acceptsTheBoundary() public {
        MockAggregator feed = new MockAggregator(8, 2388e8);
        ChainlinkSource src = new ChainlinkSource(IAggregatorV3(address(feed)), _token(LOW, 18), _token(HIGH, 0));
        assertEq(src.scaleNum(), 1, "smallest workable scale");
    }

    /// The real launch shapes still build and price correctly.
    function test_constructor_acceptsTheLaunchShapes() public {
        MockAggregator ethUsd = new MockAggregator(8, 2388e8);
        ChainlinkSource ethHollar = new ChainlinkSource(IAggregatorV3(address(ethUsd)), address(0), _token(HIGH, 18));
        (uint256 p,) = ethHollar.priceX18();
        assertEq(p, 2388e18, "ETH/HOLLAR priced in whole HOLLAR per ETH");

        MockAggregator hdxEth = new MockAggregator(8, 502);
        ChainlinkSource ethHdx = new ChainlinkSource(IAggregatorV3(address(hdxEth)), _token(HIGH, 12), address(0));
        (uint256 q,) = ethHdx.priceX18();
        assertGt(q, 0, "ETH/HDX inverted price is real");
        console2.log(string.concat("  ETH/HDX priceX18: ", vm.toString(q)));
    }
}
