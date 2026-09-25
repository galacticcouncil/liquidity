// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// What a pool does while its price source fails (audit A-7/B-1/C-4): swaps continue at the fee
// cap, nothing is placed, and the pool recovers by itself when the source answers again.

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {ToggleRevertSource, GasBurnerSource, ShortAnswerSource} from "./mocks/SourceMocks.sol";

contract BandHookDeadSourceTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    ToggleRevertSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    uint24 constant FLOOR = 3000;
    uint24 constant CAP = 20000;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        source = new ToggleRevertSource(1e18);

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        hook.configure(key, _cfg(IPriceSource(address(source))));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        hook.fund(id, FUND, FUND);
    }

    // ---------- the tests

    function test_aDeadSource_swapsPayTheCap() public {
        source.kill();
        assertEq(_swapFee(key), CAP, "a failed read charges the cap, and the swap goes through");
    }

    function test_aDeadSource_recenterAndFundRefuse() public {
        (int24 lower, int24 upper,, uint128 liquidity) = hook.core(id);
        source.kill();

        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.recenter(id);
        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.fund(id, 0, 0);

        (int24 lowerAfter, int24 upperAfter,, uint128 liquidityAfter) = hook.core(id);
        assertEq(lowerAfter, lower, "the band did not move");
        assertEq(upperAfter, upper, "the band did not move");
        assertEq(liquidityAfter, liquidity, "nor did its liquidity");
    }

    function test_aStaleSource_stillPaysTheFloor() public {
        vm.warp(block.timestamp + 2 hours); // older than staleAfter (1 hour), but still answering
        assertEq(_swapFee(key), FLOOR, "stale is not failed: the floor, as before");
    }

    function test_aRevivedSource_pricesNormallyWithoutSetSource() public {
        source.kill();
        assertEq(_swapFee(key), CAP, "while dead: the cap");

        source.revive();
        (, int24 poolTick,,) = manager.getSlot0(id);
        uint256 gap = poolTick < 0 ? uint256(int256(-poolTick)) : uint256(int256(poolTick)); // oracle at tick 0
        assertEq(_swapFee(key), FLOOR + gap * 100, "floor plus 0.01% per tick of gap, with no setSource");
    }

    function test_aSourceThatBurnsItsGas_swapsPayTheCap() public {
        uint256 g = gasleft();
        _swapFee(key);
        uint256 healthy = g - gasleft();

        vm.etch(address(source), address(new GasBurnerSource()).code); // the source now loops
        g = gasleft();
        uint24 fee = _swapFee(key);
        uint256 burning = g - gasleft();

        assertEq(fee, CAP, "a source that runs out of gas counts as failed");
        assertLt(burning, healthy + 210_000, "the read stopped at SOURCE_GAS (200k), not at the swap's gas");
    }

    function test_aShortAnswer_swapsPayTheCap() public {
        vm.etch(address(source), address(new ShortAnswerSource()).code); // one number, not two
        assertEq(_swapFee(key), CAP, "a malformed answer counts as failed");
    }

    function test_aDeadSource_inSwapRecenterSkips() public {
        // make a recenter due: the oracle moves 600 ticks (trigger 500) and the pool follows it
        source.set(_priceAt(600), block.timestamp);
        _pushPoolTo(600);
        hook.setAutoRecenter(id, true);
        assertEq(_coreCenter(), 0, "the band is still quoted around tick 0");

        source.kill();
        _swapFee(key);
        assertEq(_coreCenter(), 0, "no recenter is attempted while the source is dead");

        source.revive();
        _swapFee(key);
        assertApproxEqAbs(_coreCenter(), 600, 1, "the same swap recenters once the source answers: it was due");
    }

    function test_aNeverConfiguredPool_refusesSwaps() public {
        PoolKey memory stranger = key;
        stranger.tickSpacing = 60; // a pool on our hook that nobody configured
        manager.initialize(stranger, TickMath.getSqrtPriceAtTick(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                HOOK_ADDR,
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BandHook.NotEnabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            stranger,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ---------- helpers

    function _cfg(IPriceSource src) internal pure returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: src,
            feeFloor: FLOOR,
            feeCap: CAP,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 1000,
            backstopHalfTicks: 16000,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 300,
            enabled: true,
            autoRecenter: false
        });
    }

    /// @dev A small sell of token0 on `k`; returns the fee from the pool's Swap event.
    function _swapFee(PoolKey memory k) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return _feeIn(vm.getRecordedLogs());
    }

    /// @dev Buys token0 until the pool reaches `tick`.
    function _pushPoolTo(int24 tick) internal {
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The price, in the 1e18 fixed point a source reports, that sits exactly at `tick`.
    function _priceAt(int24 tick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(s, s * 1e18, 1 << 192);
    }

    function _feeIn(Vm.Log[] memory logs) internal pure returns (uint24) {
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no swap event");
    }

    function _coreCenter() internal view returns (int24 center) {
        (,, center,) = hook.core(id);
    }
}
