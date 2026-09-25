// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Five guard rails, none of which fires at the launch values, all of which make a
/// bad state unreachable on a contract that cannot be upgraded.
/// R7 and R11: the guard, the trigger and staleAfter bounded against the band and the clock.
/// R9: the hook checks its own permission bits. R10: the freshness check subtracts.
/// R13: the native settle syncs first, as v4-core instructs.
contract BandHookGuardRailsTest is Test {
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

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    int24 constant HALF = 1000;

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
        hook.configure(key, _base());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(hollar)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        nativeId = nativeKey.toId();
        BandHook.PoolConfig memory nc = _base();
        nc.source = IPriceSource(address(nativeSource));
        nc.guardTicks = 300;
        hook.configure(nativeKey, nc);
        manager.initialize(nativeKey, TickMath.getSqrtPriceAtTick(78244));

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        hollar.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        hollar.approve(address(hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 1000 ether);
    }

    function _base() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: 3000,
            feeCap: 20000,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: HALF,
            backstopHalfTicks: 16000,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 300,
            enabled: true,
            autoRecenter: false
        });
    }

    /// A key nobody has configured yet, so `configure` can be tried repeatedly.
    function _freshKey(int24 spacing) internal view returns (PoolKey memory k) {
        k = key;
        k.tickSpacing = spacing;
    }

    function _swapFee(PoolKey memory k) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
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

    // ---------- R9: the hook checks its own address

    /// A hook deployed anywhere but a correctly mined address refuses to exist. Without
    /// this the PoolManager accepts it, the pool works, and every swap is charged 0 ppm.
    function test_R9_deployingAtAWrongAddress_reverts() public {
        vm.expectRevert(BandHook.BadConfig.selector);
        new BandHook(manager, address(this));
    }

    /// And the mined address is accepted, which the whole suite depends on.
    function test_R9_theMinedAddressIsAccepted() public view {
        assertEq(uint160(HOOK_ADDR) & 0x3FFF, 0x10C0, "afterInitialize | beforeSwap | afterSwap");
        assertEq(address(hook), HOOK_ADDR, "and the hook lives there");
    }

    // ---------- R10: the freshness check subtracts

    /// A timestamp at the top of uint256 used to make `updatedAt + staleAfter` overflow
    /// inside beforeSwap, which stopped every swap in the pool.
    function test_R10_anAbsurdTimestampDoesNotBrickSwaps() public {
        hook.fund(id, FUND, FUND);
        source.set(1e18, type(uint256).max);
        assertEq(_swapFee(key), 3000, "treated as no price, so the floor fee, and no panic");
    }

    /// A feed reporting the future is broken, not fresh.
    function test_R10_aFutureTimestampIsNotFresh() public {
        hook.fund(id, FUND, FUND);
        source.set(1.05e18, block.timestamp + 365 days);
        assertEq(_swapFee(key), 3000, "floor fee, because a future reading is not trusted");

        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.recenter(id);
    }

    /// An ordinary fresh reading still works, so the new form did not break freshness.
    function test_R10_anOrdinaryReadingIsStillFresh() public {
        hook.fund(id, FUND, FUND);
        source.set(1.005e18, block.timestamp);
        assertGt(_swapFee(key), 3000, "the divergence term is applied");
    }

    // ---------- R7 and R11: the guard and the trigger live inside the band

    function test_R7_guardAtTheBandWidth_isRejected() public {
        BandHook.PoolConfig memory c = _base();
        c.guardTicks = HALF;
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.configure(_freshKey(60), c);
    }

    function test_R7_guardOneInsideTheBandWidth_isAccepted() public {
        BandHook.PoolConfig memory c = _base();
        c.guardTicks = HALF - 1;
        hook.configure(_freshKey(60), c);
    }

    function test_R11_triggerAtTheBandWidth_isRejected() public {
        BandHook.PoolConfig memory c = _base();
        c.triggerTicks = HALF;
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.configure(_freshKey(60), c);
    }

    function test_R11_staleAfterCeiling() public {
        BandHook.PoolConfig memory c = _base();
        c.staleAfter = 7 days;
        hook.configure(_freshKey(60), c);

        c.staleAfter = 7 days + 1;
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.configure(_freshKey(200), c);
    }

    /// setParams applies the same rules, so a live pool cannot be walked into the bad state.
    function test_R7_setParamsAppliesTheSameRules() public {
        BandHook.PoolConfig memory c = _base();
        c.guardTicks = HALF + 500;
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setParams(id, c);
    }

    /// The launch configurations as issue #2 set them all pass these rails too: ETH/HOLLAR
    /// guard 200, and HDX guard 300 (R4's proposal, now adopted).
    function test_theLaunchValuesValidate() public {
        BandHook.PoolConfig memory eth = _base();
        eth.feeFloor = 800; eth.feeCap = 10000; eth.staleAfter = 100800;
        eth.halfBandTicks = 700; eth.backstopHalfTicks = 11000; eth.backstopBps = 3500;
        eth.triggerTicks = 350; eth.guardTicks = 200;
        hook.configure(_freshKey(60), eth);

        BandHook.PoolConfig memory hdx = _base();
        hdx.staleAfter = 7200; hdx.halfBandTicks = 1000; hdx.backstopHalfTicks = 16000;
        hdx.backstopBps = 3500; hdx.triggerTicks = 500; hdx.guardTicks = 300; // R4's proposal
        hook.configure(_freshKey(200), hdx);
    }

    // ---------- R13: the native settle syncs first

    /// Somebody syncs another currency earlier in the same transaction. Without the hook's
    /// own sync, v4 takes the ERC20 path and the native settle reverts NonzeroNativeValue.
    function test_R13_aDirtiedSyncSlotDoesNotBreakNativeFunding() public {
        manager.sync(Currency.wrap(address(t0)));
        hook.fund{value: 10 ether}(nativeId, 10 ether, 25_000e18);
        (,,, uint128 cliq) = hook.core(nativeId);
        assertGt(cliq, 0, "the native pool funded despite the dirty slot");
    }

    /// And the ordinary path is unchanged.
    function test_R13_nativeFundingStillWorksNormally() public {
        hook.fund{value: 10 ether}(nativeId, 10 ether, 25_000e18);
        (,,, uint128 cliq) = hook.core(nativeId);
        assertGt(cliq, 0, "funded");
        assertEq(HOOK_ADDR.balance, 0, "no ETH stuck in the hook");
    }

    receive() external payable {}
}
