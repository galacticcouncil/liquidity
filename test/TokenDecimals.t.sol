// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The price sources read each pool token's decimals from the token itself (audit C-2, A-6).
// These tests pin the one helper that does it.

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TokenDecimals} from "../src/sources/TokenDecimals.sol";

/// @dev Exposes the library's internal function.
contract TokenDecimalsHarness {
    function read(address token) external view returns (uint8) {
        return TokenDecimals.read(token);
    }
}

/// @dev A token contract that never implemented decimals().
contract NoDecimals {}

contract TokenDecimalsTest is Test {
    TokenDecimalsHarness h = new TokenDecimalsHarness();

    function test_nativeEthCountsAs18() public view {
        assertEq(h.read(address(0)), 18, "native ETH has no contract to ask");
    }

    function test_aTokenReportsItsOwnDecimals() public {
        assertEq(h.read(address(new MockERC20("Hollar", "HOLLAR", 8))), 8, "a Wormhole-wrapped HOLLAR says 8");
        assertEq(h.read(address(new MockERC20("HydraDX", "HDX", 12))), 12, "HDX says 12");
    }

    function test_aTokenWithoutDecimals_reverts() public {
        address token = address(new NoDecimals());
        vm.expectRevert();
        h.read(token);
    }

    function test_anAddressWithNoCode_reverts() public {
        address typo = makeAddr("a wallet typed as a token");
        vm.expectRevert();
        h.read(typo);
    }
}
