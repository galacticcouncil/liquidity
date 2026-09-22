// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Moves a pool that drifted off its oracle back onto it before funding, with the recipe from
// the Gamma launch (tiny straddling position, swap to the oracle price, burn), through
// PoolAnchor. Only needed when 01_SetupPool or 02_Fund says the pool is off the oracle.
//
//   set -a; source .env.hdx-hollar; set +a
//   forge script script/AnchorPool.s.sol --rpc-url robinhood --broadcast
//
// Spends a little of both tokens, never more than ANCHOR_MAX0 / ANCHOR_MAX1 (raw units), which
// it approves or, for native ETH, sends and gets back unused. ANCHOR_LIQUIDITY sizes the tiny
// position. Any liquidity from others on the way costs more; past the caps nothing happens.

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolScript} from "./PoolScript.sol";
import {PoolAnchor} from "./PoolAnchor.sol";

interface IERC20Approve {
    function approve(address, uint256) external returns (bool);
}

contract AnchorPool is PoolScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        PoolKey memory key = _poolKey(address(hook));
        PoolId id = key.toId();
        (IPriceSource source,,,, uint32 staleAfter,,,,, int24 guard,) = hook.config(id);
        require(address(source) != address(0), "pool not configured: run 01_SetupPool first");
        (uint160 target, int24 oracleTick) = _oracle(source, staleAfter);
        (uint160 current, int24 poolTick,,) = MANAGER.getSlot0(id);
        require(current != 0, "pool not initialized: run 01_SetupPool first");
        uint256 before = _absDiff(poolTick, oracleTick);
        console2.log("ticks from the oracle before:", before);
        if (before <= uint256(int256(guard))) {
            console2.log("already within the guard: nothing to anchor");
            return;
        }

        _anchor(key, target, target < current);

        (, poolTick,,) = MANAGER.getSlot0(id);
        uint256 afterGap = _absDiff(poolTick, oracleTick);
        console2.log("ticks from the oracle after:", afterGap);
        require(afterGap <= uint256(int256(guard)), "anchored pool is still outside the guard");
    }

    function _anchor(PoolKey memory key, uint160 target, bool priceFalls) internal {
        uint256 max0 = vm.envUint("ANCHOR_MAX0");
        uint256 max1 = vm.envUint("ANCHOR_MAX1");
        bool native = key.currency0.isAddressZero();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PoolAnchor helper = new PoolAnchor(MANAGER);
        if (!native) IERC20Approve(Currency.unwrap(key.currency0)).approve(address(helper), max0);
        IERC20Approve(Currency.unwrap(key.currency1)).approve(address(helper), max1);
        helper.anchor{value: native ? max0 : 0}(
            key, target, uint128(vm.envUint("ANCHOR_LIQUIDITY")), priceFalls ? max0 : max1
        );
        vm.stopBroadcast();
    }
}
