// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolAnchor} from "../script/PoolAnchor.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// PoolAnchor moves a stale pool onto a target price in one transaction with one swap, and costs its
/// caller nothing when nobody else's liquidity is in the way.
contract PoolAnchorTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    MockERC20 hollar;
    MockPriceSource source;
    BandHook hook;
    PoolAnchor helper;
    PoolKey key;
    PoolId id;
    PoolKey nativeKey;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    address stranger = makeAddr("stranger");
    address mallory = makeAddr("mallory");
    uint256 constant DUST = 1e12; // what an anchor through an empty path may cost, per token
    uint160 constant FLOOR = TickMath.MIN_SQRT_PRICE + 1; // the lowest price a swap can leave a pool at
    uint160 constant CEILING = TickMath.MAX_SQRT_PRICE - 1; // the highest

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        source = new MockPriceSource(1e18);

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        helper = new PoolAnchor(manager);

        key = PoolKey(
            Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(HOOK_ADDR)
        );
        id = key.toId();
        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        nativeKey = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(hollar)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(HOOK_ADDR)
        );
        hook.configure(nativeKey, _cfg());
        manager.initialize(nativeKey, TickMath.getSqrtPriceAtTick(0));

        MockERC20[3] memory tokens = [t0, t1, hollar];
        for (uint256 i; i < 3; i++) {
            tokens[i].mint(address(this), 10_000_000e18);
            tokens[i].approve(address(helper), type(uint256).max);
            tokens[i].approve(address(hook), type(uint256).max);
            tokens[i].mint(stranger, 10_000_000e18);
            vm.prank(stranger);
            tokens[i].approve(address(lpRouter), type(uint256).max);
            tokens[i].mint(mallory, 1);
            vm.prank(mallory);
            tokens[i].approve(address(swapRouter), type(uint256).max);
        }
        vm.deal(address(this), 100 ether);
    }

    function _cfg() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
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
            enabled: true,
            autoRecenter: false
        });
    }

    function price(PoolId pid) internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(pid);
    }

    function setOracleTick(int24 t) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        source.set(FullMath.mulDiv(FullMath.mulDiv(s, s, 1 << 96), 1e18, 1 << 96), block.timestamp);
    }

    /// The stranger puts liquidity between the pool's price (tick 0) and tick 1200.
    function strangerAddsLiquidityOnThePath() internal {
        vm.prank(stranger);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(0, 1200, 1e21, bytes32(0)), "");
    }

    /// Mallory moves an empty pool's price onto `limit` with a 1-wei swap; nothing trades, so it is free.
    function malloryParksThePriceAt(PoolKey memory k, uint160 limit) internal {
        vm.prank(mallory);
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: limit < price(k.toId()), amountSpecified: -1, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    receive() external payable {}

    // ---------- an empty path

    /// 1. A stale empty pool at tick 0 is moved exactly onto the target at tick 1200, for dust.
    function test_anchorsAStaleEmptyPool_upToTheTarget() public {
        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        uint160 target = TickMath.getSqrtPriceAtTick(1200);

        helper.anchor(key, target,1e18);

        assertEq(price(id), target, "exactly on the target");
        assertLt(before0 - t0.balanceOf(address(this)), DUST, "only dust of token0");
        assertLt(before1 - t1.balanceOf(address(this)), DUST, "only dust of token1");
        assertEq(t0.balanceOf(address(helper)) + t1.balanceOf(address(helper)), 0, "the helper keeps nothing");
    }

    /// 2. The same downwards.
    function test_anchorsDown() public {
        uint160 target = TickMath.getSqrtPriceAtTick(-1200);
        helper.anchor(key, target,1e18);
        assertEq(price(id), target);
    }

    /// 3. A native ETH pool: the ETH sent along is returned.
    function test_nativePool_returnsTheUnusedEth() public {
        uint256 ethBefore = address(this).balance;
        uint160 target = TickMath.getSqrtPriceAtTick(1200);

        helper.anchor{value: 1 ether}(nativeKey, target,1e18);

        assertEq(price(nativeKey.toId()), target, "exactly on the target");
        assertLt(ethBefore - address(this).balance, DUST, "all but dust of the ETH came back");
        assertEq(address(helper).balance, 0, "the helper keeps no ETH");
    }

    // ---------- someone else's liquidity in the way

    /// 4. With a stranger's liquidity on the path and a cap too small to cross it, nothing
    /// happens: the whole anchor reverts and the price stays where it was.
    function test_liquidityOnThePath_capTooSmall_nothingHappens() public {
        strangerAddsLiquidityOnThePath();
        uint160 before = price(id);

        vm.expectRevert(PoolAnchor.TargetNotReached.selector);
        helper.anchor(key, TickMath.getSqrtPriceAtTick(1200),1e15);

        assertEq(price(id), before, "the price did not move");
    }

    /// 5. With a big enough cap, the anchor crosses the stranger's liquidity and the caller pays
    /// for it, which is why the caps exist.
    function test_liquidityOnThePath_callerPaysThrough() public {
        strangerAddsLiquidityOnThePath();
        uint256 before1 = t1.balanceOf(address(this));
        uint160 target = TickMath.getSqrtPriceAtTick(1200);

        helper.anchor(key, target,1_000_000e18);

        assertEq(price(id), target, "on the target");
        assertGt(before1 - t1.balanceOf(address(this)), 1e18, "the caller paid to cross the stranger's liquidity");
    }

    // ---------- the edges

    /// 6. A pool already on the target: refused, there is nothing to do.
    function test_alreadyAtTheTarget_isRefused() public {
        vm.expectRevert(PoolAnchor.AlreadyAtTarget.selector);
        helper.anchor(key, TickMath.getSqrtPriceAtTick(0),1e18);
    }

    /// 7. The point of it all: with the oracle 1200 ticks away the hook refuses to fund; after
    /// the anchor it funds around the oracle.
    function test_afterAnchoring_theHookFunds() public {
        setOracleTick(1200);
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, 100_000e18, 100_000e18);

        helper.anchor(key, TickMath.getSqrtPriceAtTick(1200),1e18);
        hook.fund(id, 100_000e18, 100_000e18);
        (,, int24 center, uint128 liq) = hook.core(id);
        assertEq(center, 1200, "funded around the oracle");
        assertGt(liq, 0);
    }

    /// 8. Only the PoolManager can drive the callback.
    function test_onlyThePoolManagerCanCallBack() public {
        vm.expectRevert(PoolAnchor.NotManager.selector);
        helper.unlockCallback("");
    }

    // ---------- a pool parked at the very edge (review issue 1)

    /// 9. Mallory parks an empty pool on the floor; Alice anchors it up to tick 1200, then the hook funds.
    function test_fromTheFloor_anchorsOntoTheTarget() public {
        setOracleTick(1200);
        malloryParksThePriceAt(key, FLOOR);
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, 100_000e18, 100_000e18);

        uint160 target = TickMath.getSqrtPriceAtTick(1200);
        helper.anchor(key, target,1e18);

        assertEq(price(id), target, "exactly on the target");
        hook.fund(id, 100_000e18, 100_000e18);
        (,, int24 center, uint128 liq) = hook.core(id);
        assertEq(center, 1200, "funded around the oracle");
        assertGt(liq, 0);
    }

    /// 10. Mallory parks it on the ceiling; Alice anchors it down to tick -1200.
    function test_fromTheCeiling_anchorsOntoTheTarget() public {
        malloryParksThePriceAt(key, CEILING);
        uint160 target = TickMath.getSqrtPriceAtTick(-1200);

        helper.anchor(key, target,1e18);

        assertEq(price(id), target, "exactly on the target");
    }

    /// 11. From the floor, an empty path costs Alice nothing and the pool is still empty afterwards.
    function test_fromTheFloor_costsNothing() public {
        malloryParksThePriceAt(key, FLOOR);
        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));

        helper.anchor(key, TickMath.getSqrtPriceAtTick(1200),1e18);

        assertEq(t0.balanceOf(address(this)), before0, "no token0 spent");
        assertEq(t1.balanceOf(address(this)), before1, "no token1 spent");
        assertEq(manager.getLiquidity(id), 0, "the pool is still empty");
    }

    /// 12. A native-ETH pool on the floor: Alice sends 1 ETH along and gets all of it back.
    function test_nativePoolFromTheFloor_returnsAllTheEth() public {
        malloryParksThePriceAt(nativeKey, FLOOR);
        uint256 ethBefore = address(this).balance;
        uint160 target = TickMath.getSqrtPriceAtTick(1200);

        helper.anchor{value: 1 ether}(nativeKey, target,1e18);

        assertEq(price(nativeKey.toId()), target, "exactly on the target");
        assertEq(address(this).balance, ethBefore, "all the ETH came back");
        assertEq(address(helper).balance, 0, "the helper keeps no ETH");
    }
}
