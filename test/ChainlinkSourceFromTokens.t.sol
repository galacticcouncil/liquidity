// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ChainlinkSource is built from the token its feed prices and the pool's other token (audit A-6):
// it reads their decimals and works out which way up the price goes from their addresses.

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {MockAggregator} from "./mocks/SourceMocks.sol";

contract ChainlinkSourceFromTokensTest is Test {
    address constant LOW = address(0x1000); // sorts first: the pool's token0
    address constant HIGH = address(0x2000); // sorts second: token1

    MockAggregator ethUsd = new MockAggregator(8, 2400e8); // $2,400
    MockAggregator hdxUsd = new MockAggregator(8, 1e6); // $0.01

    function test_ethIsToken0_notInverted_rawHollarPerRawEth() public {
        ChainlinkSource src = new ChainlinkSource(IAggregatorV3(address(ethUsd)), address(0), _token(HIGH, 18));
        (uint256 p,) = src.priceX18();
        assertFalse(src.invert(), "native ETH always sorts first");
        assertEq(p, 2400e18, "2,400 HOLLAR per ETH, 18 decimals each");
    }

    function test_hdxSortsSecond_theSourceInvertsItself() public {
        address hollar = _token(LOW, 18);
        address hdx = _token(HIGH, 12);
        ChainlinkSource src = new ChainlinkSource(IAggregatorV3(address(hdxUsd)), hdx, hollar);
        (uint256 p,) = src.priceX18();
        assertTrue(src.invert(), "the feed prices token1, so the source flips it");
        assertEq(p, 1e14, "raw HDX per raw HOLLAR: 100 x 1e12 / 1e18 = 1e-4");
    }

    function test_hdxSortsFirst_theSameInputsAreNotInverted() public {
        address hdx = _token(LOW, 12);
        address hollar = _token(HIGH, 18);
        ChainlinkSource src = new ChainlinkSource(IAggregatorV3(address(hdxUsd)), hdx, hollar);
        (uint256 p,) = src.priceX18();
        assertFalse(src.invert(), "the feed prices token0");
        assertEq(p, 1e22, "raw HOLLAR per raw HDX: 0.01 x 1e18 / 1e12 = 1e4");
    }

    function test_an8DecimalHollar_isScaledByItsRealDecimals() public {
        ChainlinkSource src = new ChainlinkSource(IAggregatorV3(address(ethUsd)), address(0), _token(HIGH, 8));
        (uint256 p,) = src.priceX18();
        assertEq(p, 2.4e11, "raw HOLLAR per raw ETH at 8 decimals: 2,400 x 1e8 / 1e18");
    }

    /// @dev A token with `d` decimals at a chosen address, so a test decides which sorts first.
    function _token(address at, uint8 d) internal returns (address) {
        vm.etch(at, address(new MockERC20("T", "T", d)).code);
        return at;
    }
}
