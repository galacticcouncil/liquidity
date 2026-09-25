// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Bands wide enough to reach the end of the price range (audit A-1): their edges are cut at the
// last usable tick before any price is taken from them, so every width `_validate` accepts funds.

import {Test} from "forge-std/Test.sol";
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

contract BandHookWideBandsTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    bytes32 constant CORE_SALT = bytes32(0);
    bytes32 constant BACKSTOP_SALT = bytes32(uint256(1));
    int24 constant WIDEST_HALF = 221_818; // 4 x this is MAX_TICK, the most _validate accepts

    IPoolManager manager;
    PoolSwapTest pusher;
    MockPriceSource source;
    BandHook hook;
    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pusher = new PoolSwapTest(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = i == 0 ? t0 : t1;
            t.mint(address(this), 1e36);
            t.approve(address(hook), type(uint256).max);
            t.approve(address(pusher), type(uint256).max);
        }
    }

    function test_aFullRangeBackstop_funds_toTheTopOfTheRange() public {
        PoolId id = _pool(10, 77_836, 700, int24(TickMath.MAX_TICK), 10_000, 350, 200);
        hook.fund(id, 100e18, 240_000e18); // ETH/HOLLAR-like: about 2,400 token1 per token0

        (int24 lower, int24 upper,, uint128 liq) = hook.backstop(id);
        assertEq(upper, TickMath.maxUsableTick(10), "cut at the last usable tick");
        assertGt(lower, TickMath.minUsableTick(10), "the lower side stays inside the range");
        assertApproxEqAbs(lower, 77_836 - 887_272, 10, "at the centre minus the width, within one spacing");
        assertGt(liq, 0, "and it holds liquidity");
        _assertMatchesThePoolManager(id, lower, upper, liq, BACKSTOP_SALT);
    }

    function test_theWidestCore_negativeCentre_token1Surplus_reachesTheBottom() public {
        PoolId id = _pool(60, -14_272, WIDEST_HALF, 0, 20_000, 500, 300);
        hook.fund(id, 1e15, 1_000_000e18); // almost all token1: the core stretches down as far as it may

        (int24 lower, int24 upper,, uint128 liq) = hook.core(id);
        assertEq(lower, TickMath.minUsableTick(60), "the stretch is cut at the first usable tick");
        assertGt(liq, 0);
        _assertMatchesThePoolManager(id, lower, upper, liq, CORE_SALT);
    }

    function test_theWidestCore_positiveCentre_token0Surplus_reachesTheTop() public {
        PoolId id = _pool(60, 14_272, WIDEST_HALF, 0, 20_000, 500, 300);
        hook.fund(id, 1_000_000e18, 1e15); // almost all token0: the core stretches up as far as it may

        (int24 lower, int24 upper,, uint128 liq) = hook.core(id);
        assertEq(upper, TickMath.maxUsableTick(60), "the stretch is cut at the last usable tick");
        assertGt(liq, 0);
        _assertMatchesThePoolManager(id, lower, upper, liq, CORE_SALT);
    }

    function test_theWidestCore_recentersAfterAMove() public {
        PoolId id = _pool(60, -14_272, WIDEST_HALF, 0, 20_000, 500, 300);
        hook.fund(id, 1_000e18, 1_000e18);

        // someone sends the hook a pile of token1, then the market moves 800 ticks up
        t1.transfer(HOOK_ADDR, 1_000_000e18);
        _moveTo(id, -13_472);
        hook.recenter(id);

        (int24 lower, int24 upper, int24 center, uint128 liq) = hook.core(id);
        assertApproxEqAbs(center, -13_472, 1, "recentred on the oracle");
        assertEq(lower, TickMath.minUsableTick(60), "the surplus stretch is cut at the first usable tick");
        _assertMatchesThePoolManager(id, lower, upper, liq, CORE_SALT);
    }

    // ---------- helpers

    PoolKey key;

    /// @dev Configures and initializes a pool on the hook with the oracle and the pool at `tick`.
    function _pool(int24 spacing, int24 tick, int24 half, int24 backstopHalf, uint24 cap, int24 trigger, int24 guard)
        internal
        returns (PoolId id)
    {
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        source.set(_priceAt(tick), block.timestamp);
        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 800,
                feeCap: cap,
                feeSlopePpm: 1_000_000,
                staleAfter: 1 hours,
                halfBandTicks: half,
                backstopHalfTicks: backstopHalf,
                backstopBps: backstopHalf == 0 ? 0 : 3500,
                triggerTicks: trigger,
                guardTicks: guard,
                enabled: true,
                autoRecenter: false
            })
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @dev The oracle moves to `tick` and a trade takes the pool there.
    function _moveTo(PoolId id, int24 tick) internal {
        source.set(_priceAt(tick), block.timestamp);
        (, int24 now_,,) = manager.getSlot0(id);
        bool up = tick > now_;
        pusher.swap(
            key,
            SwapParams({zeroForOne: !up, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The price, in the 1e18 fixed point a source reports, that sits exactly at `tick`.
    function _priceAt(int24 tick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(s, s * 1e18, 1 << 192);
    }

    function _assertMatchesThePoolManager(PoolId id, int24 lower, int24 upper, uint128 liq, bytes32 salt)
        internal
        view
    {
        (uint128 held,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, salt);
        assertEq(held, liq, "the PoolManager holds exactly the recorded liquidity at the recorded edges");
    }
}
