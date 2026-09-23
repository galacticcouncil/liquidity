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
import {ToggleRevertSource} from "./mocks/SourceMocks.sol";

/// A pool whose price source stops answering must be recoverable in place.
contract BandHookSetSourceTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    ToggleRevertSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    address carol = makeAddr("carol");
    uint256 constant FUND = 100_000e18;
    uint24 constant FLOOR = 3000;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        source = new ToggleRevertSource(1e18);

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

        hook.configure(key, _cfg(IPriceSource(address(source))));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
    }

    function _cfg(IPriceSource src) internal pure returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: src,
            feeFloor: FLOOR,
            feeCap: 20000,
            feeSlopePpm: 1_000_000,
            staleAfter: 1 hours,
            halfBandTicks: 1000,
            backstopHalfTicks: 16000,
            backstopBps: 3000,
            triggerTicks: 500,
            guardTicks: 300,
            enabled: true,
            autoRecenter: false
        });
    }

    function _swap() internal {
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapFee() internal returns (uint24 fee) {
        vm.recordLogs();
        _swap();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no swap event");
    }

    function _currentSource() internal view returns (address s) {
        (IPriceSource src,,,,,,,,,,,) = hook.config(id);
        return address(src);
    }

    // ---------- the recovery path

    /// The whole point: a source that stops answering used to end the pool. Now the
    /// owner can replace it, and everything works again.
    function test_setSource_recoversAPoolWhoseSourceReverts() public {
        hook.fund(id, FUND, FUND);
        assertEq(_swapFee(), FLOOR, "trading normally to start with");

        source.kill();

        vm.expectRevert();
        _swap();

        vm.expectRevert();
        hook.recenter(id);

        MockPriceSource replacement = new MockPriceSource(1e18);
        hook.setSource(id, IPriceSource(address(replacement)), 0, 50);

        assertEq(_currentSource(), address(replacement), "source replaced");
        // the earlier swap moved the pool a tick off the oracle, so the fee is the floor
        // plus that one tick of divergence rather than exactly the floor
        assertApproxEqAbs(_swapFee(), FLOOR, 200, "the pool trades again, priced off the new source");
    }

    /// setSource must never touch the old source, or it could not run on a dead pool.
    function test_setSource_worksWithoutCallingTheOldSource() public {
        source.kill();
        MockPriceSource replacement = new MockPriceSource(1e18);
        hook.setSource(id, IPriceSource(address(replacement)), 0, 50);
        assertEq(_currentSource(), address(replacement), "replaced while the old one reverts");
    }

    /// Withdraw was always possible; check the fix did not change that.
    function test_withdrawStillWorksWhileTheSourceIsDead() public {
        hook.fund(id, FUND, FUND);
        source.kill();
        uint256 before0 = t0.balanceOf(address(this));
        hook.withdraw(id);
        assertGt(t0.balanceOf(address(this)), before0, "funds come back regardless");
    }

    // ---------- what setSource refuses

    function test_setSource_notOwner_reverts() public {
        MockPriceSource replacement = new MockPriceSource(1e18);
        vm.prank(carol);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.setSource(id, IPriceSource(address(replacement)), 0, 50);
    }

    function test_setSource_rejectsTheZeroAddress() public {
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, IPriceSource(address(0)), 0, 50);
    }

    /// A replacement that has no price is refused, so the pool is not swapped from one
    /// broken source to another.
    function test_setSource_rejectsASourceWithNoPrice() public {
        MockPriceSource dead = new MockPriceSource(0);
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, IPriceSource(address(dead)), 0, 50);
    }

    function test_setSource_rejectsAStaleSource() public {
        MockPriceSource old = new MockPriceSource(1e18);
        old.set(1e18, block.timestamp);
        skip(2 hours); // staleAfter is 1 hour
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, IPriceSource(address(old)), 0, 50);
    }

    /// Bob installs a source whose clock runs 10 minutes ahead: refused with BadConfig. The
    /// old check accepted it, and then every swap read the price as stale.
    function test_setSource_rejectsASourceFromTheFuture() public {
        MockPriceSource ahead = new MockPriceSource(1e18);
        ahead.set(1e18, block.timestamp + 10 minutes);
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, IPriceSource(address(ahead)), 0, 50);
        assertEq(_currentSource(), address(source), "the old source stays");
    }

    /// A source reporting the largest possible timestamp: BadConfig, not an overflow panic.
    function test_setSource_rejectsAnAbsurdTimestampWithBadConfig() public {
        MockPriceSource absurd = new MockPriceSource(1e18);
        absurd.set(1e18, type(uint256).max);
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, IPriceSource(address(absurd)), 0, 50);
    }

    /// A replacement that reverts takes the revert with it, rather than being installed.
    function test_setSource_rejectsARevertingSource() public {
        ToggleRevertSource bad = new ToggleRevertSource(1e18);
        bad.kill();
        vm.expectRevert();
        hook.setSource(id, IPriceSource(address(bad)), 0, 50);
        assertEq(_currentSource(), address(source), "the old source is still in place");
    }

    function test_setSource_onAnUnconfiguredPool_reverts() public {
        PoolKey memory other = key;
        other.tickSpacing = 60;
        MockPriceSource replacement = new MockPriceSource(1e18);
        vm.expectRevert(BandHook.NotEnabled.selector);
        hook.setSource(other.toId(), IPriceSource(address(replacement)), 0, 50);
    }

    /// setParams is still not a way to change the source.
    function test_setParams_stillRefusesToChangeTheSource() public {
        MockPriceSource replacement = new MockPriceSource(1e18);
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setParams(id, _cfg(IPriceSource(address(replacement))));
    }

    // ---------- the event, which is what a multisig reviews

    /// The event carries the tick the new source implies, so a wrongly-oriented
    /// replacement is visible after the fact even though it is not checked on chain.
    function test_setSource_emitsTheOldAddressTheNewAddressAndTheNewTick() public {
        MockPriceSource replacement = new MockPriceSource(2e18); // ~6931 ticks above 1.0
        vm.recordLogs();
        hook.setSource(id, IPriceSource(address(replacement)), 6931, 5);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SourceChanged(bytes32,address,address,int24)")) {
                (address oldS, address newS, int24 tick) = abi.decode(logs[i].data, (address, address, int24));
                assertEq(oldS, address(source), "old source in the event");
                assertEq(newS, address(replacement), "new source in the event");
                assertApproxEqAbs(int256(tick), 6931, 2, "the tick the new source implies");
                found = true;
            }
        }
        assertTrue(found, "SourceChanged was emitted");
    }

    /// After a replacement the fee is computed from the new source, not the old one.
    function test_setSource_changesWhatTheFeeIsMeasuredAgainst() public {
        hook.fund(id, FUND, FUND);
        assertEq(_swapFee(), FLOOR, "pool and source agree at first");

        MockPriceSource shifted = new MockPriceSource(1.01e18); // ~100 ticks away
        hook.setSource(id, IPriceSource(address(shifted)), 99, 5);

        uint24 fee = _swapFee();
        assertGt(fee, FLOOR, "the fee now reflects the new source");
        console2.log(string.concat("  fee after replacing the source: ", vm.toString(uint256(fee))));
    }

    // ---------- the expected-tick guard

    /// The mistake the contract cannot otherwise catch: a source oriented the wrong way
    /// round. It answers, it is fresh, and it is catastrophically wrong.
    function test_setSource_rejectsAnInvertedSource() public {
        // the pool is at 1.0 today; a correct replacement reports ~1.0, this one reports 5.0
        MockPriceSource inverted = new MockPriceSource(5e18);
        vm.expectRevert(abi.encodeWithSelector(BandHook.SourceTickMismatch.selector, int24(0), int24(16095)));
        hook.setSource(id, IPriceSource(address(inverted)), 0, 50);
        assertEq(_currentSource(), address(source), "the old source is untouched");
    }

    /// The error carries the tick the source actually reported, so a multisig reading a
    /// failed simulation learns what is wrong rather than only that something is.
    function test_setSource_mismatchErrorCarriesTheActualTick() public {
        MockPriceSource shifted = new MockPriceSource(2e18);
        try hook.setSource(id, IPriceSource(address(shifted)), 0, 50) {
            revert("should have reverted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), BandHook.SourceTickMismatch.selector, "mismatch error");
            (int24 expected, int24 actual) = abi.decode(_stripSelector(err), (int24, int24));
            assertEq(expected, 0, "what the caller expected");
            assertApproxEqAbs(int256(actual), 6931, 2, "what the source reported");
        }
    }

    function test_setSource_acceptsATickInsideTolerance() public {
        MockPriceSource near = new MockPriceSource(1.001e18); // ~9 ticks
        hook.setSource(id, IPriceSource(address(near)), 0, 20);
        assertEq(_currentSource(), address(near), "inside tolerance, accepted");
    }

    function test_setSource_rejectsATickOutsideTolerance() public {
        MockPriceSource near = new MockPriceSource(1.001e18); // ~9 ticks
        vm.expectRevert();
        hook.setSource(id, IPriceSource(address(near)), 0, 5);
        assertEq(_currentSource(), address(source), "outside tolerance, refused");
    }

    /// Zero tolerance is legal and means the tick must match exactly.
    function test_setSource_zeroToleranceDemandsAnExactTick() public {
        MockPriceSource exact = new MockPriceSource(1e18); // tick 0
        hook.setSource(id, IPriceSource(address(exact)), 0, 0);
        assertEq(_currentSource(), address(exact), "exact match accepted");
    }

    /// A negative tolerance would cast to an enormous unsigned number and disable the
    /// check entirely, so it is refused outright.
    function test_setSource_rejectsANegativeTolerance() public {
        MockPriceSource inverted = new MockPriceSource(5e18);
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, IPriceSource(address(inverted)), 0, -1);
        assertEq(_currentSource(), address(source), "the old source is untouched");
    }

    function _stripSelector(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 4; i < err.length; i++) out[i - 4] = err[i];
    }
}
