// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The gaps the independent code review listed: both band edges and just inside them (with the
// blind pass's F6), native pay-in, running out of gas inside the attempt, a failure that repeats,
// the manager check, `setParams` and the switch, two swaps in one unlock.
// Written by Claude at Yash's request (2026-09-23).

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {FalseReturningERC20} from "./mocks/NonStandardERC20.sol";
import {GasGuzzlerERC20} from "./mocks/AfterSwapMocks.sol";
import {Sandwicher} from "./BandHookSandwich.t.sol";

interface ITok {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract BandHookAfterSwapReviewTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    bytes32 constant RECENTERED = keccak256("Recentered(bytes32,int24,int24,int24,uint128)");
    bytes32 constant SKIPPED = keccak256("RecenterSkipped(bytes32,bytes4)");

    IPoolManager manager;
    PoolSwapTest pusher;
    MockPriceSource source;
    BandHook hook;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pusher = new PoolSwapTest(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
    }

    // ---------- gaps 1 and 2, and blind pass F6: both band edges, and just inside them

    /// Token1 is the scarce side at funding, so none of it stays idle; the oracle sits 100 ticks
    /// above the lower edge, so the recenter is due and the edge is inside the guard. The pool is
    /// then parked 50 ticks below the edge with the switch off, where the band holds only token0.
    function _lowerEdgeSetup() internal returns (PoolKey memory k, PoolId i, int24 lo) {
        (address a, address b) = _twoTokens();
        (k, i) = _pool(a, b);
        hook.fund(i, FUND * 3 / 2, FUND);
        assertEq(ITok(b).balanceOf(HOOK_ADDR), 0, "no token1 left idle");
        (lo,,,) = hook.core(i);
        source.set(_price(lo + 100), block.timestamp);
        hook.setAutoRecenter(i, false);
        _swapTo(k, TickMath.getSqrtPriceAtTick(lo - 50));
        hook.setAutoRecenter(i, true);
    }

    /// The mirror: token0 scarce, the oracle 100 ticks below the upper edge, the pool parked 50
    /// ticks above it, where the band holds only token1.
    function _upperEdgeSetup() internal returns (PoolKey memory k, PoolId i, int24 hi) {
        (address a, address b) = _twoTokens();
        (k, i) = _pool(a, b);
        hook.fund(i, FUND, FUND * 3 / 2);
        assertEq(ITok(a).balanceOf(HOOK_ADDR), 0, "no token0 left idle");
        (, hi,,) = hook.core(i);
        source.set(_price(hi - 100), block.timestamp);
        hook.setAutoRecenter(i, false);
        _swapTo(k, TickMath.getSqrtPriceAtTick(hi + 50));
        hook.setAutoRecenter(i, true);
    }

    /// Before issue #3 a recenter here placed almost nothing, so the in-swap path refused it up
    /// front. Now what the core cannot hold goes into the limit, and the swap recenters the same
    /// way the manual path does.
    function test_lowerEdge_halfATickInside_recentersLikeTheManualPath() public {
        (PoolKey memory k, PoolId i, int24 lo) = _lowerEdgeSetup();
        uint160 half = uint160((uint256(TickMath.getSqrtPriceAtTick(lo)) + TickMath.getSqrtPriceAtTick(lo + 1)) / 2);
        _assertInSwapMatchesManual(k, i, half);
        (, int24 tick,,) = manager.getSlot0(i);
        assertEq(tick, lo, "the tick names the edge");
    }

    function test_lowerEdge_exactlyOnItFromAbove_recentersLikeTheManualPath() public {
        (PoolKey memory k, PoolId i, int24 lo) = _lowerEdgeSetup();
        hook.setAutoRecenter(i, false);
        _swapTo(k, TickMath.getSqrtPriceAtTick(lo + 50));
        hook.setAutoRecenter(i, true);
        _assertInSwapMatchesManual(k, i, TickMath.getSqrtPriceAtTick(lo));
        (, int24 tick,,) = manager.getSlot0(i);
        assertEq(tick, lo - 1, "a downward stop on a tick reports the tick below");
    }

    function test_lowerEdge_exactlyOnItFromBelow_recentersLikeTheManualPath() public {
        (PoolKey memory k, PoolId i, int24 lo) = _lowerEdgeSetup();
        _assertInSwapMatchesManual(k, i, TickMath.getSqrtPriceAtTick(lo));
        (, int24 tick,,) = manager.getSlot0(i);
        assertEq(tick, lo, "an upward stop on a tick reports the tick itself");
    }

    function test_upperEdge_halfATickInside_recentersLikeTheManualPath() public {
        (PoolKey memory k, PoolId i, int24 hi) = _upperEdgeSetup();
        uint160 half = uint160((uint256(TickMath.getSqrtPriceAtTick(hi - 1)) + TickMath.getSqrtPriceAtTick(hi)) / 2);
        _assertInSwapMatchesManual(k, i, half);
        (, int24 tick,,) = manager.getSlot0(i);
        assertEq(tick, hi - 1);
    }

    /// Blind pass F6: stopping exactly on the upper edge from above reports the tick below it, so
    /// a tick test reads "inside the band" while the band holds only token1. The recenter leaves
    /// no core and a bid holding the token1.
    function test_upperEdge_exactlyOnItFromAbove_recentersLikeTheManualPath() public {
        (PoolKey memory k, PoolId i, int24 hi) = _upperEdgeSetup();
        _assertInSwapMatchesManual(k, i, TickMath.getSqrtPriceAtTick(hi));
        (, int24 tick,,) = manager.getSlot0(i);
        assertEq(tick, hi - 1, "v4 reports the tick below the edge");
        (,,, uint128 coreLiq) = hook.core(i);
        (,,, uint128 limLiq) = hook.limit(i);
        assertEq(coreLiq, 0, "no token0, so no core");
        assertGt(limLiq, 0, "a bid holds the token1");
    }

    /// Was a known limit before issue #3 (audit R1 part two): a few ticks inside the edge the band
    /// holds only a little of the scarce token, so the new core is thin. The rest used to wait
    /// idle; now the limit holds it.
    function test_aFewTicksInsideTheEdge_theCoreIsThin_andTheLimitHoldsTheRest() public {
        (PoolKey memory k, PoolId i, int24 lo) = _lowerEdgeSetup();
        (,,, uint128 liq) = hook.core(i);
        _assertInSwapMatchesManual(k, i, TickMath.getSqrtPriceAtTick(lo + 5));
        (,,, uint128 coreLiq) = hook.core(i);
        (,,, uint128 limLiq) = hook.limit(i);
        assertLt(uint256(coreLiq) * 20, liq, "the new core keeps under 5% of the old one's liquidity");
        assertGt(limLiq, 0, "the limit holds the rest");
    }

    /// Swap to `target` with the switch on, then again from the same state with the switch off
    /// followed by the manual recenter. Both must leave the same core and limit, and the hook
    /// must be left holding no more than rounding dust.
    function _assertInSwapMatchesManual(PoolKey memory k, PoolId i, uint160 target) internal {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _swapTo(k, target);
        (uint256 fired,) = _events(RECENTERED);
        assertEq(fired, 1, "recentered inside the swap");
        bytes32 inSwap = _records(i);
        vm.revertToState(snap);

        hook.setAutoRecenter(i, false);
        _swapTo(k, target);
        hook.recenter(i);
        assertEq(_records(i), inSwap, "the same core and limit as the manual recenter");
        assertLt(ITok(Currency.unwrap(k.currency0)).balanceOf(HOOK_ADDR), 1e15, "no token0 left idle");
        assertLt(ITok(Currency.unwrap(k.currency1)).balanceOf(HOOK_ADDR), 1e15, "no token1 left idle");
    }

    // ---------- gap 3: the hook pays ETH in during a swap

    function test_nativePool_theHookPaysEthInDuringTheSwap() public {
        vm.deal(address(this), 1_000_000 ether);
        (address b,) = _twoTokens();
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(b),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        PoolId i = k.toId();
        hook.configure(k, _cfg());
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        hook.fund{value: FUND}(i, FUND, FUND);
        (bool sent,) = HOOK_ADDR.call{value: FUND / 5}(""); // spare ETH the re-mint will want
        require(sent);
        uint256 ethBefore = HOOK_ADDR.balance;

        source.set(1.04e18, block.timestamp);
        vm.recordLogs();
        _swapTo(k, TickMath.getSqrtPriceAtTick(392)); // buys ETH: the old band is short of ETH after this
        (uint256 fired,) = _events(RECENTERED);
        assertEq(fired, 1);
        assertLt(HOOK_ADDR.balance, ethBefore, "spare ETH went into the new band, paid in during the swap");
    }

    // ---------- gap 4: running out of gas inside the attempt

    function test_runningOutOfGasInsideTheAttempt_isUndoneAndTheSwapGoesThrough() public {
        GasGuzzlerERC20 x = new GasGuzzlerERC20("GA", "GA");
        GasGuzzlerERC20 y = new GasGuzzlerERC20("GB", "GB");
        (address a, address b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        _setUpToken(a);
        _setUpToken(b);
        (PoolKey memory k, PoolId i) = _pool(a, b);
        hook.fund(i, FUND, FUND);
        _giveSpare(a, b); // so the recenter pays in, which is where the token burns the gas
        bytes32 before = _records(i);
        GasGuzzlerERC20(a).watch(HOOK_ADDR, address(manager));
        GasGuzzlerERC20(b).watch(HOOK_ADDR, address(manager));

        source.set(1.04e18, block.timestamp);
        vm.recordLogs();
        uint256 g = gasleft();
        _swapTo(k, TickMath.getSqrtPriceAtTick(392));
        uint256 used = g - gasleft();
        (uint256 skipped, bytes memory data) = _events(SKIPPED);
        assertEq(skipped, 1, "attempted and undone");
        // Where the gas runs out decides the reason: in the token (the hook then fails with its
        // own error, from the 1/64 of gas a call always keeps back) or in the hook (no reason).
        bytes4 reason = abi.decode(data, (bytes4));
        assertTrue(reason == BandHook.TransferFailed.selector || reason == bytes4(0), "either way");
        assertEq(_records(i), before, "nothing moved");
        emit log_named_uint("gas of the swap whose recenter ran dry", used);
        assertLt(used, 1_250_000, "capped by RECENTER_MAX_GAS plus the swap itself");
    }

    // ---------- gap 5: a failure that persists is tried again on every due swap

    function test_aPersistentFailure_isTriedAgainOnTheNextDueSwap_untilTheOwnerSwitchesOff() public {
        FalseReturningERC20 x = new FalseReturningERC20("FA", "FA");
        FalseReturningERC20 y = new FalseReturningERC20("FB", "FB");
        (address a, address b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        _setUpToken(a);
        _setUpToken(b);
        (PoolKey memory k, PoolId i) = _pool(a, b);
        hook.fund(i, FUND, FUND);
        _giveSpare(a, b);
        FalseReturningERC20(a).setFailTransferTo(address(manager));
        FalseReturningERC20(b).setFailTransferTo(address(manager));
        source.set(1.04e18, block.timestamp);

        vm.recordLogs();
        _swapTo(k, TickMath.getSqrtPriceAtTick(392));
        _nudge(k);
        (uint256 skipped,) = _events(SKIPPED);
        assertEq(skipped, 2, "each due swap tries again and pays for it");

        hook.setAutoRecenter(i, false);
        vm.recordLogs();
        _nudge(k);
        (skipped,) = _events(SKIPPED);
        assertEq(skipped, 0, "the owner's switch stops it");
    }

    // ---------- gap 6: only the PoolManager may call afterSwap

    function test_afterSwap_refusesAnyCallerButTheManager() public {
        (address a, address b) = _twoTokens();
        (PoolKey memory k,) = _pool(a, b);
        vm.expectRevert(BandHook.NotManager.selector);
        hook.afterSwap(
            address(this),
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            BalanceDelta.wrap(0),
            ""
        );
    }

    // ---------- gap 7: setParams leaves the switch alone

    function test_setParams_doesNotChangeTheSwitch() public {
        (address a, address b) = _twoTokens();
        (, PoolId i) = _pool(a, b);
        hook.setAutoRecenter(i, false);
        BandHook.PoolConfig memory c = _cfg();
        c.autoRecenter = true;
        c.feeFloor = 900;
        hook.setParams(i, c);
        (, uint24 floorFee,,,,,,,,,, bool autoOn) = hook.config(i);
        assertEq(floorFee, 900, "the other fields changed");
        assertFalse(autoOn, "the switch did not");

        hook.setAutoRecenter(i, true);
        c.autoRecenter = false;
        hook.setParams(i, c);
        (,,,,,,,,,,, autoOn) = hook.config(i);
        assertTrue(autoOn, "nor the other way round");
    }

    // ---------- gap 8: two swaps on the pool in one unlock

    function test_twoSwapsInOneUnlock_recenterOnceThenNotDue() public {
        (address a, address b) = _twoTokens();
        (PoolKey memory k, PoolId i) = _pool(a, b);
        hook.fund(i, FUND, FUND);
        Sandwicher sw = new Sandwicher(manager);
        ITok(a).mint(address(sw), 100_000_000e18);
        ITok(b).mint(address(sw), 100_000_000e18);
        source.set(1.04e18, block.timestamp);

        vm.recordLogs();
        sw.run(k, 450, 392); // up past the oracle, back to it, one unlock
        (uint256 fired,) = _events(RECENTERED);
        assertEq(fired, 1, "the first swap recentered; the second found nothing due");
        (,, int24 c,) = hook.core(i);
        assertEq(c, 392);
    }

    // ---------- helpers

    function _cfg() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: 800,
            feeCap: 10_000,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 700,
            backstopHalfTicks: 11_000,
            backstopBps: 3500,
            triggerTicks: 350,
            guardTicks: 200,
            enabled: true,
            autoRecenter: true
        });
    }

    function _twoTokens() internal returns (address a, address b) {
        MockERC20 x = new MockERC20("A", "A", 18);
        MockERC20 y = new MockERC20("B", "B", 18);
        (a, b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        _setUpToken(a);
        _setUpToken(b);
    }

    function _setUpToken(address t) internal {
        ITok(t).mint(address(this), 100_000_000e18);
        ITok(t).approve(address(hook), type(uint256).max);
        ITok(t).approve(address(pusher), type(uint256).max);
    }

    function _pool(address a, address b) internal returns (PoolKey memory k, PoolId i) {
        k = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        i = k.toId();
        hook.configure(k, _cfg());
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    /// Swap to an exact price, in whichever direction it lies.
    function _swapTo(PoolKey memory k, uint160 target) internal {
        (uint160 now_,,,) = manager.getSlot0(k.toId());
        bool up = target > now_;
        pusher.swap(
            k,
            SwapParams({zeroForOne: !up, amountSpecified: -1e30, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _nudge(PoolKey memory k) internal {
        pusher.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _price(int24 tick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        return (s * s >> 96) * 1e18 >> 96;
    }

    /// Spare tokens in the hook: the next recenter places them, so it pays the PoolManager in.
    /// Since issue #3 a recenter otherwise places everything it burned and moves only dust.
    function _giveSpare(address a, address b) internal {
        ITok(a).transfer(HOOK_ADDR, FUND / 5);
        ITok(b).transfer(HOOK_ADDR, FUND / 5);
    }

    /// Both position records, hashed, to check in one line that nothing moved.
    function _records(PoolId i) internal view returns (bytes32) {
        (int24 lo, int24 hi, int24 c, uint128 liq) = hook.core(i);
        (int24 limLo, int24 limHi, int24 limC, uint128 limLiq) = hook.limit(i);
        return keccak256(abi.encode(lo, hi, c, liq, limLo, limHi, limC, limLiq));
    }

    function _events(bytes32 topic) internal view returns (uint256 n, bytes memory last) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].emitter == HOOK_ADDR && logs[j].topics[0] == topic) {
                n++;
                last = logs[j].data;
            }
        }
    }
}
