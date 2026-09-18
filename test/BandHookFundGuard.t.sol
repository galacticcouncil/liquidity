// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
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

/// fund() places capital against the pool price, so it must refuse when that price is
/// unverified: stale oracle, or pool too far from it. Audit finding C1.
contract BandHookFundGuardTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    MockERC20 hollar;
    MockPriceSource source;
    MockPriceSource nativeSource;
    BandHook hook;
    PoolKey key;
    PoolId id;
    PoolKey nativeKey;
    PoolId nativeId;

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));
    address mallory = makeAddr("mallory");
    uint256 constant FUND = 100_000e18;
    int24 constant GUARD = 100;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        source = new MockPriceSource(1e18);
        nativeSource = new MockPriceSource(2500e18);

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
        hook.configure(key, _cfg(IPriceSource(address(source)), GUARD, 20000));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(hollar)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        nativeId = nativeKey.toId();
        hook.configure(nativeKey, _cfg(IPriceSource(address(nativeSource)), 150, 10000));
        manager.initialize(nativeKey, TickMath.getSqrtPriceAtTick(78244));

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        hollar.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        hollar.approve(address(hook), type(uint256).max);
        vm.deal(address(this), 1000 ether);

        t0.mint(mallory, 5_000_000e18);
        t1.mint(mallory, 5_000_000e18);
        vm.startPrank(mallory);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _cfg(IPriceSource src, int24 guardTicks, uint24 feeCap)
        internal
        pure
        returns (BandHook.PoolConfig memory)
    {
        return BandHook.PoolConfig({
            source: src,
            feeFloor: 3000,
            feeCap: feeCap,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 1000,
            backstopHalfTicks: 16000,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: guardTicks,
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
        vm.prank(mallory);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -5_000_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function setOracleTick(MockPriceSource src, int24 t) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        uint256 px96 = FullMath.mulDiv(s, s, 1 << 96);
        src.set(FullMath.mulDiv(px96, 1e18, 1 << 96), block.timestamp);
    }

    // ---------- a stale oracle

    /// The 16.77%-of-funding case. The band used to centre on whatever the pool said.
    function test_fund_refusedWhenTheOracleIsStale() public {
        skip(2 hours); // staleAfter is 1 hour
        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.fund(id, FUND, FUND);
    }

    /// Staleness is checked before the pool price, so a pool sitting exactly on a stale
    /// oracle is still refused.
    function test_fund_refusedWhenStaleEvenWithThePoolOnTheOracle() public {
        assertEq(poolTick(), 0, "pool and oracle agree");
        skip(2 hours);
        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.fund(id, FUND, FUND);
    }

    // ---------- the pool too far from the oracle

    /// The launch-day attack: Mallory sets an empty pool's price for free, then the owner
    /// funds into it. Measured before the fix at 2.41% of the funding.
    function test_fund_refusedAfterMalloryMovesAnEmptyPool() public {
        pushPoolToTick(6000);
        assertEq(poolTick(), 6000, "Mallory set the price for nothing");

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);
    }

    /// Ben's point: every funding, not only the first. Measured before the fix at
    /// $23,125 on a $200k top-up during a stale window.
    function test_topUp_refusedWhenThePoolHasBeenMoved() public {
        hook.fund(id, FUND, FUND);
        pushPoolToTick(400);

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);
    }

    /// Symmetric: it refuses in both directions.
    function test_fund_refusedInBothDirections() public {
        uint256 snap = vm.snapshotState();

        setOracleTick(source, 400);
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);

        vm.revertToState(snap);
        setOracleTick(source, -400);
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);
    }

    /// Where the line actually falls, swept rather than predicted. The pool sits at tick 0
    /// and the oracle moves, so the gap is exact.
    function test_fund_guardBoundarySweep() public {
        console2.log("pool at tick 0, oracle moved N ticks, guardTicks = 100");
        int24[7] memory offsets = [int24(0), 50, 98, 99, 100, 101, 150];
        for (uint256 i = 0; i < offsets.length; i++) {
            uint256 snap = vm.snapshotState();
            setOracleTick(source, offsets[i]);
            try hook.fund(id, FUND, FUND) {
                console2.log(string.concat("  oracle +", vm.toString(int256(offsets[i])), " -> funded"));
            } catch (bytes memory err) {
                console2.log(
                    string.concat(
                        "  oracle +", vm.toString(int256(offsets[i])), " -> refused ", vm.toString(bytes4(err))
                    )
                );
            }
            vm.revertToState(snap);
        }
    }

    // ---------- a refusal costs only gas

    /// Nothing moves on a refusal: the owner keeps both balances and no band is recorded.
    function test_refusedFund_movesNoTokens() public {
        pushPoolToTick(6000);
        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);

        assertEq(t0.balanceOf(address(this)), before0, "token0 untouched");
        assertEq(t1.balanceOf(address(this)), before1, "token1 untouched");
        (,,, uint128 cliq) = hook.core(id);
        assertEq(cliq, 0, "no band recorded");
    }

    /// The native leg: a refused fund returns the ETH sent with it.
    function test_refusedNativeFund_returnsTheEth() public {
        setOracleTick(nativeSource, 78244 + 400); // beyond the 150-tick guard
        uint256 before = address(this).balance;

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund{value: 10 ether}(nativeId, 10 ether, 25_000e18);

        assertEq(address(this).balance, before, "the ETH came back");
        assertEq(HOOK_ADDR.balance, 0, "and none of it stuck in the hook");
    }

    // ---------- the happy paths still work

    function test_fund_worksWhenThePoolSitsOnTheOracle() public {
        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "funded normally");
    }

    function test_fund_worksWellInsideTheGuard() public {
        setOracleTick(source, 50);
        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "50 ticks is inside a 100-tick guard");
    }

    function test_nativeFund_stillWorksOnTheOracle() public {
        hook.fund{value: 10 ether}(nativeId, 10 ether, 25_000e18);
        (,,, uint128 cliq) = hook.core(nativeId);
        assertGt(cliq, 0, "native pool funded");
    }

    // ---------- the coupling this decision accepts

    /// PINS AUDIT FINDING H1, which is open for Ben. `fund` now shares `guardTicks` with
    /// `recenter`. On the HDX pools that guard is 200, while a 2% fee cap leaves arbitrage
    /// resting 203 ticks from the oracle (measured in the audit). So after any ordinary
    /// price move, an HDX top-up is refused - no attacker involved. When H1 widens the
    /// guard, this test changes and says so.
    function test_hdxGuardIsTooTightForAnOrdinaryTopUp() public {
        PoolKey memory hdx = key;
        hdx.tickSpacing = 60;
        PoolId hdxId = hdx.toId();
        hook.configure(hdx, _cfg(IPriceSource(address(source)), 200, 20000));
        manager.initialize(hdx, TickMath.getSqrtPriceAtTick(0));

        // the pool rests where arbitrage leaves it at a 2% cap
        setOracleTick(source, 203);

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(hdxId, FUND, FUND);
    }

    receive() external payable {}
}
