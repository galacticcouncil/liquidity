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

/// The hook must never burn a position it cannot replace. Audit finding R1: once the price has
/// left the band the held token alone makes no two-sided liquidity, and the burn would move the
/// whole book to idle. Part one refused such a recentre; issue #3 places the held token as a
/// one-sided limit instead, so every burn is replaced and nothing is stranded.
contract BandHookEmptyBandTest is Test {
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
    bytes32 constant CORE_SALT = bytes32(0);
    bytes32 constant LIMIT_SALT = bytes32(uint256(2));
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

    function heldByManager(int24 lower, int24 upper) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, CORE_SALT);
    }

    function heldAsLimit(int24 lower, int24 upper) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, LIMIT_SALT);
    }

    function hookIdle() internal view returns (uint256 i0, uint256 i1) {
        return (t0.balanceOf(HOOK_ADDR), t1.balanceOf(HOOK_ADDR));
    }

    /// Put the pool `ticks` away from the band and move the oracle with it, so every
    /// recenter gate passes and only the placement decides the outcome.
    function _moveBothTo(int24 target) internal {
        pushPoolToTick(target);
        setOracleTick(poolTick());
    }

    // ---------- a full exit is placed, not refused

    /// The price rises clear of the band, so the core is all token1. The recentre places that
    /// token1 as a bid below the price: the old band is gone, the new one is live, nothing idle.
    function test_recenterUpward_placesTheHeldToken_andNothingIsStranded() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);

        _moveBothTo(1200);
        hook.recenter(id);

        (int24 llo, int24 lhi,, uint128 lliq) = hook.limit(id);
        assertGt(lliq, 0, "the token1 is placed");
        assertLe(lhi, poolTick(), "as a bid below the price");
        assertEq(heldByManager(lo, hi), 0, "the old band was burned");
        assertEq(heldAsLimit(llo, lhi), lliq, "and the PoolManager holds the new one");
        (uint256 i0, uint256 i1) = hookIdle();
        assertEq(i0, 0, "no token0 idle");
        assertLt(i1, 1e15, "only rounding dust of token1 idle");
    }

    /// The mirror direction: the price falls clear of the band, the core is all token0, and
    /// the recentre places it as an ask above the price.
    function test_recenterDownward_placesTheHeldToken() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);

        _moveBothTo(-1200);
        hook.recenter(id);

        (int24 llo, int24 lhi,, uint128 lliq) = hook.limit(id);
        assertGt(lliq, 0, "the token0 is placed");
        assertGt(llo, poolTick(), "as an ask above the price");
        assertEq(heldByManager(lo, hi), 0, "the old band was burned");
        assertEq(heldAsLimit(llo, lhi), lliq, "and the PoolManager holds the new one");
    }

    /// The whole point, restated: after a full-exit recentre the PoolManager holds exactly what
    /// the records say - nothing at the old band, the core and the limit as recorded - so no
    /// liquidity exists that no call can reach.
    function test_theRecordsMatchWhatThePoolManagerHolds() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);
        assertGt(heldByManager(lo, hi), 0, "a real position to begin with");

        _moveBothTo(1200);
        hook.recenter(id);

        (int24 clo, int24 chi,, uint128 cliq) = hook.core(id);
        (int24 llo, int24 lhi,, uint128 lliq) = hook.limit(id);
        assertEq(heldByManager(lo, hi), 0, "nothing left at the old band");
        assertEq(heldByManager(clo, chi), cliq, "the core record matches");
        assertEq(heldAsLimit(llo, lhi), lliq, "the limit record matches");
    }

    // ---------- what still works

    /// With a dust amount of the scarce token the re-mint places something, so the
    /// recentre goes ahead. No regression on the H3 fix.
    function test_withDust_theRecentreStillHappens() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);

        _moveBothTo(1200);
        t0.transfer(HOOK_ADDR, DUST);

        hook.recenter(id);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "placed something");
        assertEq(heldByManager(lo, hi), 0, "the old band was burned");
    }

    /// An ordinary recentre, well inside the band, is untouched by the check.
    function test_ordinaryRecentre_isUnaffected() public {
        hook.fund(id, BASE, BASE);
        _moveBothTo(600);

        hook.recenter(id);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "recentred normally");
    }

    /// The distances that used to find where the refusal started. Every one of them now
    /// recentres, and the hook keeps only rounding dust idle.
    function test_everyDistanceRecentres_nothingIdle() public {
        int24[6] memory moves = [int24(600), 900, 1000, 1100, 1200, 1500];
        for (uint256 i = 0; i < moves.length; i++) {
            uint256 snap = vm.snapshotState();
            hook.fund(id, BASE, BASE);
            _moveBothTo(moves[i]);
            hook.recenter(id);
            (uint256 i0, uint256 i1) = hookIdle();
            assertLt(i0, 1e15, "only rounding dust of token0 idle");
            assertLt(i1, 1e15, "only rounding dust of token1 idle");
            vm.revertToState(snap);
        }
    }

    // ---------- after an exit

    /// After a full exit the hook quotes one way. Funding the missing token makes the core
    /// two-sided again, straddling the price.
    function test_fundingTheMissingTokenMakesTheCoreTwoSided() public {
        hook.fund(id, BASE, BASE);
        _moveBothTo(1200);
        hook.recenter(id);
        (,,, uint128 before) = hook.core(id);
        assertEq(before, 0, "one-sided after the exit");

        hook.fund(id, BASE, 0);
        (int24 clo, int24 chi,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "two-sided again");
        assertTrue(clo < poolTick() && poolTick() < chi, "the core straddles the price");
    }

    /// Adding more of the token the hook already holds cannot make a two-sided band, and no
    /// longer has to: the fund goes through, the old core is burned, and all of it is placed.
    function test_fundOfTheHeldTokenAfterAnExit_isPlacedInTheLimit() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);
        _moveBothTo(1200);

        hook.fund(id, 0, BASE);

        (,,, uint128 cliq) = hook.core(id);
        (int24 llo, int24 lhi,, uint128 lliq) = hook.limit(id);
        assertEq(cliq, 0, "still no token0, so no core");
        assertGt(lliq, 0, "the old core's token1 and the new token1 are in the limit");
        assertEq(heldByManager(lo, hi), 0, "the old band was burned, not stranded");
        assertEq(heldAsLimit(llo, lhi), lliq, "and the PoolManager holds the limit");
    }

    /// Withdraw is the escape hatch and still returns everything after a full exit, limit included.
    function test_withdrawAfterAnExit_returnsEverything() public {
        hook.fund(id, BASE, BASE);
        _moveBothTo(1200);
        hook.recenter(id);

        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        hook.withdraw(id);
        assertGt(t0.balanceOf(address(this)) + t1.balanceOf(address(this)), before0 + before1, "funds came back");
        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 lliq) = hook.limit(id);
        assertEq(cliq, 0, "core closed");
        assertEq(lliq, 0, "limit closed");
        (uint256 i0, uint256 i1) = hookIdle();
        assertEq(i0 + i1, 0, "nothing left in the hook");
    }
}
