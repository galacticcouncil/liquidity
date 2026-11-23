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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Issue #3: what the two-sided core cannot hold goes into a one-sided limit next to the
/// price, so a trend or a full band exit no longer leaves the capital idle or stuck.
contract BandHookOneSidedLimitTest is Test {
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
    bytes32 constant LIMIT_SALT = bytes32(uint256(2));
    uint256 constant BASE = 100_000e18;
    address alice = makeAddr("alice"); // arbitrage: moves the pool with the market
    address mallory = makeAddr("mallory"); // pushes the pool on her own
    address carol = makeAddr("carol"); // calls recenter

    /// The HDX shape: spacing 60, band +-1000, cap 2%, trigger 500, guard 300, no backstop,
    /// so every token is in the core, the limit or idle, and nothing hides in a backstop.
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
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 3000,
                feeCap: 20000,
                feeSlopePpm: 1_000_000,
                staleAfter: 1 hours,
                halfBandTicks: 1000,
                backstopHalfTicks: 0,
                backstopBps: 0,
                triggerTicks: 500,
                guardTicks: 300,
                enabled: true
            })
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 10_000_000e18);
        t1.mint(address(this), 10_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        _endow(alice);
        _endow(mallory);
    }

    function _endow(address who) internal {
        t0.mint(who, 100_000_000e18);
        t1.mint(who, 100_000_000e18);
        vm.startPrank(who);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ---------- moving the market

    function poolTick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _poolSqrt() internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(id);
    }

    /// `who` swaps the pool to `target`, trading through whatever liquidity is on the way.
    function _swapTo(address who, int24 target) internal {
        uint160 limitPrice = TickMath.getSqrtPriceAtTick(target);
        bool zeroForOne = limitPrice < _poolSqrt();
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -50_000_000e18, sqrtPriceLimitX96: limitPrice}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function setOracleTick(int24 t) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        uint256 px96 = FullMath.mulDiv(s, s, 1 << 96);
        source.set(FullMath.mulDiv(px96, 1e18, 1 << 96), block.timestamp);
    }

    /// The market moves: Alice trades the pool to `target` and the oracle follows it.
    function moveBothTo(int24 target) internal {
        _swapTo(alice, target);
        setOracleTick(poolTick());
    }

    /// Mallory moves the pool alone; the oracle stays where it was.
    function pushPoolTo(int24 target) internal {
        _swapTo(mallory, target);
    }

    // ---------- reading the hook

    function coreRecord() internal view returns (int24 lo, int24 hi, int24 center, uint128 liq) {
        return hook.core(id);
    }

    function limitRecord() internal view returns (int24 lo, int24 hi, int24 center, uint128 liq) {
        return hook.limit(id);
    }

    function heldByManager(int24 lo, int24 hi, bytes32 salt) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lo, hi, salt);
    }

    /// What `amount0` and `amount1` are worth together, in token1, at the pool price.
    function valueInToken1(uint256 amount0, uint256 amount1) internal view returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(_poolSqrt(), _poolSqrt(), 1 << 96);
        return FullMath.mulDiv(amount0, priceX96, 1 << 96) + amount1;
    }

    /// What a position is worth, in token1, at the pool price. Zero for an empty record.
    function positionValue(int24 lo, int24 hi, uint128 liq) internal view returns (uint256) {
        if (liq == 0) return 0;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            _poolSqrt(), TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq
        );
        return valueInToken1(a0, a1);
    }

    /// Share of the hook's capital sitting in its own balance, in basis points of core + limit + idle.
    function idleShareBps() internal view returns (uint256) {
        (int24 cl, int24 ch,, uint128 cq) = coreRecord();
        (int24 ll, int24 lh,, uint128 lq) = limitRecord();
        uint256 idle = valueInToken1(t0.balanceOf(HOOK_ADDR), t1.balanceOf(HOOK_ADDR));
        uint256 total = positionValue(cl, ch, cq) + positionValue(ll, lh, lq) + idle;
        return total == 0 ? 0 : idle * 10_000 / total;
    }

    // ---------- the milestone test

    /// 1. HDX jumps 1200 ticks, Carol recentres with under 1% idle; the price falls back to 600
    /// through the bid, which fills; Carol's next recentre is two-sided again.
    function test_exitAndComeBack() public {
        hook.fund(id, BASE, BASE);

        // the market jumps: the core sells all its token0 on the way up and is left below the price
        moveBothTo(1200);
        vm.prank(carol);
        hook.recenter(id);

        (,,, uint128 coreLiq) = coreRecord();
        (int24 bidLo, int24 bidHi,, uint128 bidLiq) = limitRecord();
        assertEq(coreLiq, 0, "no token0 left, so no two-sided core");
        assertGt(bidLiq, 0, "the token1 is placed");
        assertLe(bidHi, poolTick(), "as a bid below the price");
        assertLt(idleShareBps(), 100, "under 1% idle");

        // the market falls back through the bid, which buys token0 on the way down
        moveBothTo(600);
        assertTrue(bidLo < poolTick() && poolTick() < bidHi, "the price is inside the bid");
        (uint256 bought,) = LiquidityAmounts.getAmountsForLiquidity(
            _poolSqrt(), TickMath.getSqrtPriceAtTick(bidLo), TickMath.getSqrtPriceAtTick(bidHi), bidLiq
        );
        assertGt(bought, 0, "the bid filled: it now holds token0");

        // the core is empty, so no trigger applies and Carol can recentre straight away
        vm.prank(carol);
        hook.recenter(id);

        (int24 lo, int24 hi,, uint128 liq) = coreRecord();
        assertGt(liq, 0, "two-sided again");
        assertTrue(lo < poolTick() && poolTick() < hi, "the core straddles the price");
        assertLt(idleShareBps(), 100, "still under 1% idle");
    }

    // ---------- where the leftover goes

    /// 2. After a 1200-tick jump up, Carol recentres: the core is empty and a bid below the
    /// price holds all the token1.
    function test_fullExitUp_bidBelowThePriceHoldsEverything() public {
        hook.fund(id, BASE, BASE);
        (int24 oldLo, int24 oldHi,,) = coreRecord();
        moveBothTo(1200);
        vm.prank(carol);
        hook.recenter(id);

        (,,, uint128 coreLiq) = coreRecord();
        (int24 lo, int24 hi, int24 center, uint128 liq) = limitRecord();
        assertEq(coreLiq, 0, "no two-sided core without token0");
        assertEq(hi, 1200, "the bid tops out right at the price");
        assertEq(lo, 180, "half a band below, rounded down to the tick grid");
        assertEq(center, 1200, "recorded against the oracle");
        assertEq(heldByManager(oldLo, oldHi, CORE_SALT), 0, "the old core was burned");
        assertEq(heldByManager(lo, hi, LIMIT_SALT), liq, "the PoolManager holds the bid");
        assertEq(t0.balanceOf(HOOK_ADDR), 0, "no token0 anywhere in the hook");
        assertLt(t1.balanceOf(HOOK_ADDR), 1e15, "only rounding dust of token1 left over");
    }

    /// 3. The mirror: after a 1200-tick fall, an ask above the price holds all the token0.
    function test_fullExitDown_askAboveThePriceHoldsEverything() public {
        hook.fund(id, BASE, BASE);
        moveBothTo(-1200);
        vm.prank(carol);
        hook.recenter(id);

        (,,, uint128 coreLiq) = coreRecord();
        (int24 lo, int24 hi,, uint128 liq) = limitRecord();
        assertEq(coreLiq, 0, "no two-sided core without token1");
        assertEq(lo, -1140, "the ask starts one tick spacing above the price");
        assertEq(hi, -120, "half a band above, rounded up to the tick grid");
        assertEq(heldByManager(lo, hi, LIMIT_SALT), liq, "the PoolManager holds the ask");
        assertEq(t1.balanceOf(HOOK_ADDR), 0, "no token1 anywhere in the hook");
        assertLt(t0.balanceOf(HOOK_ADDR), 1e15, "only rounding dust of token0 left over");
    }

    /// 4. Six legs of +600 with a recentre after each: under 1% idle after every leg.
    function test_trendLegs_idleStaysUnderOnePercent() public {
        hook.fund(id, BASE, BASE);
        for (int24 leg = 1; leg <= 6; leg++) {
            moveBothTo(leg * 600);
            vm.prank(carol);
            hook.recenter(id);
            assertLt(idleShareBps(), 100, "under 1% idle after every leg");
        }
    }

    /// 5. After a full exit, 1e6 wei of token0 lands in the hook: the recentre puts the rest in
    /// the limit instead of leaving 99.99% idle.
    function test_sliverAfterAnExit_restGoesToTheLimit() public {
        hook.fund(id, BASE, BASE);
        moveBothTo(1200);
        t0.transfer(HOOK_ADDR, 1e6);

        vm.prank(carol);
        hook.recenter(id);

        (,,, uint128 liq) = limitRecord();
        assertGt(liq, 0, "the token1 is in the limit");
        assertLt(idleShareBps(), 100, "under 1% idle, not 99.99%");
    }

    // ---------- the safer side

    /// 6. After a rise, Mallory pushes the pool 250 ticks above the oracle and Carol recentres:
    /// the bid tops out at the oracle, not at Mallory's price.
    function test_pushedPool_bidTopsOutAtTheOracle() public {
        hook.fund(id, BASE, BASE);
        moveBothTo(1200);
        pushPoolTo(1450);
        assertEq(poolTick(), 1450, "Mallory moved the pool, inside the 300-tick guard");

        vm.prank(carol);
        hook.recenter(id);

        (, int24 hi, int24 oracleTick, uint128 liq) = limitRecord();
        assertEq(oracleTick, 1200, "the oracle did not move");
        assertEq(hi, 1200, "the bid tops out at the oracle, not at 1440 under Mallory's price");
        assertGt(liq, 0, "and holds the token1");
    }

    // ---------- funding and withdrawing

    /// 7. Bob withdraws while a limit is live: everything comes back, and the PoolManager holds
    /// nothing at the limit's range.
    function test_withdraw_burnsTheLimitAndReturnsEverything() public {
        hook.fund(id, BASE, BASE);
        moveBothTo(1200);
        vm.prank(carol);
        hook.recenter(id);
        (int24 lo, int24 hi,, uint128 liq) = limitRecord();
        assertGt(liq, 0, "a bid is live");

        uint256 before1 = t1.balanceOf(address(this));
        hook.withdraw(id);

        (,,, uint128 after_) = limitRecord();
        assertEq(after_, 0, "the limit record is cleared");
        assertEq(heldByManager(lo, hi, LIMIT_SALT), 0, "and the PoolManager holds nothing there");
        assertEq(t0.balanceOf(HOOK_ADDR), 0, "nothing left in the hook");
        assertEq(t1.balanceOf(HOOK_ADDR), 0, "nothing left in the hook");
        assertGt(
            t1.balanceOf(address(this)) - before1, 200_000e18, "Bob gets his token1 plus what the core sold token0 for"
        );
    }

    /// 8. Bob funds only token1 into a fresh pool: no core, and a bid holds all of it.
    function test_fundToken1Only_bidHoldsItAll() public {
        hook.fund(id, 0, BASE);

        (,,, uint128 coreLiq) = coreRecord();
        (int24 lo, int24 hi,, uint128 liq) = limitRecord();
        assertEq(coreLiq, 0, "no token0, so no core");
        assertEq(hi, 0, "a bid right under the price");
        assertEq(lo, -1020, "half a band below, rounded down to the tick grid");
        assertGt(liq, 0, "holding the token1");
        assertLt(t1.balanceOf(HOOK_ADDR), 1e15, "only rounding dust left over");
    }

    /// 9. A pool whose hook holds nothing: recenter refuses with EmptyBand.
    function test_nothingAtAll_isRefused() public {
        vm.prank(carol);
        vm.expectRevert(BandHook.EmptyBand.selector);
        hook.recenter(id);
    }

    // ---------- the rules, for any move

    /// For any market move past the trigger and any push by Mallory inside the guard, a
    /// recentre leaves under 1% idle, the limit is one-sided and on the safe side of the
    /// oracle, and both records match what the PoolManager holds.
    function testFuzz_anyMoveAndPush_recentreIsOneSidedAndSafe(bool up, uint256 distance, int256 push) public {
        int24 move = int24(int256(bound(distance, 520, 3000)));
        if (!up) move = -move;
        int24 nudge = int24(bound(push, -250, 250));

        hook.fund(id, BASE, BASE);
        moveBothTo(move);
        if (nudge != 0) pushPoolTo(poolTick() + nudge);

        vm.prank(carol);
        hook.recenter(id);

        assertLt(idleShareBps(), 100, "under 1% idle");
        (int24 cl, int24 ch,, uint128 cq) = coreRecord();
        (int24 ll, int24 lh, int24 oracleTick, uint128 lq) = limitRecord();
        assertEq(heldByManager(cl, ch, CORE_SALT), cq, "the core record matches the PoolManager");
        assertEq(heldByManager(ll, lh, LIMIT_SALT), lq, "the limit record matches the PoolManager");
        if (lq == 0) return;
        if (lh <= poolTick()) {
            assertLe(lh, oracleTick, "a bid never tops out above the oracle");
        } else {
            assertGt(ll, poolTick(), "a limit that is not a bid is an ask, wholly above the price");
            assertGt(ll, oracleTick, "an ask never starts below the oracle");
        }
    }
}
