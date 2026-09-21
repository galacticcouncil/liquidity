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

/// The hook must never burn a position it cannot replace. Audit finding R1, part one:
/// once the price has left the band the held token alone yields zero liquidity, and the
/// burn would move the whole book to idle with no way to put it back.
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

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));
    bytes32 constant CORE_SALT = bytes32(0);
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

    function heldByManager(int24 lower, int24 upper) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, CORE_SALT);
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

    // ---------- the refusal

    /// The price rises clear of the band, so the core is all token1 and the re-mint would
    /// place nothing. The recentre is refused and the position survives untouched.
    function test_recenterUpward_isRefused_andNothingIsStranded() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,, uint128 liqBefore) = hook.core(id);

        _moveBothTo(1200);

        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.recenter(id);

        (,,, uint128 liqAfter) = hook.core(id);
        assertEq(liqAfter, liqBefore, "record untouched");
        assertEq(heldByManager(lo, hi), liqBefore, "the burn was rolled back");
        (uint256 i0, uint256 i1) = hookIdle();
        assertEq(i0, 0, "nothing went idle");
        assertEq(i1, 0, "nothing went idle");
    }

    /// The mirror direction: the price falls clear of the band, the core is all token0.
    function test_recenterDownward_isRefused() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,, uint128 liqBefore) = hook.core(id);

        _moveBothTo(-1200);

        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.recenter(id);

        assertEq(heldByManager(lo, hi), liqBefore, "the burn was rolled back");
    }

    /// The whole point of part one: the position stays in the pool rather than becoming
    /// idle, so the PoolManager's own view of it is unchanged by the failed attempt.
    function test_theBurnIsRolledBack_notJustTheRecord() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,,) = hook.core(id);
        uint128 managerBefore = heldByManager(lo, hi);

        _moveBothTo(1200);
        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.recenter(id);

        assertEq(heldByManager(lo, hi), managerBefore, "the PoolManager still holds it");
        assertGt(managerBefore, 0, "and it was a real position");
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

    /// Sweep the distance to find where the refusal starts, rather than assuming it.
    function test_refusalBoundarySweep() public {
        console2.log("both pool and oracle moved N ticks, band half-width 1000");
        int24[6] memory moves = [int24(600), 900, 1000, 1100, 1200, 1500];
        for (uint256 i = 0; i < moves.length; i++) {
            uint256 snap = vm.snapshotState();
            hook.fund(id, BASE, BASE);
            _moveBothTo(moves[i]);
            try hook.recenter(id) {
                (,,, uint128 cliq) = hook.core(id);
                console2.log(
                    string.concat(
                        "  +",
                        vm.toString(int256(moves[i])),
                        " -> recentred, liquidity ",
                        vm.toString(uint256(cliq))
                    )
                );
            } catch (bytes memory err) {
                console2.log(
                    string.concat("  +", vm.toString(int256(moves[i])), " -> refused ", vm.toString(bytes4(err)))
                );
            }
            vm.revertToState(snap);
        }
    }

    // ---------- the repair path

    /// After a refusal the owner can fund the missing token and the pool recovers.
    function test_fundingTheMissingTokenRepairsIt() public {
        hook.fund(id, BASE, BASE);
        _moveBothTo(1200);

        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.recenter(id);

        // the core is all token1, so add token0 and the band can be placed again
        hook.fund(id, BASE, 0);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "the repair placed a real band");
    }

    /// A fund that would itself place nothing is refused too, rather than burning the
    /// live position and stranding everything.
    function test_fundThatWouldPlaceNothing_isAlsoRefused() public {
        hook.fund(id, BASE, BASE);
        (int24 lo, int24 hi,, uint128 liqBefore) = hook.core(id);
        _moveBothTo(1200);

        // adding more of the token the hook already holds cannot make a two-sided band
        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.fund(id, 0, BASE);

        assertEq(heldByManager(lo, hi), liqBefore, "the live position survived");
    }

    /// Withdraw is the escape hatch and must keep working after a refusal.
    function test_withdrawStillWorksAfterARefusal() public {
        hook.fund(id, BASE, BASE);
        _moveBothTo(1200);

        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.recenter(id);

        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        hook.withdraw(id);
        assertGt(t0.balanceOf(address(this)) + t1.balanceOf(address(this)), before0 + before1, "funds came back");
        (,,, uint128 cliq) = hook.core(id);
        assertEq(cliq, 0, "position closed");
    }
}
