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

/// After any number of fund() calls the hook holds exactly one core position,
/// and what it records is what the PoolManager holds.
contract BandHookFundBurnsOldCoreTest is Test {
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
    bytes32 constant BACKSTOP_SALT = bytes32(uint256(1));
    uint256 constant FUND = 100_000e18;

    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

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

        hook.configure(key, _cfg(16000));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? bob : carol;
            t0.mint(who, 5_000_000e18);
            t1.mint(who, 5_000_000e18);
            vm.startPrank(who);
            t0.approve(address(swapRouter), type(uint256).max);
            t1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _cfg(int24 backstopHalfTicks) internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: 3000,
            feeCap: 20000,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 1000,
            backstopHalfTicks: backstopHalfTicks,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 100,
            enabled: true
        });
    }

    // ---------- helpers

    /// @notice Liquidity the PoolManager credits to the hook at these bounds.
    function heldByManager(int24 lower, int24 upper, bytes32 salt) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, salt);
    }

    function heldByManagerIn(PoolId pid, int24 lower, int24 upper, bytes32 salt) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(pid, HOOK_ADDR, lower, upper, salt);
    }

    /// @notice The hook's own record of its core band.
    function coreRecord() internal view returns (int24 lower, int24 upper, int24 center, uint128 liq) {
        return hook.core(id);
    }

    /// @notice The hook's own record of its backstop band.
    function backstopRecord() internal view returns (int24 lower, int24 upper, int24 center, uint128 liq) {
        return hook.backstop(id);
    }

    /// @notice Move the pool price to roughly `target` by trading against it as `who`.
    function pushPoolToTick(address who, int24 target) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        bool zeroForOne = limit < _poolSqrt();
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -2_000_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function poolTick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _poolSqrt() internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(id);
    }

    /// @notice Move the oracle, keeping it fresh.
    function setOracleTick(int24 t) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        uint256 px96 = FullMath.mulDiv(s, s, 1 << 96);
        source.set(FullMath.mulDiv(px96, 1e18, 1 << 96), block.timestamp);
    }

    /// @notice Everything the owner holds of both tokens.
    function ownerBalances() internal view returns (uint256 a0, uint256 a1) {
        return (t0.balanceOf(address(this)), t1.balanceOf(address(this)));
    }

    /// @notice Assert the record and the PoolManager agree about the core band.
    function assertCoreRecordMatchesManager() internal view {
        (int24 lo, int24 hi,, uint128 recorded) = coreRecord();
        assertEq(recorded, heldByManager(lo, hi, CORE_SALT), "core record != PoolManager");
    }

    /// @notice Assert the hook has nothing left anywhere after a withdraw.
    function assertNothingLeftBehind(int24[] memory lowers, int24[] memory uppers) internal view {
        for (uint256 i = 0; i < lowers.length; i++) {
            assertEq(heldByManager(lowers[i], uppers[i], CORE_SALT), 0, "core liquidity left in the PoolManager");
            assertEq(heldByManager(lowers[i], uppers[i], BACKSTOP_SALT), 0, "backstop liquidity left behind");
        }
        assertEq(t0.balanceOf(HOOK_ADDR), 0, "token0 left idle in the hook");
        assertEq(t1.balanceOf(HOOK_ADDR), 0, "token1 left idle in the hook");
    }

    function bounds2(int24 a, int24 b, int24 c, int24 d)
        internal
        pure
        returns (int24[] memory lo, int24[] memory hi)
    {
        lo = new int24[](2);
        hi = new int24[](2);
        lo[0] = a;
        hi[0] = b;
        lo[1] = c;
        hi[1] = d;
    }

    function logPositions(string memory label) internal view {
        (int24 cl, int24 cu,, uint128 cliq) = coreRecord();
        (int24 bl, int24 bu,, uint128 bliq) = backstopRecord();
        console2.log(label);
        console2.log(
            string.concat(
                "  core   record ",
                vm.toString(uint256(cliq)),
                "  manager ",
                vm.toString(uint256(heldByManager(cl, cu, CORE_SALT)))
            )
        );
        console2.log(
            string.concat(
                "  backstop record ",
                vm.toString(uint256(bliq)),
                "  manager ",
                vm.toString(uint256(heldByManager(bl, bu, BACKSTOP_SALT)))
            )
        );
    }

    // ---------- the cases

    /// 1. Alice funds 100k+100k twice at an unmoved price.
    function test_topUpAtTheSamePrice_recordMatchesManager() public {
        hook.fund(id, FUND, FUND);
        (int24 lo1, int24 hi1,,) = coreRecord();

        hook.fund(id, FUND, FUND);
        (int24 lo2, int24 hi2,, uint128 recorded2) = coreRecord();

        assertEq(lo2, lo1, "same price, so the same bounds");
        assertEq(hi2, hi1, "same price, so the same bounds");
        assertCoreRecordMatchesManager();
        assertGt(recorded2, 0, "a core position exists");

        (uint256 b0, uint256 b1) = ownerBalances();
        hook.withdraw(id);
        (uint256 a0, uint256 a1) = ownerBalances();

        (int24 bl, int24 bu,,) = backstopRecord();
        (int24[] memory lows, int24[] memory highs) = bounds2(lo1, hi1, bl, bu);
        assertNothingLeftBehind(lows, highs);

        assertApproxEqAbs(a0 - b0, 2 * FUND, 1e15, "token0 returned");
        assertApproxEqAbs(a1 - b1, 2 * FUND, 1e15, "token1 returned");
    }

    /// 2. Alice funds, Bob moves the price 300 ticks, Alice tops up.
    function test_topUpAfterAPriceMove_oldBandIsGone() public {
        hook.fund(id, FUND, FUND);
        (int24 lo1, int24 hi1,,) = coreRecord();

        pushPoolToTick(bob, 300);
        setOracleTick(poolTick());

        hook.fund(id, FUND, FUND);
        (int24 lo2, int24 hi2,,) = coreRecord();

        assertTrue(lo2 != lo1 || hi2 != hi1, "the band moved with the price");
        assertEq(heldByManager(lo1, hi1, CORE_SALT), 0, "nothing left at the old bounds");
        assertCoreRecordMatchesManager();

        hook.withdraw(id);
        (int24 bl, int24 bu,,) = backstopRecord();
        (int24[] memory lows, int24[] memory highs) = bounds2(lo1, hi1, bl, bu);
        assertNothingLeftBehind(lows, highs);
        assertEq(heldByManager(lo2, hi2, CORE_SALT), 0, "nothing left at the new bounds either");
    }

    /// 3. Alice funds, then calls fund(id, 0, 0).
    function test_zeroAmountFund_replacesRatherThanDestroys() public {
        hook.fund(id, FUND, FUND);
        (int24 lo, int24 hi,, uint128 before) = coreRecord();

        hook.fund(id, 0, 0);
        (int24 lo2, int24 hi2,, uint128 afterZero) = coreRecord();

        assertEq(lo2, lo, "same price, so the same bounds");
        assertEq(hi2, hi, "same price, so the same bounds");
        assertApproxEqRel(afterZero, before, 1e9, "the core is re-placed, not destroyed");
        assertCoreRecordMatchesManager();

        (uint256 b0, uint256 b1) = ownerBalances();
        hook.withdraw(id);
        (uint256 a0, uint256 a1) = ownerBalances();

        (int24 bl, int24 bu,,) = backstopRecord();
        (int24[] memory lows, int24[] memory highs) = bounds2(lo, hi, bl, bu);
        assertNothingLeftBehind(lows, highs);

        assertApproxEqAbs(a0 - b0, FUND, 1e15, "token0 returned");
        assertApproxEqAbs(a1 - b1, FUND, 1e15, "token1 returned");
    }

    /// 4. Alice funds a fresh pool once: both bands minted, records match, nothing stranded.
    function test_firstFund_unchanged() public {
        hook.fund(id, FUND, FUND);

        (int24 lo, int24 hi,, uint128 cliq) = coreRecord();
        (int24 bl, int24 bu,, uint128 bliq) = backstopRecord();

        assertGt(cliq, 0, "core minted");
        assertGt(bliq, 0, "backstop minted");
        assertEq(cliq, heldByManager(lo, hi, CORE_SALT), "core record matches");
        assertEq(bliq, heldByManager(bl, bu, BACKSTOP_SALT), "backstop record matches");
        assertLt(bl, lo, "backstop is wider on the low side");
        assertGt(bu, hi, "backstop is wider on the high side");

        (uint256 b0, uint256 b1) = ownerBalances();
        hook.withdraw(id);
        (uint256 a0, uint256 a1) = ownerBalances();

        (int24[] memory lows, int24[] memory highs) = bounds2(lo, hi, bl, bu);
        assertNothingLeftBehind(lows, highs);
        assertApproxEqAbs(a0 - b0, FUND, 1e15, "token0 returned");
        assertApproxEqAbs(a1 - b1, FUND, 1e15, "token1 returned");
    }

    /// 5. Alice funds three times in a row.
    function test_threeFunds_stillOneCorePosition() public {
        hook.fund(id, FUND, FUND);
        hook.fund(id, FUND, FUND);
        hook.fund(id, FUND, FUND);

        (int24 lo, int24 hi,, uint128 recorded) = coreRecord();
        assertEq(recorded, heldByManager(lo, hi, CORE_SALT), "one position, fully recorded");

        (uint256 b0, uint256 b1) = ownerBalances();
        hook.withdraw(id);
        (uint256 a0, uint256 a1) = ownerBalances();

        (int24 bl, int24 bu,,) = backstopRecord();
        (int24[] memory lows, int24[] memory highs) = bounds2(lo, hi, bl, bu);
        assertNothingLeftBehind(lows, highs);
        assertApproxEqAbs(a0 - b0, 3 * FUND, 1e15, "token0 returned");
        assertApproxEqAbs(a1 - b1, 3 * FUND, 1e15, "token1 returned");
    }

    /// 6. Alice funds, Bob moves the price, Alice tops up, then Carol recenters.
    function test_topUpThenRecenter_stillOneCore() public {
        hook.fund(id, FUND, FUND);

        pushPoolToTick(bob, 600);
        setOracleTick(poolTick());
        hook.fund(id, FUND, FUND);
        (int24 loAfterFund, int24 hiAfterFund, int24 centerAfterFund,) = coreRecord();

        pushPoolToTick(bob, 1400);
        setOracleTick(poolTick());
        assertGt(
            uint256(int256(poolTick() - centerAfterFund)), uint256(int256(int24(500))), "drift is past the trigger"
        );

        vm.prank(carol);
        hook.recenter(id);

        (int24 lo, int24 hi,, uint128 recorded) = coreRecord();
        assertEq(heldByManager(loAfterFund, hiAfterFund, CORE_SALT), 0, "the funded band was burned by recenter");
        assertEq(recorded, heldByManager(lo, hi, CORE_SALT), "one position, fully recorded");

        hook.withdraw(id);
        (int24 bl, int24 bu,,) = backstopRecord();
        (int24[] memory lows, int24[] memory highs) = bounds2(lo, hi, bl, bu);
        assertNothingLeftBehind(lows, highs);
        assertEq(heldByManager(loAfterFund, hiAfterFund, CORE_SALT), 0, "old band still empty");
    }

    /// 7. Alice funds twice: the backstop is minted once and never touched again.
    function test_backstopMintedOnceAndUntouched() public {
        hook.fund(id, FUND, FUND);
        (int24 bl1, int24 bu1,, uint128 bliq1) = backstopRecord();
        assertGt(bliq1, 0, "backstop minted on the first fund");

        hook.fund(id, FUND, FUND);
        (int24 bl2, int24 bu2,, uint128 bliq2) = backstopRecord();

        assertEq(bl2, bl1, "backstop bounds unchanged");
        assertEq(bu2, bu1, "backstop bounds unchanged");
        assertEq(bliq2, bliq1, "backstop liquidity unchanged by the second fund");
        assertEq(bliq2, heldByManager(bl1, bu1, BACKSTOP_SALT), "backstop record matches the manager");
    }

    /// 8. Alice funds, Bob moves the price clear of the old band, Alice tops up.
    function test_topUpFarFromTheOldBand_nothingLeftBehind() public {
        hook.fund(id, FUND, FUND);
        (int24 lo1, int24 hi1,,) = coreRecord();

        pushPoolToTick(bob, 3000);
        setOracleTick(poolTick());

        hook.fund(id, FUND, FUND);
        (int24 lo2, int24 hi2,,) = coreRecord();

        assertGt(lo2, hi1, "the new band does not overlap the old one");
        assertEq(heldByManager(lo1, hi1, CORE_SALT), 0, "nothing left at the old bounds");
        assertCoreRecordMatchesManager();

        hook.withdraw(id);
        (int24 bl, int24 bu,,) = backstopRecord();
        (int24[] memory lows, int24[] memory highs) = bounds2(lo2, hi2, bl, bu);
        assertNothingLeftBehind(lows, highs);
        assertEq(heldByManager(lo1, hi1, CORE_SALT), 0, "old band still empty");
    }

    /// 9. Alice funds while the feed has gone quiet: the band centres on the pool price.
    /// @dev Pins the `fresh ? oracleTick : poolTick` fallback. Audit finding C1 is that this
    /// branch exists at all; when C1 is fixed this call reverts StaleOracle instead.
    function test_staleOracle_centresOnThePoolPrice() public {
        hook.fund(id, FUND, FUND);
        (int24 lo1, int24 hi1,,) = coreRecord();

        pushPoolToTick(bob, 300);
        int24 pool = poolTick();
        skip(2 hours);

        hook.fund(id, FUND, FUND);
        (,, int24 center,) = coreRecord();

        assertEq(center, pool, "centre came from the pool price, not the oracle");
        assertEq(heldByManager(lo1, hi1, CORE_SALT), 0, "the old band was still burned");
        assertCoreRecordMatchesManager();
    }

    /// 10. A pool configured with no backstop: only the core is ever minted.
    function test_noBackstopConfigured_onlyCoreIsMinted() public {
        PoolKey memory k2 = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        PoolId id2 = k2.toId();

        hook.configure(k2, _cfg(0));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));

        hook.fund(id2, FUND, FUND);
        (,,, uint128 bliq) = hook.backstop(id2);
        (int24 lo, int24 hi,, uint128 cliq) = hook.core(id2);

        assertEq(bliq, 0, "no backstop was minted");
        assertGt(cliq, 0, "the core was minted");
        assertEq(cliq, heldByManagerIn(id2, lo, hi, CORE_SALT), "core record matches");

        hook.fund(id2, FUND, FUND);
        (int24 lo2, int24 hi2,, uint128 cliq2) = hook.core(id2);
        assertEq(cliq2, heldByManagerIn(id2, lo2, hi2, CORE_SALT), "still one position after a top-up");
        (,,, uint128 bliq2) = hook.backstop(id2);
        assertEq(bliq2, 0, "still no backstop");
    }
}
