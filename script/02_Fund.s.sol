// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Funds one configured pool. Approvals for ERC20 legs are handled here; the native leg
// (currency0 = 0x0) is sent as msg.value. Refuses up front, before any token moves, when the
// pool is further from the oracle than its guard - the hook would refuse too; this says why.
//
//   set -a; source .env.eth-hollar; set +a
//   forge script script/02_Fund.s.sol --rpc-url robinhood --broadcast

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolScript} from "./PoolScript.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
}

contract FundPool is PoolScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        PoolKey memory key = _poolKey(address(hook));
        PoolId id = key.toId();
        _requireOnTheOracle(hook, id);

        address c0 = vm.envAddress("CURRENCY0");
        address c1 = vm.envAddress("CURRENCY1");
        uint256 a0 = vm.envUint("FUND_AMOUNT0");
        uint256 a1 = vm.envUint("FUND_AMOUNT1");

        vm.startBroadcast(pk);
        if (c0 != address(0)) IERC20(c0).approve(address(hook), a0);
        IERC20(c1).approve(address(hook), a1);
        hook.fund{value: c0 == address(0) ? a0 : 0}(id, a0, a1);
        vm.stopBroadcast();

        (int24 cl, int24 cu,, uint128 cliq) = hook.core(id);
        (int24 ll, int24 lu,, uint128 lliq) = hook.limit(id);
        console2.log("core lower:", int256(cl));
        console2.log("core upper:", int256(cu));
        console2.log("core liquidity:", uint256(cliq));
        console2.log("limit lower:", int256(ll));
        console2.log("limit upper:", int256(lu));
        console2.log("limit liquidity:", uint256(lliq));
    }

    /// @dev Read-only gate, with the hook's own source, staleness and guard.
    function _requireOnTheOracle(BandHook hook, PoolId id) internal view {
        (IPriceSource source,,,, uint32 staleAfter,,,,, int24 guard,) = hook.config(id);
        require(address(source) != address(0), "pool not configured: run 01_SetupPool first");
        (, int24 oracleTick) = _oracle(source, staleAfter);
        (, int24 poolTick,,) = MANAGER.getSlot0(id);
        require(
            _absDiff(poolTick, oracleTick) <= uint256(int256(guard)),
            "pool is further from the oracle than its guard: run AnchorPool first"
        );
    }
}
