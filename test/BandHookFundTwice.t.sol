// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Funding a pool that already holds a core position: what the hook records
/// against what the PoolManager actually holds.
contract BandHookFundTwiceTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    MockERC20 t0;
    MockERC20 t1;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));
    bytes32 constant CORE_SALT = bytes32(0);
    uint256 constant FUND0 = 100_000e18;
    uint256 constant FUND1 = 100_000e18;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
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

        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 1_000_000e18);
        t1.mint(address(this), 1_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
    }

    function _cfg() internal view returns (BandHook.PoolConfig memory) {
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

    /// liquidity the PoolManager actually credits to the hook at those bounds
    function _heldByManager(int24 lower, int24 upper) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, HOOK_ADDR, lower, upper, CORE_SALT);
    }

    function test_secondFund_strandsPartOfTheCore() public {
        hook.fund(id, FUND0, FUND1);
        (int24 lo1, int24 hi1,, uint128 recorded1) = hook.core(id);
        uint128 held1 = _heldByManager(lo1, hi1);

        console2.log("after fund #1");
        console2.log(string.concat("  core bounds ", vm.toString(int256(lo1)), " .. ", vm.toString(int256(hi1))));
        console2.log(string.concat("  hook records  ", vm.toString(uint256(recorded1))));
        console2.log(string.concat("  manager holds ", vm.toString(uint256(held1))));
        assertEq(held1, recorded1, "fund #1: record should match the manager");

        hook.fund(id, FUND0, FUND1);
        (int24 lo2, int24 hi2,, uint128 recorded2) = hook.core(id);
        uint128 held2 = _heldByManager(lo2, hi2);

        console2.log("after fund #2");
        console2.log(string.concat("  core bounds ", vm.toString(int256(lo2)), " .. ", vm.toString(int256(hi2))));
        console2.log(string.concat("  hook records  ", vm.toString(uint256(recorded2))));
        console2.log(string.concat("  manager holds ", vm.toString(uint256(held2))));
        console2.log(string.concat("  forgotten     ", vm.toString(uint256(held2 - recorded2))));

        assertEq(lo2, lo1, "same price, so the same bounds");
        assertEq(hi2, hi1, "same price, so the same bounds");
        assertGt(held2, recorded2, "the manager holds more than the hook remembers");

        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        hook.withdraw(id);
        uint256 got0 = t0.balanceOf(address(this)) - before0;
        uint256 got1 = t1.balanceOf(address(this)) - before1;

        uint128 leftBehind = _heldByManager(lo1, hi1);

        console2.log("after withdraw");
        console2.log(string.concat("  funded in total ", vm.toString(FUND0 * 2), " / ", vm.toString(FUND1 * 2)));
        console2.log(string.concat("  returned        ", vm.toString(got0), " / ", vm.toString(got1)));
        console2.log(string.concat("  still held by the manager ", vm.toString(uint256(leftBehind))));

        assertGt(leftBehind, 0, "withdraw left a live position behind");
        assertLt(got0 + got1, FUND0 * 2 + FUND1 * 2, "owner got back less than was funded");
    }

    function test_zeroAmountFund_strandsTheWholeCore() public {
        hook.fund(id, FUND0, FUND1);
        (int24 lo, int24 hi,, uint128 recorded) = hook.core(id);
        console2.log(string.concat("after fund #1: hook records ", vm.toString(uint256(recorded))));

        hook.fund(id, 0, 0);
        (,,, uint128 recordedAfter) = hook.core(id);
        uint128 held = _heldByManager(lo, hi);

        console2.log("after fund(id, 0, 0)");
        console2.log(string.concat("  hook records  ", vm.toString(uint256(recordedAfter))));
        console2.log(string.concat("  manager holds ", vm.toString(uint256(held))));

        assertEq(recordedAfter, 0, "the record was replaced by an empty position");
        assertEq(held, recorded, "the real position is untouched and unreachable");

        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        hook.withdraw(id);
        uint256 got0 = t0.balanceOf(address(this)) - before0;
        uint256 got1 = t1.balanceOf(address(this)) - before1;

        console2.log("after withdraw");
        console2.log(string.concat("  funded   ", vm.toString(FUND0), " / ", vm.toString(FUND1)));
        console2.log(string.concat("  returned ", vm.toString(got0), " / ", vm.toString(got1)));
        console2.log(string.concat("  still held by the manager ", vm.toString(uint256(_heldByManager(lo, hi)))));

        assertGt(_heldByManager(lo, hi), 0, "the whole core is stranded");
    }
}
