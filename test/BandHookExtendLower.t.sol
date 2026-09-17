// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2, stdError} from "forge-std/Test.sol";
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
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Band fitting with a lopsided inventory. `_extendUpper` clamps when its arithmetic
/// would overflow; `_extendLower` does not, and reverts instead.
contract BandHookExtendLowerTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));
    address bob = makeAddr("bob");
    uint256 constant BASE = 100_000e18;
    uint256 constant DUST = 1e6;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        source = new MockPriceSource(1e18);

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

        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 20_000_000e18);
        t1.mint(address(this), 20_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        t0.mint(bob, 20_000_000e18);
        t1.mint(bob, 20_000_000e18);
        vm.startPrank(bob);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _cfg() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: 3000,
            feeCap: 20000,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 1000,
            backstopHalfTicks: 16000,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 100,
            enabled: true
        });
    }

    // ---------- helpers

    function poolTick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _poolSqrt() internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(id);
    }

    function pushPoolToTick(int24 target) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        bool zeroForOne = limit < _poolSqrt();
        vm.prank(bob);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -10_000_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function setOracleTick(int24 t) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        uint256 px96 = FullMath.mulDiv(s, s, 1 << 96);
        source.set(FullMath.mulDiv(px96, 1e18, 1 << 96), block.timestamp);
    }

    function absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d < 0 ? -d : d);
    }

    function hookIdle() internal view returns (uint256 i0, uint256 i1) {
        return (t0.balanceOf(HOOK_ADDR), t1.balanceOf(HOOK_ADDR));
    }

    // ---------- the asymmetry, at funding time

    /// A first fund holding 3x more token1 than token0 by value reverts with an
    /// arithmetic panic inside _extendLower.
    function test_fund_token1Surplus_revertsWithPanic() public {
        vm.expectRevert(stdError.arithmeticError);
        hook.fund(id, BASE, 3 * BASE);
    }

    /// The mirror: 3x more token0 than token1 is absorbed without complaint,
    /// because _extendUpper clamps where _extendLower subtracts.
    function test_fund_token0Surplus_succeeds() public {
        hook.fund(id, 3 * BASE, BASE);
        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);
        assertGt(cliq, 0, "core minted despite the skew");
        assertGt(bliq, 0, "backstop minted despite the skew");
        (uint256 i0, uint256 i1) = hookIdle();
        console2.log(string.concat("  idle token0 ", vm.toString(i0), "  idle token1 ", vm.toString(i1)));
    }

    /// Where the wall is: sweep the token1-to-token0 ratio on a first fund.
    function test_fund_skewBoundary() public {
        console2.log("first fund, token1 : token0 by value");
        for (uint256 r = 1; r <= 6; r++) {
            uint256 snap = vm.snapshotState();
            try hook.fund(id, BASE, r * BASE) {
                console2.log(string.concat("  ratio ", vm.toString(r), " : 1  -> minted"));
            } catch (bytes memory err) {
                console2.log(
                    string.concat("  ratio ", vm.toString(r), " : 1  -> REVERT ", vm.toString(bytes4(err)))
                );
            }
            vm.revertToState(snap);
        }
    }

    // ---------- the asymmetry, at recenter time

    /// The price rises through the band, leaving the hook token1-heavy with a dust
    /// amount of token0. Every recenter gate passes, and recenter still reverts.
    function test_recenter_revertsWhileEveryGatePasses() public {
        hook.fund(id, BASE, BASE);

        pushPoolToTick(1200);
        setOracleTick(poolTick());
        t0.transfer(HOOK_ADDR, DUST);

        (,, int24 center,) = hook.core(id);
        assertGt(absDiff(poolTick(), center), 500, "drift is past the trigger");

        (uint256 i0, uint256 i1) = hookIdle();
        console2.log(string.concat("  idle before recenter: token0 ", vm.toString(i0), "  token1 ", vm.toString(i1)));

        vm.expectRevert(stdError.arithmeticError);
        hook.recenter(id);
    }

    /// The mirror: the price falls the same distance, leaving the hook token0-heavy
    /// with dust of token1. _extendUpper clamps, and recentering works.
    function test_recenter_succeedsInTheMirrorDirection() public {
        hook.fund(id, BASE, BASE);

        pushPoolToTick(-1200);
        setOracleTick(poolTick());
        t1.transfer(HOOK_ADDR, DUST);

        (,, int24 center,) = hook.core(id);
        assertGt(absDiff(poolTick(), center), 500, "drift is past the trigger");

        hook.recenter(id);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "the mirror direction places liquidity");
        console2.log(string.concat("  recentered, core liquidity ", vm.toString(uint256(cliq))));
    }

    /// Without any dust of the scarce token the underflow is never reached: _fitBounds
    /// skips _extendLower, and the core mints nothing at all. Separate behaviour, not
    /// fixed here; see audit findings H3 (second half) and M2.
    function test_recenter_withoutDust_mintsAnEmptyCore() public {
        hook.fund(id, BASE, BASE);

        pushPoolToTick(1200);
        setOracleTick(poolTick());

        (uint256 i0,) = hookIdle();
        assertEq(i0, 0, "no dust of the scarce token");

        hook.recenter(id);
        (,,, uint128 cliq) = hook.core(id);
        (uint256 idle0, uint256 idle1) = hookIdle();
        console2.log(
            string.concat("  core liquidity after recenter ", vm.toString(uint256(cliq)))
        );
        console2.log(string.concat("  idle token0 ", vm.toString(idle0), "  idle token1 ", vm.toString(idle1)));
        assertEq(cliq, 0, "the core was minted empty");
        assertGt(idle1, 0, "and every token1 it held went idle");
    }

    /// How far the price has to rise before recentering becomes impossible.
    function test_recenter_upwardBoundary() public {
        console2.log("price pushed up by N ticks, then recenter");
        int24[6] memory moves = [int24(600), 800, 1000, 1100, 1200, 1500];
        for (uint256 i = 0; i < moves.length; i++) {
            uint256 snap = vm.snapshotState();
            hook.fund(id, BASE, BASE);
            pushPoolToTick(moves[i]);
            setOracleTick(poolTick());
            t0.transfer(HOOK_ADDR, DUST);
            try hook.recenter(id) {
                console2.log(string.concat("  +", vm.toString(int256(moves[i])), " ticks -> recentered"));
            } catch (bytes memory err) {
                console2.log(
                    string.concat(
                        "  +", vm.toString(int256(moves[i])), " ticks -> REVERT ", vm.toString(bytes4(err))
                    )
                );
            }
            vm.revertToState(snap);
        }
    }
}
