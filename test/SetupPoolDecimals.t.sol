// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// 01_SetupPool builds the pool's price source from the decimals the tokens report on chain, not
// from typed settings (audit C-2). These tests pin the helper that reads them.

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SetupPool} from "../script/01_SetupPool.s.sol";

/// @dev Exposes the script's internal helper and nothing else.
contract SetupPoolHarness is SetupPool {
    function tokenDecimals(address token) external view returns (uint8) {
        return _tokenDecimals(token);
    }
}

/// @dev A token contract that never implemented decimals().
contract NoDecimals {}

contract SetupPoolDecimalsTest is Test {
    SetupPoolHarness setup = new SetupPoolHarness();

    function test_nativeEthCountsAs18() public view {
        assertEq(setup.tokenDecimals(address(0)), 18, "native ETH has no contract to ask");
    }

    function test_aTokenReportsItsOwnDecimals() public {
        MockERC20 wormholeHollar = new MockERC20("Hollar", "HOLLAR", 8);
        MockERC20 hdx = new MockERC20("HydraDX", "HDX", 12);
        assertEq(setup.tokenDecimals(address(wormholeHollar)), 8, "a Wormhole-wrapped HOLLAR says 8");
        assertEq(setup.tokenDecimals(address(hdx)), 12, "HDX says 12");
    }

    function test_aTokenWithoutDecimals_stopsTheScript() public {
        address token = address(new NoDecimals());
        vm.expectRevert();
        setup.tokenDecimals(token);
    }

    function test_anAddressWithNoCode_stopsTheScript() public {
        address typo = makeAddr("a wallet typed as CURRENCY1");
        vm.expectRevert();
        setup.tokenDecimals(typo);
    }
}
