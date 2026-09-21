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
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {CallbackERC20, IPoke} from "./mocks/NonStandardERC20.sol";

/// Moves the pool when the token calls it, which is the whole point of the attack.
contract Poker is IPoke {
    PoolSwapTest immutable router;
    PoolKey key;
    int24 public target;
    uint256 public fired;

    constructor(PoolSwapTest _router) {
        router = _router;
    }

    function arm(PoolKey memory k, int24 t) external {
        key = k;
        target = t;
    }

    function poke() external {
        fired++;
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -2_000_000e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

/// The price the guard checks must be the price the mint uses. Audit finding R8:
/// the guard used to run in fund(), two external token calls before the mint read
/// the price again, so a token that runs code mid-transfer could move it in between.
contract BandHookGateInsideUnlockTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 plain;
    CallbackERC20 cb;
    address c0;
    address c1;
    MockPriceSource source;
    BandHook hook;
    Poker poker;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));
    uint256 constant FUND = 100_000e18;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        poker = new Poker(swapRouter);
        source = new MockPriceSource(1e18);

        // the callback fires on transferFrom, which fund() calls for both legs, so it
        // does not matter which slot the callback token lands in
        plain = new MockERC20("PLAIN", "PLAIN", 18);
        cb = new CallbackERC20("CB", "CB");
        (c0, c1) = address(plain) < address(cb) ? (address(plain), address(cb)) : (address(cb), address(plain));

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();

        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        _endow(address(this));
        _endow(address(poker));
    }

    function _cfg() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: 3000,
            feeCap: 3500, // low enough that a 100-tick guard clears the dead band rule
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 1000,
            backstopHalfTicks: 16000,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 100,
            enabled: true
        });
    }

    function _endow(address who) internal {
        plain.mint(who, 20_000_000e18);
        cb.mint(who, 20_000_000e18);
        vm.startPrank(who);
        plain.approve(address(hook), type(uint256).max);
        cb.approve(address(hook), type(uint256).max);
        plain.approve(address(swapRouter), type(uint256).max);
        cb.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function bal0(address who) internal view returns (uint256) {
        return c0 == address(plain) ? plain.balanceOf(who) : cb.balanceOf(who);
    }

    function bal1(address who) internal view returns (uint256) {
        return c1 == address(plain) ? plain.balanceOf(who) : cb.balanceOf(who);
    }

    function poolTick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    // ---------- the attack

    /// A first fund to give the pool liquidity, then a top-up during which the token
    /// moves the price past the guard. The gate reads the same price the mint would,
    /// so it refuses.
    function test_tokenMovesThePoolMidTransfer_isCaught() public {
        hook.fund(id, FUND, FUND);
        assertEq(poolTick(), 0, "pool starts on the oracle");

        poker.arm(key, -600);
        cb.setCallback(address(poker));

        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);

        // the revert unwinds the poker's own counter too, so that the callback fires at
        // all is shown by test_aSmallMidTransferNudge_isToleratedAndUsed, where it does
        // not revert. Here the revert is the proof: without the callback the identical
        // top-up succeeds (test_withoutTheCallback_theSameTopUpSucceeds).
        assertEq(poolTick(), 0, "and the pool is back where it started");
    }

    /// Without the callback the identical top-up goes through, so the refusal above
    /// is the guard working and not the pool being broken.
    function test_withoutTheCallback_theSameTopUpSucceeds() public {
        hook.fund(id, FUND, FUND);
        (,,, uint128 before) = hook.core(id);

        hook.fund(id, FUND, FUND);
        (,,, uint128 liqAfter) = hook.core(id);

        assertGt(liqAfter, before, "the top-up landed");
        assertEq(poker.fired(), 0, "no callback involved");
    }

    /// A nudge the guard tolerates still funds, and the band is built against the
    /// price as it stands after the nudge rather than before it.
    function test_aSmallMidTransferNudge_isToleratedAndUsed() public {
        hook.fund(id, FUND, FUND);

        poker.arm(key, -50); // inside the 100-tick guard
        cb.setCallback(address(poker));

        hook.fund(id, FUND, FUND);
        assertEq(poker.fired(), 1, "the callback ran");
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "and the fund still landed");
    }

    /// Nothing moves on a refusal: the owner keeps both balances and the existing
    /// position is untouched.
    function test_theRefusalLeavesEverythingWhereItWas() public {
        hook.fund(id, FUND, FUND);
        (int24 lo, int24 hi,, uint128 liqBefore) = hook.core(id);
        uint256 b0 = bal0(address(this));
        uint256 b1 = bal1(address(this));

        poker.arm(key, -600);
        cb.setCallback(address(poker));
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);

        assertEq(bal0(address(this)), b0, "token0 untouched");
        assertEq(bal1(address(this)), b1, "token1 untouched");
        (,,, uint128 liqAfter) = hook.core(id);
        assertEq(liqAfter, liqBefore, "the position survived");
        (uint128 held,,) = manager.getPositionInfo(id, HOOK_ADDR, lo, hi, bytes32(0));
        assertEq(held, liqBefore, "and the PoolManager agrees");
    }

    /// The gate is gone from fund(), so its errors now arrive from inside the unlock.
    /// They must still reach the caller unchanged.
    function test_theGuardErrorsStillReachTheCaller() public {
        // stale
        skip(2 hours);
        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.fund(id, FUND, FUND);

        // and out of guard, without any callback
        source.set(1e18, block.timestamp);
        source.set(1.05e18, block.timestamp); // ~487 ticks away, guard is 100
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.fund(id, FUND, FUND);
    }
}
