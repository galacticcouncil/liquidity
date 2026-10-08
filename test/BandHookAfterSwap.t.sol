// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The in-swap recenter: it fires on the swap that makes it due, it never fails that swap, and it
// leaves the trader's amounts alone. Written by Claude at Yash's request (2026-09-23).

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {FalseReturningERC20} from "./mocks/NonStandardERC20.sol";
import {ShortPayERC20, PrepayRouter, SelfCallProbe} from "./mocks/AfterSwapMocks.sol";

interface ITestToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract BandHookAfterSwapTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    // ln(1.04) / ln(1.0001) = 392.2: past the 350 trigger, and a push can land inside the guard
    uint256 constant UP_4PCT = 1.04e18;
    int24 constant UP_4PCT_TICK = 392;
    bytes32 constant RECENTERED = keccak256("Recentered(bytes32,int24,int24,int24,uint128)");
    bytes32 constant SKIPPED = keccak256("RecenterSkipped(bytes32,bytes4)");

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PrepayRouter prepay;
    MockPriceSource source;
    BandHook hook;
    MockERC20 t0;
    MockERC20 t1;
    PoolKey key;
    PoolId id;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        prepay = new PrepayRouter(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        _mintAndApprove(address(t0));
        _mintAndApprove(address(t1));
        (key, id) = _newPool(Currency.wrap(address(t0)), Currency.wrap(address(t1)), true);
    }

    // ---------- it fires, and only when every gate says yes

    function test_aSwapThatMakesTheRecenterDue_movesTheBandInsideTheSwap() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        assertEq(_centre(id), 0, "band still centred on the old price");

        vm.recordLogs();
        _push(key, UP_4PCT_TICK);
        (uint256 fired,) = _hookEvents(RECENTERED);
        assertEq(fired, 1, "recentered inside the swap");

        (int24 lo, int24 hi, int24 c, uint128 liq) = hook.core(id);
        assertEq(c, UP_4PCT_TICK, "centred on the oracle tick");
        assertLt(lo, c);
        assertGt(hi, c);
        assertGt(liq, 0);
        _assertCoreMatchesManager(key, id);
    }

    function test_afterTheInSwapRecenter_theManualRecenterHasNothingToDo() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        _push(key, UP_4PCT_TICK);
        vm.expectRevert(BandHook.DriftBelowTrigger.selector);
        hook.recenter(id);
    }

    function test_theTradersAmountsAreTheSameWithOrWithoutTheRecenter() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        uint256 snap = vm.snapshotState();

        BalanceDelta withRecenter = _push(key, UP_4PCT_TICK);
        assertEq(_centre(id), UP_4PCT_TICK, "the recenter did happen");

        vm.revertToState(snap);
        hook.setAutoRecenter(id, false);
        BalanceDelta without = _push(key, UP_4PCT_TICK);
        assertEq(_centre(id), 0, "and here it did not");

        assertEq(BalanceDelta.unwrap(withRecenter), BalanceDelta.unwrap(without), "same amounts either way");
    }

    function test_belowTheTrigger_theBandStays() public {
        hook.fund(id, FUND, FUND);
        source.set(1.02e18, block.timestamp); // ~198 ticks, under the 350 trigger
        _push(key, 198);
        assertEq(_centre(id), 0);
    }

    function test_outsideTheGuard_theBandStaysAndTheSwapGoesThrough() public {
        hook.fund(id, FUND, FUND);
        source.set(1.06e18, block.timestamp); // oracle ~582
        _push(key, 300); // 282 ticks short of the oracle, outside the 200 guard
        (, int24 poolTick,,) = manager.getSlot0(id);
        assertApproxEqAbs(int256(poolTick), 300, 1, "the swap happened");
        assertEq(_centre(id), 0, "but nothing moved");

        _push(key, 560); // now inside the guard: the same swap path recenters
        assertEq(_centre(id), 582);
    }

    function test_staleOracle_theBandStays() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        skip(2 hours); // staleAfter is 1 hour
        _push(key, UP_4PCT_TICK);
        assertEq(_centre(id), 0);
    }

    function test_autoRecenterOff_theBandStays_andTheManualPathStillWorks() public {
        hook.fund(id, FUND, FUND);
        hook.setAutoRecenter(id, false);
        source.set(UP_4PCT, block.timestamp);
        _push(key, UP_4PCT_TICK);
        assertEq(_centre(id), 0, "switched off");

        hook.recenter(id);
        assertEq(_centre(id), UP_4PCT_TICK, "manual recenter unchanged");
    }

    /// After a full exit the recenter leaves the core empty and a bid holding everything (issue #3).
    /// From then on a swap does not recenter: with no core there is no drift to measure, and the
    /// manual recenter, which needs no trigger in that state, is the keeper's job.
    function test_anEmptyCoreWithTheLimitLive_isLeftToTheKeeper() public {
        hook.fund(id, FUND, FUND);
        source.set(_priceAt(1500), block.timestamp); // +15%: far past the band's upper edge
        _push(key, 1500);
        (,,, uint128 coreLiq) = hook.core(id);
        (,, int24 limCentre, uint128 limLiq) = hook.limit(id);
        assertEq(coreLiq, 0, "the exit swap recentered: no token0 left, so no core");
        assertGt(limLiq, 0, "and a bid holds the token1");
        assertEq(limCentre, 1500);

        source.set(_priceAt(1560), block.timestamp);
        vm.recordLogs();
        _push(key, 1560);
        assertEq(_allHookEvents(), 0, "not attempted: the core is empty");
        (,, limCentre,) = hook.limit(id);
        assertEq(limCentre, 1500, "the bid stays where it was");

        hook.recenter(id);
        (,, limCentre,) = hook.limit(id);
        assertEq(limCentre, 1560, "the manual recenter still works");
        _assertCoreMatchesManager(key, id);
    }

    /// Not funded yet (or withdrawn) is the owner's state to change, not a trader's.
    function test_anEmptyCore_isLeftToTheOwner() public {
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -2000, tickUpper: 2000, liquidityDelta: 1e24, salt: 0}), ""
        );
        source.set(UP_4PCT, block.timestamp);
        vm.recordLogs();
        _push(key, UP_4PCT_TICK);
        (uint256 skipped,) = _hookEvents(SKIPPED);
        assertEq(skipped, 0, "not even attempted");
        (,,, uint128 liq) = hook.core(id);
        assertEq(liq, 0, "the core stays empty");
    }

    function test_tooLittleGas_skipsAndTheSwapStillSucceeds() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        uint256 snap = vm.snapshotState();
        hook.setAutoRecenter(id, false);
        uint256 g = gasleft();
        _push(key, UP_4PCT_TICK);
        uint256 plain = g - gasleft();
        vm.revertToState(snap);

        // enough for the swap with room to spare, not enough for a recenter
        swapRouter.swap{gas: plain + 100_000}(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(UP_4PCT_TICK)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(_centre(id), 0, "skipped for gas");

        _nudge(key);
        assertEq(_centre(id), UP_4PCT_TICK, "the next swap with room does it");
    }

    // ---------- a failure inside is undone, and the swap goes through

    /// The hook's payment to the PoolManager fails after the burns and the mints have run. Spare
    /// tokens in the hook make the re-mint pay in: since issue #3 the limit places what the core
    /// cannot hold, so a recenter pays in rather than collects.
    function test_aFailedPaymentAfterTheBurn_isUndoneAndTheSwapGoesThrough() public {
        FalseReturningERC20 a = new FalseReturningERC20("FA", "FA");
        FalseReturningERC20 b = new FalseReturningERC20("FB", "FB");
        (FalseReturningERC20 f0, FalseReturningERC20 f1) = address(a) < address(b) ? (a, b) : (b, a);
        _mintAndApprove(address(f0));
        _mintAndApprove(address(f1));
        (PoolKey memory k, PoolId i) = _newPool(Currency.wrap(address(f0)), Currency.wrap(address(f1)), true);
        hook.fund(i, FUND, FUND);
        f0.transfer(HOOK_ADDR, FUND / 5);
        f1.transfer(HOOK_ADDR, FUND / 5);
        bytes32 before = _records(i);

        f0.setFailTransferTo(address(manager));
        f1.setFailTransferTo(address(manager));
        source.set(UP_4PCT, block.timestamp);
        vm.recordLogs();
        _push(k, UP_4PCT_TICK);

        (uint256 skipped, bytes memory data) = _hookEvents(SKIPPED);
        assertEq(skipped, 1, "attempted and undone");
        assertEq(abi.decode(data, (bytes4)), BandHook.TransferFailed.selector, "with the reason's selector");
        assertEq(_records(i), before, "the core and the limit are back where they were");
        _assertCoreMatchesManager(k, i);

        f0.setFailTransferTo(address(0));
        f1.setFailTransferTo(address(0));
        _nudge(k);
        assertEq(_centre(i), UP_4PCT_TICK, "it recovers on the next swap");
    }

    /// Blind pass F3: a payment that "succeeds" one wei short would leave the hook owing the
    /// PoolManager, failing the trader's unlock after afterSwap has returned. The check inside the
    /// attempt turns it into an undone attempt instead.
    function test_aTokenThatPaysShort_isUndoneAndTheSwapGoesThrough() public {
        ShortPayERC20 a = new ShortPayERC20("SA", "SA");
        ShortPayERC20 b = new ShortPayERC20("SB", "SB");
        (ShortPayERC20 s0, ShortPayERC20 s1) = address(a) < address(b) ? (a, b) : (b, a);
        _mintAndApprove(address(s0));
        _mintAndApprove(address(s1));
        (PoolKey memory k, PoolId i) = _newPool(Currency.wrap(address(s0)), Currency.wrap(address(s1)), true);
        hook.fund(i, FUND, FUND);

        // spare tokens the re-mint will want, so the hook has to pay in, not only collect
        s0.transfer(HOOK_ADDR, FUND / 5);
        s1.transfer(HOOK_ADDR, FUND / 5);
        s0.setShortPay(HOOK_ADDR, address(manager));
        s1.setShortPay(HOOK_ADDR, address(manager));

        source.set(UP_4PCT, block.timestamp);
        vm.recordLogs();
        _push(k, UP_4PCT_TICK);

        (uint256 skipped, bytes memory data) = _hookEvents(SKIPPED);
        assertEq(skipped, 1, "attempted and undone");
        assertEq(abi.decode(data, (bytes4)), BandHook.Unsettled.selector);
        assertEq(_centre(i), 0);
        _assertCoreMatchesManager(k, i);
    }

    /// Blind pass F1: a router that pays in before it swaps still has its payment open while our
    /// hook runs. Syncing over it would break its settle, so the hook leaves this swap alone.
    function test_aRouterThatPaysBeforeSwapping_stillWorks() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        hook.setAutoRecenter(id, false);
        _push(key, UP_4PCT_TICK - 20); // close to the oracle, recenter now due on any swap
        hook.setAutoRecenter(id, true);

        vm.recordLogs();
        prepay.buyZero(key, 10e18);
        (uint256 skipped,) = _hookEvents(SKIPPED);
        assertEq(skipped, 0, "not attempted: the router is mid-payment");
        assertEq(_centre(id), 0);

        _nudge(key);
        assertEq(_centre(id), UP_4PCT_TICK, "an ordinary swap then does it");
    }

    // ---------- the in-swap entry is not a door

    function test_recenterInSwap_refusesAnOutsideCaller() public {
        hook.fund(id, FUND, FUND);
        vm.expectRevert(BandHook.NotSelf.selector);
        hook.recenterInSwap(id);
    }

    function test_recenterInSwap_refusesACallerInsideItsOwnUnlock() public {
        hook.fund(id, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);
        SelfCallProbe probe = new SelfCallProbe(manager);
        vm.expectRevert(BandHook.NotSelf.selector);
        probe.probe(HOOK_ADDR, id);
    }

    // ---------- the owner's switch

    function test_setAutoRecenter_isOwnerOnly() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.setAutoRecenter(id, false);
    }

    function test_setAutoRecenter_refusesAnUnconfiguredPool() public {
        PoolKey memory k = key;
        k.tickSpacing = 60;
        vm.expectRevert(BandHook.NotEnabled.selector);
        hook.setAutoRecenter(k.toId(), true);
    }

    // ---------- native ETH, as ETH/HOLLAR will run

    function test_aNativePool_recentersInsideTheSwap() public {
        vm.deal(address(this), 1_000_000 ether);
        (PoolKey memory k, PoolId i) = _newPool(Currency.wrap(address(0)), Currency.wrap(address(t1)), true);
        hook.fund{value: FUND}(i, FUND, FUND);
        source.set(UP_4PCT, block.timestamp);

        _push(k, UP_4PCT_TICK); // pays in the ERC20, takes out ETH
        assertEq(_centre(i), UP_4PCT_TICK);
        _assertCoreMatchesManager(k, i);
    }

    // ---------- helpers

    function _cfg(bool autoOn) internal view returns (BandHook.PoolConfig memory) {
        // ETH/HOLLAR launch values, with the guard at 200 as issue #2 proposes
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
            autoRecenter: autoOn
        });
    }

    function _newPool(Currency c0, Currency c1, bool autoOn) internal returns (PoolKey memory k, PoolId i) {
        k = PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 10, hooks: IHooks(HOOK_ADDR)});
        i = k.toId();
        hook.configure(k, _cfg(autoOn));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function _mintAndApprove(address token) internal {
        ITestToken(token).mint(address(this), 10_000_000e18);
        ITestToken(token).approve(address(hook), type(uint256).max);
        ITestToken(token).approve(address(swapRouter), type(uint256).max);
        ITestToken(token).approve(address(lpRouter), type(uint256).max);
        ITestToken(token).approve(address(prepay), type(uint256).max);
    }

    /// Swap toward `target` (in either direction) and stop there.
    function _push(PoolKey memory k, int24 target) internal returns (BalanceDelta) {
        (, int24 now_,,) = manager.getSlot0(k.toId());
        bool up = target > now_;
        return swapRouter.swap(
            k,
            SwapParams({zeroForOne: !up, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// A tiny sale of token0: moves the price by about nothing, but runs every hook.
    function _nudge(PoolKey memory k) internal {
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _centre(PoolId i) internal view returns (int24 c) {
        (,, c,) = hook.core(i);
    }

    /// Count this hook's events with `topic` among the logs recorded since the last call.
    function _hookEvents(bytes32 topic) internal view returns (uint256 n, bytes memory last) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].emitter == HOOK_ADDR && logs[j].topics[0] == topic) {
                n++;
                last = logs[j].data;
            }
        }
    }

    /// The core and limit records and the PoolManager agree on each position's liquidity.
    function _assertCoreMatchesManager(PoolKey memory k, PoolId i) internal view {
        (int24 lo, int24 hi,, uint128 liq) = hook.core(i);
        (uint128 held,,) = manager.getPositionInfo(k.toId(), HOOK_ADDR, lo, hi, bytes32(0));
        assertEq(held, liq, "core record matches the PoolManager");
        (lo, hi,, liq) = hook.limit(i);
        (held,,) = manager.getPositionInfo(k.toId(), HOOK_ADDR, lo, hi, bytes32(uint256(2)));
        assertEq(held, liq, "limit record matches the PoolManager");
    }

    /// Count every event this hook emitted since the last read. A swap emits one only when a
    /// recenter was attempted: `Recentered` when it went through, `RecenterSkipped` when undone.
    function _allHookEvents() internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].emitter == HOOK_ADDR) n++;
        }
    }

    /// Both position records, hashed, to check in one line that nothing moved.
    function _records(PoolId i) internal view returns (bytes32) {
        (int24 lo, int24 hi, int24 c, uint128 liq) = hook.core(i);
        (int24 limLo, int24 limHi, int24 limC, uint128 limLiq) = hook.limit(i);
        return keccak256(abi.encode(lo, hi, c, liq, limLo, limHi, limC, limLiq));
    }

    function _priceAt(int24 tick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        return (s * s >> 96) * 1e18 >> 96;
    }
}
