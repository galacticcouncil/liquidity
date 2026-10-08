// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The sandwich around a recenter (blind pass F5), measured. Inside one unlock an attacker pushes the
// pool to the edge of the guard, lets the recenter happen at that price, and trades back. Profit is
// valued at the oracle price. Compared with the same two trades and no recenter, and with the manual
// path (three separate transactions). Written by Claude at Yash's request (2026-09-23).

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Swaps to `pushTick`, then back to `unwindTick`, in one unlock; either leg is skipped when its
/// target equals the current tick. Pays or collects the net at the end from its own balance.
contract Sandwicher is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolKey internal key;

    constructor(IPoolManager m) {
        manager = m;
    }

    function run(PoolKey calldata k, int24 pushTick, int24 unwindTick) external {
        key = k;
        manager.unlock(abi.encode(pushTick, unwindTick));
    }

    function unlockCallback(bytes calldata d) external returns (bytes memory) {
        (int24 pushTick, int24 unwindTick) = abi.decode(d, (int24, int24));
        _swapTo(pushTick);
        _swapTo(unwindTick);
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _swapTo(int24 target) internal {
        (, int24 t,,) = manager.getSlot0(key.toId());
        if (target == t) return;
        bool up = target > t;
        manager.swap(
            key,
            SwapParams({zeroForOne: !up, amountSpecified: -1e36, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)}),
            ""
        );
    }

    function _settle(Currency c) internal {
        int256 delta = manager.currencyDelta(address(this), c);
        if (delta < 0) {
            manager.sync(c);
            MockERC20(Currency.unwrap(c)).transfer(address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(delta));
        }
    }
}

contract BandHookSandwichTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18; // 200k of value at price 1
    bytes32 constant RECENTERED = keccak256("Recentered(bytes32,int24,int24,int24,uint128)");

    IPoolManager manager;
    PoolSwapTest pusher;
    MockPriceSource source;
    BandHook hook;
    MockERC20 t0;
    MockERC20 t1;
    Sandwicher sw;
    PoolKey key;
    PoolId id;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pusher = new PoolSwapTest(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        sw = new Sandwicher(manager);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 t = i == 0 ? t0 : t1;
            t.mint(address(this), 100_000_000e18);
            t.mint(address(sw), 100_000_000e18);
            t.approve(address(hook), type(uint256).max);
            t.approve(address(pusher), type(uint256).max);
        }
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
    }

    function _cfg(int24 guard, bool autoOn) internal view returns (BandHook.PoolConfig memory) {
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
            guardTicks: guard,
            enabled: true,
            autoRecenter: autoOn
        });
    }

    /// Fund at tick 0, move the oracle to `oraclePrice`, let arbitrage (switch off) bring the pool to
    /// `startTick`, and optionally leave spare tokens in the hook, so the recenter is due for
    /// whoever trades next.
    function _stage(int24 guard, bool autoOn, uint256 oraclePrice, int24 startTick, uint256 idle0, uint256 idle1)
        internal
    {
        hook.configure(key, _cfg(guard, false));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.fund(id, FUND, FUND);
        source.set(oraclePrice, block.timestamp);
        pusher.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1e36, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(startTick)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        if (idle0 > 0) t0.transfer(HOOK_ADDR, idle0);
        if (idle1 > 0) t1.transfer(HOOK_ADDR, idle1);
        if (autoOn) hook.setAutoRecenter(id, true);
    }

    /// Whether the hook emitted `Recentered` since the logs were last read. The core's centre is
    /// not enough: since issue #3 a recenter past the band leaves an empty core and a bid.
    function _recentered() internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].emitter == HOOK_ADDR && logs[j].topics[0] == RECENTERED) return true;
        }
        return false;
    }

    /// Where the last recenter centred what it placed: the core when it has one, else the limit.
    function _placedCentre() internal view returns (int24) {
        (,, int24 c, uint128 liq) = hook.core(id);
        if (liq > 0) return c;
        (,, int24 limC,) = hook.limit(id);
        return limC;
    }

    /// Value in token1 at the oracle price.
    function _value(address who, uint256 oraclePrice) internal view returns (int256) {
        return int256(t0.balanceOf(who) * oraclePrice / 1e18 + t1.balanceOf(who));
    }

    struct Case {
        string label;
        int24 guard;
        uint256 oraclePrice;
        int24 oracleTick;
        int24 startTick;
        int24 pushTo;
        int24 unwindTo;
        uint256 idle0;
        uint256 idle1;
    }

    /// Attacker's profit, per 1M of pool value, for: in-swap recenter, no recenter, manual recenter.
    function _run(Case memory k) internal returns (int256 inSwap, int256 none, int256 manual, bool firedOnPush) {
        uint256 snap = vm.snapshotState();

        _stage(k.guard, true, k.oraclePrice, k.startTick, k.idle0, k.idle1);
        int256 v0 = _value(address(sw), k.oraclePrice);
        vm.recordLogs();
        sw.run(key, k.pushTo, k.pushTo); // push only, to see whether the recenter fired on it
        firedOnPush = _recentered();
        if (firedOnPush) assertEq(_placedCentre(), k.oracleTick, "placed around the oracle, not the pushed price");
        (, int24 t0_,,) = manager.getSlot0(id);
        sw.run(key, t0_, k.unwindTo); // then the unwind (inside one unlock or two: same prices)
        inSwap = (_value(address(sw), k.oraclePrice) - v0) * 5;
        vm.revertToState(snap);

        _stage(k.guard, false, k.oraclePrice, k.startTick, k.idle0, k.idle1);
        v0 = _value(address(sw), k.oraclePrice);
        sw.run(key, k.pushTo, k.unwindTo);
        none = (_value(address(sw), k.oraclePrice) - v0) * 5;
        vm.revertToState(snap);

        _stage(k.guard, false, k.oraclePrice, k.startTick, k.idle0, k.idle1);
        v0 = _value(address(sw), k.oraclePrice);
        sw.run(key, k.pushTo, k.pushTo); // push only
        try hook.recenter(id) {} catch {} // when refused here, a later one cannot touch this attack's prices
        (, int24 t,,) = manager.getSlot0(id);
        sw.run(key, t, k.unwindTo); // unwind only
        manual = (_value(address(sw), k.oraclePrice) - v0) * 5;
        vm.revertToState(snap);
    }

    function _row(Case memory k) internal {
        (int256 a, int256 b, int256 m, bool fired) = _run(k);
        emit log_string(string.concat(k.label, fired ? "  [recentered on the push]" : "  [not on the push]"));
        emit log_named_decimal_int("  attacker profit per 1M, in-swap recenter", a, 18);
        emit log_named_decimal_int("  attacker profit per 1M, no recenter", b, 18);
        emit log_named_decimal_int("  attacker profit per 1M, manual recenter", m, 18);
        emit log_named_decimal_int("  what the recenter adds", a - b, 18);
        assertEq(a, m, "in-swap and manual recenter give the attacker the same result");
    }

    function _c(string memory l, int24 g, uint256 p, int24 ot, int24 st, int24 pu, int24 un, uint256 i0, uint256 i1)
        internal
        pure
        returns (Case memory)
    {
        return Case(l, g, p, ot, st, pu, un, i0, i1);
    }

    /// Market up 4%, old band still around the price, pool already at the oracle. Guard 200 is the
    /// ETH/HOLLAR launch value; 300 is the HDX pools' value, shown on the same pool for scale. Issue
    /// #2 refuses anything at or under 161 here, so the old 150 rows are gone.
    function test_sandwich_typical() public {
        _row(_c("4%, guard 200: push +200, unwind to +100", 200, 1.04e18, 392, 392, 592, 492, 0, 0));
        _row(_c("4%, guard 200: push +200, unwind to +120", 200, 1.04e18, 392, 392, 592, 512, 0, 0));
        _row(_c("4%, guard 200: push +200, unwind to oracle", 200, 1.04e18, 392, 392, 592, 392, 0, 0));
        _row(_c("4%, guard 200: start -100, push +200, unwind to +100", 200, 1.04e18, 392, 292, 592, 492, 0, 0));
        _row(_c("4%, guard 200: push -200, unwind to -100", 200, 1.04e18, 392, 392, 192, 292, 0, 0));
        _row(_c("4%, guard 300: push +300, unwind to +150", 300, 1.04e18, 392, 392, 692, 542, 0, 0));
        _row(_c("4%, guard 300: push +300, unwind to oracle", 300, 1.04e18, 392, 392, 692, 392, 0, 0));
    }

    /// The blind pass's profitable case: the market has left the old band (+8%, the band is +-700),
    /// so the push only meets the thin backstop, and the hook holds spare tokens of both kinds, so
    /// the re-mint can be two-sided and deep.
    function test_sandwich_pastTheBand_withSpareTokens() public {
        _row(_c("8%, guard 200, spare 10k+10k: push +200, unwind to +100", 200, 1.08e18, 769, 769, 969, 869, 10_000e18, 10_000e18));
        _row(_c("8%, guard 200, spare 30k+30k: push +200, unwind to +100", 200, 1.08e18, 769, 769, 969, 869, 30_000e18, 30_000e18));
        _row(_c("8%, guard 200, spare 10k+10k: push -200, unwind to -100", 200, 1.08e18, 769, 769, 569, 669, 10_000e18, 10_000e18));
        _row(_c("6%, guard 200, no spare: push +200, unwind to +100", 200, 1.06e18, 582, 582, 782, 682, 0, 0));
        _row(_c("8%, guard 200, no spare: push +200, unwind to +100", 200, 1.08e18, 769, 769, 969, 869, 0, 0));
        _row(_c("8%, guard 300, spare 10k+10k: push +300, unwind to +150", 300, 1.08e18, 769, 769, 1069, 919, 10_000e18, 10_000e18));
        _row(_c("8%, guard 300, spare 30k+30k: push +300, unwind to +150", 300, 1.08e18, 769, 769, 1069, 919, 30_000e18, 30_000e18));
    }
}
