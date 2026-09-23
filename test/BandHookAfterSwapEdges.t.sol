// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The blind pass's edge cases for the in-swap recenter (F8, F9; F6 is with the band edges in
// BandHookAfterSwapReview) and the one place the "a swap always goes through" rule can still be
// broken: a long route after our pool. Written by Claude at Yash's request (2026-09-23).

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {CallbackOnTransferERC20, SyncClearer, BombERC20, TailRouter} from "./mocks/AfterSwapMocks.sol";

interface IToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract BandHookAfterSwapEdgesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    bytes32 constant SKIPPED = keccak256("RecenterSkipped(bytes32,bytes4)");

    IPoolManager manager;
    PoolSwapTest pusher;
    TailRouter tail;
    MockPriceSource source;
    BandHook hook;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pusher = new PoolSwapTest(manager);
        tail = new TailRouter(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
    }

    // ---------- F9: code inside the hook's payment clears the shared sync slot

    function test_F9_codeThatClearsTheSyncSlotMidPayment_isUndone() public {
        CallbackOnTransferERC20 x = new CallbackOnTransferERC20("CA", "CA");
        CallbackOnTransferERC20 y = new CallbackOnTransferERC20("CB", "CB");
        (address a, address b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        _setUpToken(a);
        _setUpToken(b);
        (PoolKey memory k, PoolId i) = _pool(a, b, 10);
        hook.fund(i, FUND, FUND);
        // spare tokens the re-mint will want, so the hook has to pay in during the recenter
        IToken(a).transfer(HOOK_ADDR, FUND / 5);
        IToken(b).transfer(HOOK_ADDR, FUND / 5);
        SyncClearer clearer = new SyncClearer(manager);
        CallbackOnTransferERC20(a).watch(HOOK_ADDR, address(manager), address(clearer));
        CallbackOnTransferERC20(b).watch(HOOK_ADDR, address(manager), address(clearer));

        source.set(1.04e18, block.timestamp);
        vm.recordLogs();
        _swapTo(k, 392);
        (uint256 skipped, bytes memory data) = _events(SKIPPED);
        assertEq(skipped, 1, "attempted and undone");
        assertEq(abi.decode(data, (bytes4)), BandHook.Unsettled.selector);
        assertEq(_centre(i), 0, "nothing moved");
    }

    // ---------- F8: a huge revert inside the attempt

    /// The token reverts with 64 KB when the hook pays the PoolManager. The hook's own transfer
    /// check copies that into the attempt's memory and fails with TransferFailed; the outer raw
    /// call copies four bytes. The cost stays inside the attempt's budget; the trade goes on.
    function test_F8_aHugeRevertInsideTheAttempt_isContained() public {
        BombERC20 x = new BombERC20("BA", "BA");
        BombERC20 y = new BombERC20("BB", "BB");
        (address a, address b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        _setUpToken(a);
        _setUpToken(b);
        (PoolKey memory k, PoolId i) = _pool(a, b, 10);
        hook.fund(i, FUND, FUND);
        // spare tokens the re-mint will want, so the hook has to pay in during the recenter
        IToken(a).transfer(HOOK_ADDR, FUND / 5);
        IToken(b).transfer(HOOK_ADDR, FUND / 5);
        BombERC20(a).arm(HOOK_ADDR, address(manager), 64 * 1024);
        BombERC20(b).arm(HOOK_ADDR, address(manager), 64 * 1024);

        source.set(1.04e18, block.timestamp);
        vm.recordLogs();
        uint256 g = gasleft();
        _swapTo(k, 392);
        uint256 used = g - gasleft();
        (uint256 skipped, bytes memory data) = _events(SKIPPED);
        assertEq(skipped, 1, "attempted and undone");
        assertEq(abi.decode(data, (bytes4)), BandHook.TransferFailed.selector);
        assertEq(_centre(i), 0);
        emit log_named_uint("gas of the swap whose recenter hit a 64 KB revert", used);
        assertLt(used, 1_000_000, "bounded by the attempt's budget, not by the revert's size");
    }

    // ---------- the rule's one gap: a long route after our pool

    /// About 400k of work after our pool: under the 900k gate minus the ~460k the recenter costs.
    /// Whatever margin the route carries over its estimate, either too little gas is left at our
    /// hook and the recenter is skipped, or enough is left for both.
    function test_tail_aRouteWithLittleWorkAfterOurPool_alwaysGoesThrough() public {
        (PoolKey memory k, PoolId i, uint160 limit, uint256 est) = _dueForTailRoute(16);
        assertTrue(_sendTail(k, limit, 16, est + 20_000), "small margin: goes through");
        assertTrue(_sendTail(k, limit, 16, est + 250_000), "bigger margin: goes through");
        assertTrue(_sendTail(k, limit, 16, est + 470_000), "near the recenter's cost: goes through");
        assertEq(_centre(i), 0, "all three skipped the recenter");
        assertTrue(_sendTail(k, limit, 16, est + 700_000), "generous margin: goes through");
        assertEq(_centre(i), 392, "and pays for the recenter");
    }

    /// About 1M of work after our pool clears the gate on its own. If the route's gas was estimated
    /// before the recenter became due and carries less spare than the recenter costs, the recenter
    /// spends gas the route needed and the whole trade fails. The hook cannot see the work left.
    function test_tail_aRouteWithMuchWorkAfterOurPool_canStillRunShort() public {
        (PoolKey memory k, PoolId i, uint160 limit, uint256 est) = _dueForTailRoute(42);
        assertFalse(_sendTail(k, limit, 42, est + 20_000), "small margin: runs short");
        assertFalse(_sendTail(k, limit, 42, est + 250_000), "bigger margin: still short");
        assertEq(_centre(i), 0);
        assertTrue(_sendTail(k, limit, 42, est + 550_000), "a margin that covers the recenter: fine");
        assertEq(_centre(i), 392);
        emit log_named_uint("the route's estimate, without the recenter", est);
    }

    /// A pool with the recenter due for the next swap, and the tail route's gas estimated without
    /// it (the switch off), as a wallet would have estimated it before the oracle moved.
    function _dueForTailRoute(uint256 writes) internal returns (PoolKey memory k, PoolId i, uint160 limit, uint256 est) {
        (address a, address b) = _twoTokens();
        IToken(b).approve(address(tail), type(uint256).max);
        (k, i) = _pool(a, b, 10);
        hook.fund(i, FUND, FUND);
        source.set(1.04e18, block.timestamp);
        hook.setAutoRecenter(i, false);
        _swapTo(k, 372); // close to the oracle: the recenter is due for the next swap
        limit = TickMath.getSqrtPriceAtTick(380);
        est = _leastGasThatWorks(k, limit, writes);
        hook.setAutoRecenter(i, true);
    }

    /// The least gas limit the route succeeds with, found by halving the gap: what a wallet's
    /// estimate converges to. It is a little above the gas the route uses, because each nested
    /// call can be handed at most 63/64 of the gas left.
    function _leastGasThatWorks(PoolKey memory k, uint160 limit, uint256 writes) internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 5_000_000;
        while (hi - lo > 1000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _sendTail(k, limit, writes, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function _sendTail(PoolKey memory k, uint160 limit, uint256 writes, uint256 gasLimit) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        (ok,) = address(tail).call{gas: gasLimit}(abi.encodeCall(TailRouter.run, (k, 1e18, limit, writes)));
        if (!ok) vm.revertToState(snap); // keep the state for the next attempt
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
        IToken(t).mint(address(this), 100_000_000e18);
        IToken(t).approve(address(hook), type(uint256).max);
        IToken(t).approve(address(pusher), type(uint256).max);
    }

    function _pool(address a, address b, int24 spacing) internal returns (PoolKey memory k, PoolId i) {
        k = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(HOOK_ADDR)
        });
        i = k.toId();
        hook.configure(k, _cfg());
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function _swapTo(PoolKey memory k, int24 target) internal {
        (, int24 now_,,) = manager.getSlot0(k.toId());
        bool up = target > now_;
        pusher.swap(
            k,
            SwapParams({zeroForOne: !up, amountSpecified: -1e36, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _centre(PoolId i) internal view returns (int24 c) {
        (,, c,) = hook.core(i);
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
