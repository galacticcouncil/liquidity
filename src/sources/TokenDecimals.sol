// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// A pool token's decimals, read from the token itself, so no one ever types a decimals number
// into a price source. Shared by ChainlinkSource and RatioSource.

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

library TokenDecimals {
    /// @dev 18 for native ETH (address 0), otherwise the token's own. A token without decimals()
    /// or an address with no code reverts, so a source for it cannot be built.
    function read(address token) internal view returns (uint8) {
        return token == address(0) ? 18 : IERC20Decimals(token).decimals();
    }
}
