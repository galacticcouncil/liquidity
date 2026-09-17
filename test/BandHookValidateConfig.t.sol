// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
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

/// A configuration the hook accepts must be one the PoolManager will also accept.
contract BandHookValidateConfigTest is Test {
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
    int24 constant MAX_TICK = TickMath.MAX_TICK; // 887272
    int24 constant MAX_HALF_BAND = MAX_TICK / 4; // halfBandTicks * MAX_EXTENSION_MULT must fit

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

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
    }

    function _base() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: 3000,
            feeCap: 20000,
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

    function _expectRejected(BandHook.PoolConfig memory cfg) internal {
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.configure(key, cfg);
    }

    /// @notice Read the fee the pool actually charged, from the Swap event.
    function _swapFee(int256 amt) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no swap event");
    }

    // ---------- the fee ceiling

    /// Exactly 100% is the largest fee Uniswap accepts, so the hook accepts it too.
    function test_feeCap_atMaxLpFee_isAccepted() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.feeCap = LPFeeLibrary.MAX_LP_FEE;
        hook.configure(key, cfg);
        (, uint24 floorFee, uint24 capFee,,,,,,,,) = hook.config(id);
        assertEq(capFee, 1_000_000, "cap stored");
        assertEq(floorFee, 3000, "floor stored");
    }

    /// One ppm above it is rejected. This used to be accepted, and then swaps that
    /// computed a fee above 100% reverted LPFeeTooLarge.
    function test_feeCap_oneAboveMaxLpFee_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.feeCap = LPFeeLibrary.MAX_LP_FEE + 1;
        _expectRejected(cfg);
    }

    /// The measured case: a cap of 2,000,000 configured cleanly before.
    function test_feeCap_twoMillion_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.feeCap = 2_000_000;
        _expectRejected(cfg);
    }

    /// The worst one: a floor above 100% made every swap revert, for good.
    function test_feeFloor_aboveMaxLpFee_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.feeFloor = 1_000_001;
        cfg.feeCap = 1_000_001;
        _expectRejected(cfg);
    }

    /// The old bound was the override bit flag, 4,194,304. Anything under it passed.
    function test_feeCap_justBelowTheOldBound_isNowRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.feeCap = LPFeeLibrary.OVERRIDE_FEE_FLAG - 1;
        _expectRejected(cfg);
    }

    // ---------- the silent kill switch

    /// Zero seconds means every reading is already stale: the fee pins to the floor and
    /// recenter reverts forever. An unset environment variable reads as zero.
    function test_staleAfter_zero_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.staleAfter = 0;
        _expectRejected(cfg);
    }

    function test_staleAfter_oneSecond_isAccepted() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.staleAfter = 1;
        hook.configure(key, cfg);
    }

    // ---------- band bounds, checked before the mint rather than during it

    /// The measured case: accepted by _validate, then fund reverted on int24 overflow.
    function test_halfBandTicks_absurdlyLarge_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.halfBandTicks = 3_000_000;
        cfg.backstopHalfTicks = 3_000_000;
        _expectRejected(cfg);
    }

    /// The boundary: halfBandTicks * 4 may reach MAX_TICK exactly.
    function test_halfBandTicks_atTheBoundary_isAccepted() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.halfBandTicks = MAX_HALF_BAND; // 221818, x4 = 887272 = MAX_TICK
        cfg.backstopHalfTicks = MAX_HALF_BAND;
        hook.configure(key, cfg);
    }

    function test_halfBandTicks_oneAboveTheBoundary_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.halfBandTicks = MAX_HALF_BAND + 1;
        cfg.backstopHalfTicks = MAX_HALF_BAND + 1;
        _expectRejected(cfg);
    }

    function test_backstopHalfTicks_beyondMaxTick_isRejected() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.halfBandTicks = 1000;
        cfg.backstopHalfTicks = MAX_TICK + 1;
        _expectRejected(cfg);
    }

    // ---------- the field that is unchecked on purpose

    /// A slope of zero is a supported configuration: a flat fee at the floor. Rejecting
    /// every zero would break it, so it stays unchecked.
    function test_feeSlopeZero_isAcceptedAndGivesAFlatFee() public {
        BandHook.PoolConfig memory cfg = _base();
        cfg.feeSlopePpm = 0;
        hook.configure(key, cfg);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.fund(id, 100_000e18, 100_000e18);

        assertEq(_swapFee(-1e18), 3000, "floor fee with the oracle on the pool");

        source.set(1.05e18, block.timestamp); // ~490 ticks of divergence
        assertEq(_swapFee(-1e18), 3000, "still the floor, because the slope is zero");
    }

    // ---------- the same rules apply to setParams

    function test_setParams_appliesTheSameRules() public {
        hook.configure(key, _base());

        BandHook.PoolConfig memory bad = _base();
        bad.feeCap = 2_000_000;
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setParams(id, bad);

        BandHook.PoolConfig memory stale = _base();
        stale.staleAfter = 0;
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setParams(id, stale);
    }

    /// No regression: the three real launch configurations still validate.
    function test_launchConfigurations_stillValidate() public {
        BandHook.PoolConfig memory ethHollar = _base();
        ethHollar.feeFloor = 800;
        ethHollar.feeCap = 10000;
        ethHollar.staleAfter = 100800;
        ethHollar.halfBandTicks = 700;
        ethHollar.backstopHalfTicks = 11000;
        ethHollar.backstopBps = 3500;
        ethHollar.triggerTicks = 350;
        ethHollar.guardTicks = 150;
        hook.configure(key, ethHollar);

        PoolKey memory k2 = key;
        k2.tickSpacing = 60;
        BandHook.PoolConfig memory hdx = _base();
        hdx.feeFloor = 3000;
        hdx.feeCap = 20000;
        hdx.staleAfter = 7200;
        hdx.halfBandTicks = 1000;
        hdx.backstopHalfTicks = 16000;
        hdx.backstopBps = 3500;
        hdx.triggerTicks = 500;
        hdx.guardTicks = 200;
        hook.configure(k2, hdx);
    }
}
