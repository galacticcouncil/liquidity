// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Proves one pool of the testnet rehearsal came out right after the owner funded it: the owner owns the
// hook, the pool price sits on the oracle, its liquidity is placed, and its wealth (wallet plus what the
// hook holds, valued at the oracle price) fell by no more than gas. If its anchor had to trade
// through someone else's liquidity, the most it may cost is the fee cap on the anchor's spend cap.
// Read-only; rehearse.sh runs it per pool with that pool's settings and the owner's numbers loaded:
//
//   env: the pool's settings, OWNER, OWNER_BEFORE_0/1, OWNER_AFTER_0/1 (raw balances around its batch),
//        OWNER_GAS_WEI (what its batch and clear transactions cost)

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BandHook} from "../../src/BandHook.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {PoolScript} from "../PoolScript.sol";

contract Check is PoolScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external view {
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        PoolKey memory key = _poolKey(address(hook));
        PoolId id = key.toId();
        address owner = vm.envAddress("OWNER");
        require(hook.owner() == owner && hook.pendingOwner() == address(0), "the owner does not own the hook");

        (uint256 px, uint160 sqrtP, uint24 feeCap) = _checkOnOracle(hook, id);

        (,,, uint128 coreLiq) = hook.core(id);
        (,,, uint128 backstopLiq) = hook.backstop(id);
        require(coreLiq > 0 && backstopLiq > 0, "the owner's liquidity is not placed");

        (uint256 held0, uint256 held1) = _held(hook, key, id, sqrtP);
        _checkWealth(px, held0, held1, feeCap, key.currency0.isAddressZero());
        console2.log("PASS");
    }

    /// @dev The pool price must sit on the oracle (within a tick of rounding). Returns the oracle
    /// price, the pool price and the fee cap for the wealth check.
    function _checkOnOracle(BandHook hook, PoolId id) internal view returns (uint256 px, uint160 sqrtP, uint24 feeCap) {
        IPriceSource source;
        uint32 staleAfter;
        (source,, feeCap,, staleAfter,,,,,,,) = hook.config(id);
        (, int24 oracleTick) = _oracle(source, staleAfter);
        (px,) = source.priceX18();
        int24 poolTick;
        (sqrtP, poolTick,,) = MANAGER.getSlot0(id);
        console2.log("pool tick:", int256(poolTick));
        console2.log("oracle tick:", int256(oracleTick));
        require(_absDiff(poolTick, oracleTick) <= 1, "pool price is not on the oracle");
    }

    /// @dev What the hook holds for this pool: its three positions at the current price plus idle tokens.
    function _held(BandHook hook, PoolKey memory key, PoolId id, uint160 sqrtP)
        internal
        view
        returns (uint256 a0, uint256 a1)
    {
        BandHook.Pos[3] memory p;
        (p[0].lower, p[0].upper,, p[0].liquidity) = hook.core(id);
        (p[1].lower, p[1].upper,, p[1].liquidity) = hook.backstop(id);
        (p[2].lower, p[2].upper,, p[2].liquidity) = hook.limit(id);
        for (uint256 i; i < 3; i++) {
            if (p[i].liquidity == 0) continue;
            (uint256 x, uint256 y) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtP, TickMath.getSqrtPriceAtTick(p[i].lower), TickMath.getSqrtPriceAtTick(p[i].upper), p[i].liquidity
            );
            a0 += x;
            a1 += y;
        }
        a0 += key.currency0.balanceOf(address(hook));
        a1 += key.currency1.balanceOf(address(hook));
    }

    /// @dev The owner's wallet plus the hook's holdings, valued in token1 at the oracle price, before and
    /// after its batch. Gas is added back: it is a cost, not a loss to anyone.
    function _checkWealth(uint256 px, uint256 held0, uint256 held1, uint24 feeCap, bool native) internal view {
        uint256 gas0 = native ? vm.envUint("OWNER_GAS_WEI") : 0;
        int256 spent0 = int256(vm.envUint("OWNER_BEFORE_0")) - int256(vm.envUint("OWNER_AFTER_0") + gas0);
        int256 spent1 = int256(vm.envUint("OWNER_BEFORE_1")) - int256(vm.envUint("OWNER_AFTER_1"));
        int256 spentValue = spent1 + spent0 * int256(px) / 1e18;
        int256 heldValue = int256(held1 + held0 * px / 1e18);
        int256 loss = spentValue - heldValue;

        uint256 deposit = vm.envUint("FUND_AMOUNT1") + vm.envUint("FUND_AMOUNT0") * px / 1e18;
        // rounding: each mint takes a few wei more than the position is worth back
        uint256 allowed = deposit / 1e6 + 1000;
        bool anchorTraded =
            spent0 != int256(vm.envUint("FUND_AMOUNT0")) || spent1 != int256(vm.envUint("FUND_AMOUNT1"));
        if (anchorTraded) {
            uint256 capValue = vm.envUint("ANCHOR_MAX1") + vm.envUint("ANCHOR_MAX0") * px / 1e18;
            allowed += capValue * feeCap / 1e6;
        }
        console2.log("anchor traded:", anchorTraded);
        console2.log("the owner spent, token0 raw:", spent0);
        console2.log("the owner spent, token1 raw:", spent1);
        console2.log("deposit value (token1 raw):", deposit);
        console2.log("loss (token1 raw):", loss);
        console2.log("allowed (token1 raw):", allowed);
        require(loss <= int256(allowed), "the owner lost more than allowed");
    }
}
