// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolAnchor} from "../script/PoolAnchor.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// poc: anyone can push an empty pool to either end of the tick range for free, and PoolAnchor's
/// straddle (floor(tick) -+ spacing, unclamped) then falls outside it, so the recovery path reverts.
contract PoolAnchorExtremeTicksTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));

    IPoolManager manager;
    PoolSwapTest router;
    MockERC20 t0;
    MockERC20 t1;
    BandHook hook;
    PoolAnchor helper;
    PoolKey key;
    PoolId id;
    address griefer = makeAddr("griefer");

    // hdx launch shape: spacing 60, cap 2%, band 1000, guard 300
    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        helper = new PoolAnchor(manager);

        key = PoolKey(
            Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(HOOK_ADDR)
        );
        id = key.toId();
        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(new MockPriceSource(1e18))), // oracle at tick 0
                feeFloor: 3000,
                feeCap: 20000,
                feeSlopePpm: 1_000_000,
                staleAfter: 2 hours,
                halfBandTicks: 1000,
                backstopHalfTicks: 16000,
                backstopBps: 3500,
                triggerTicks: 500,
                guardTicks: 300,
                enabled: true,
                autoRecenter: false
            })
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        MockERC20[2] memory tokens = [t0, t1];
        for (uint256 i; i < 2; i++) {
            tokens[i].mint(address(this), 1e30);
            tokens[i].approve(address(hook), type(uint256).max);
            tokens[i].approve(address(helper), type(uint256).max);
            tokens[i].approve(address(router), type(uint256).max);
            tokens[i].mint(griefer, 1);
            vm.prank(griefer);
            tokens[i].approve(address(router), type(uint256).max);
        }
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    /// 1 wei exact-in with a price limit: on an empty pool the price lands on the limit.
    function _swapTo(address who, uint160 limit) internal {
        (uint160 cur,,,) = manager.getSlot0(id);
        vm.prank(who);
        router.swap(
            key,
            SwapParams({zeroForOne: limit < cur, amountSpecified: -1, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _grief(uint160 limit) internal {
        _swapTo(griefer, limit);
        // free: the griefer still holds its 1 wei of each token
        assertEq(t0.balanceOf(griefer) + t1.balanceOf(griefer), 2, "the push cost nothing");
    }

    function test_pushedToMinTick_fundRefuses_andAnchorReverts() public {
        _grief(TickMath.MIN_SQRT_PRICE + 1);
        assertEq(_tick(), TickMath.MIN_TICK);

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, 1e21, 1e21);

        // lo = floor(-887272, 60) - 60 = -887340 < MIN_TICK
        vm.expectRevert(abi.encodeWithSelector(Pool.TickLowerOutOfBounds.selector, int24(-887340)));
        helper.anchor(key, TickMath.getSqrtPriceAtTick(0), 1e12, 1e18);
    }

    function test_pushedToMaxTick_anchorReverts() public {
        _grief(TickMath.MAX_SQRT_PRICE - 1);
        assertEq(_tick(), TickMath.MAX_TICK - 1);

        // lo = floor(887271, 60) - 60 = 887160, hi = 887280 > MAX_TICK
        vm.expectRevert(abi.encodeWithSelector(Pool.TickUpperOutOfBounds.selector, int24(887280)));
        helper.anchor(key, TickMath.getSqrtPriceAtTick(0), 1e12, 1e18);
    }

    /// the fix direction: on an empty pool the straddle is not needed; a bare limited swap recovers.
    function test_bareLimitedSwap_recovers_andFundSucceeds() public {
        _grief(TickMath.MIN_SQRT_PRICE + 1);
        _swapTo(address(this), TickMath.getSqrtPriceAtTick(0));
        assertEq(_tick(), 0);
        hook.fund(id, 1e21, 1e21);
    }
}
