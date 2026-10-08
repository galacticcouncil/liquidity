// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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

/// A token1 surplus widens the band to the widest allowed instead of reverting,
/// the same way a token0 surplus already did.
contract BandHookExtendLowerClampsTest is Test {
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

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    address bob = makeAddr("bob");

    uint256 constant BASE = 100_000e18;
    uint256 constant DUST = 1e6;
    int24 constant HALF = 1000;
    int24 constant MAX_HALF = 4000; // halfBandTicks * MAX_EXTENSION_MULT
    int24 constant BACKSTOP_HALF = 16000;
    int24 constant SPACING = 10;

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
            tickSpacing: SPACING,
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
            halfBandTicks: HALF,
            backstopHalfTicks: BACKSTOP_HALF,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 300,
            enabled: true,
            autoRecenter: false
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

    function heldByManager(int24 lower, int24 upper, bytes32 salt) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, salt);
    }

    // ---------- funding with a token1 surplus

    /// The case that used to revert: 3x more token1 than token0 now mints.
    function test_fund_token1Surplus_mints() public {
        hook.fund(id, BASE, 3 * BASE);

        (int24 lo, int24 hi,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);

        assertGt(cliq, 0, "core minted");
        assertGt(bliq, 0, "backstop minted");
        assertEq(cliq, heldByManager(lo, hi, bytes32(0)), "core record matches the manager");
        console2.log(string.concat("  core band ", vm.toString(int256(lo)), " .. ", vm.toString(int256(hi))));
    }

    /// The widened band stops at exactly center - maxHalf, not further.
    function test_fund_token1Surplus_clampsToTheWidestAllowed() public {
        hook.fund(id, BASE, 6 * BASE);

        (int24 lo, int24 hi, int24 center,) = hook.core(id);
        assertEq(center, 0, "centred on the oracle");
        assertEq(lo, -MAX_HALF, "lower bound is exactly center - maxHalf");
        assertEq(hi, HALF, "upper bound is untouched");
    }

    /// Every skew that used to revert now mints, and the band never goes past the cap.
    function test_fund_skewSweep_allMint() public {
        console2.log("first fund, token1 : token0 by value");
        for (uint256 r = 1; r <= 6; r++) {
            uint256 snap = vm.snapshotState();
            hook.fund(id, BASE, r * BASE);
            (int24 lo, int24 hi,, uint128 cliq) = hook.core(id);
            assertGt(cliq, 0, "minted");
            assertGe(lo, -MAX_HALF, "never wider than the cap");
            console2.log(
                string.concat(
                    "  ratio ",
                    vm.toString(r),
                    " : 1  -> band ",
                    vm.toString(int256(lo)),
                    " .. ",
                    vm.toString(int256(hi))
                )
            );
            vm.revertToState(snap);
        }
    }

    /// The surplus the widest band cannot hold goes into the limit instead of sitting idle
    /// (issue #3), and withdraw still hands all of it back.
    function test_fund_surplusGoesToTheLimitAndComesBack() public {
        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));

        hook.fund(id, BASE, 6 * BASE);
        (int24 llo, int24 lhi,, uint128 lliq) = hook.limit(id);
        assertGt(lliq, 0, "the surplus token1 is placed");
        assertLe(lhi, poolTick(), "as a bid below the price");
        assertEq(heldByManager(llo, lhi, bytes32(uint256(2))), lliq, "and the PoolManager holds it");
        (, uint256 i1) = hookIdle();
        assertLt(i1, 1e15, "only rounding dust idle");

        hook.withdraw(id);
        assertApproxEqAbs(t0.balanceOf(address(this)), before0, 1e15, "token0 returned");
        assertApproxEqAbs(t1.balanceOf(address(this)), before1, 1e15, "token1 returned");
        (uint256 a0, uint256 a1) = hookIdle();
        assertEq(a0, 0, "nothing idle after withdraw");
        assertEq(a1, 0, "nothing idle after withdraw");
    }

    /// Both skews behave the same way now: widen to the cap, and the rest goes to the limit.
    function test_fund_bothDirectionsBehaveTheSame() public {
        uint256 snap = vm.snapshotState();

        hook.fund(id, BASE, 3 * BASE);
        (int24 loA, int24 hiA,,) = hook.core(id);
        vm.revertToState(snap);

        hook.fund(id, 3 * BASE, BASE);
        (int24 loB, int24 hiB,,) = hook.core(id);

        assertEq(loA, -MAX_HALF, "token1 surplus widens downward to the cap");
        assertEq(hiA, HALF, "and leaves the other side alone");
        assertEq(hiB, MAX_HALF, "token0 surplus widens upward to the cap");
        assertEq(loB, -HALF, "and leaves the other side alone");
    }

    // ---------- recentering after a rise

    /// The sweep that used to revert from +1000 onward.
    function test_recenter_afterARise_nowSucceeds() public {
        console2.log("price pushed up by N ticks, then recenter");
        int24[6] memory moves = [int24(600), 800, 1000, 1100, 1200, 1500];
        for (uint256 i = 0; i < moves.length; i++) {
            uint256 snap = vm.snapshotState();
            hook.fund(id, BASE, BASE);
            pushPoolToTick(moves[i]);
            setOracleTick(poolTick());
            t0.transfer(HOOK_ADDR, DUST);

            hook.recenter(id);
            (int24 lo, int24 hi,, uint128 cliq) = hook.core(id);
            console2.log(
                string.concat(
                    "  +",
                    vm.toString(int256(moves[i])),
                    " ticks -> band ",
                    vm.toString(int256(lo)),
                    " .. ",
                    vm.toString(int256(hi)),
                    "  liquidity ",
                    vm.toString(uint256(cliq))
                )
            );
            vm.revertToState(snap);
        }
    }

    /// The exact case from the proof: every gate passes and it no longer reverts.
    function test_recenter_revertsNoLongerWhileEveryGatePasses() public {
        hook.fund(id, BASE, BASE);
        pushPoolToTick(1200);
        setOracleTick(poolTick());
        t0.transfer(HOOK_ADDR, DUST);

        (,, int24 center,) = hook.core(id);
        assertGt(absDiff(poolTick(), center), 500, "drift is past the trigger");

        hook.recenter(id);
        (int24 lo,, int24 newCenter, uint128 cliq) = hook.core(id);
        assertEq(newCenter, poolTick(), "recentred on the oracle");
        assertGe(lo, newCenter - MAX_HALF, "never wider than the cap");
        assertGt(cliq, 0, "and it placed something");
    }

    /// No regression in the direction that already worked.
    function test_recenter_mirrorDirectionStillWorks() public {
        hook.fund(id, BASE, BASE);
        pushPoolToTick(-1200);
        setOracleTick(poolTick());
        t1.transfer(HOOK_ADDR, DUST);

        hook.recenter(id);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "the mirror direction still places liquidity");
    }

    /// Audit finding R1. With exactly zero of the scarce token the core can place nothing. Part
    /// one refused the recentre; part two (issue #3) places the held token as a one-sided limit,
    /// so the recentre goes through and nothing is stranded.
    function test_recenter_withoutDust_placesTheHeldTokenAsALimit() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);

        pushPoolToTick(1200);
        setOracleTick(poolTick());

        (uint256 i0,) = hookIdle();
        assertEq(i0, 0, "no dust of the scarce token");

        hook.recenter(id);

        (,,, uint128 cliq) = hook.core(id);
        (int24 llo, int24 lhi,, uint128 lliq) = hook.limit(id);
        assertEq(cliq, 0, "no token0, so no two-sided core");
        assertGt(lliq, 0, "the token1 went into the limit");
        assertLe(lhi, poolTick(), "as a bid below the price");
        assertEq(heldByManager(lo, hi, bytes32(0)), 0, "the old core was burned");
        assertEq(heldByManager(llo, lhi, bytes32(uint256(2))), lliq, "and the PoolManager holds the limit");
    }
}
