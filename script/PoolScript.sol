// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// What the per-pool scripts share: the pool key built from the pool's settings file, and the
// oracle price read the way the hook reads it, as a pool price and tick.

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";

abstract contract PoolScript is Script {
    IPoolManager internal constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    /// @dev The pool key from CURRENCY0, CURRENCY1 and TICK_SPACING, on the given hook.
    function _poolKey(address hook) internal view returns (PoolKey memory) {
        address c0 = vm.envAddress("CURRENCY0"); // 0x0 for native ETH
        address c1 = vm.envAddress("CURRENCY1");
        require(c0 < c1, "currencies must be sorted (currency0 < currency1)");
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(int256(vm.envInt("TICK_SPACING"))),
            hooks: IHooks(hook)
        });
    }

    /// @dev The source's price as a pool price and tick. Refuses what the hook would call stale:
    /// no price, a timestamp from the future, or one older than `staleAfter`.
    function _oracle(IPriceSource source, uint256 staleAfter)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick)
    {
        (uint256 px, uint256 updatedAt) = source.priceX18();
        require(px > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= staleAfter, "oracle stale");
        sqrtPriceX96 = _sqrtPriceX96(px);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d < 0 ? -d : d);
    }

    /// @dev sqrt(priceX18 / 1e18) as a Q64.96 pool price.
    function _sqrtPriceX96(uint256 priceX18) internal pure returns (uint160) {
        uint256 inner = priceX18 * (uint256(1) << 128) / 1e18;
        return uint160(_sqrt(inner) << 32);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
