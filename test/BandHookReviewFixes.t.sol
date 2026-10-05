// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The hook fixes from the PR #6 reviews, one section per issue, each named by what it checks.

import {Test, Vm} from "forge-std/Test.sol";
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

/// A source that spends 300k gas before answering: fine with no gas limit, too dear for a swap's read.
contract ExpensiveSource is IPriceSource {
    function priceX18() external view returns (uint256, uint256) {
        uint256 start = gasleft();
        while (start - gasleft() < 300_000) {}
        return (1e18, block.timestamp);
    }
}

contract BandHookReviewFixesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    uint24 constant FLOOR = 3000;
    uint24 constant CAP = 20000;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        source = new MockPriceSource(1e18); // the oracle at tick 0

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        key = _key(10);
        id = key.toId();
        hook.configure(key, _cfg(IPriceSource(address(source))));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 5_000_000e18);
        t1.mint(address(this), 5_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        hook.fund(id, FUND, FUND);
    }

    // ---------- issue 3: no usable price pays the cap, whatever the reason

    function test_freshSourceAtTheOracle_paysTheFloor() public {
        assertEq(_swapFee(key), FLOOR, "a fresh price with the pool on it: the floor, as before");
    }

    function test_staleSource_swapsPayTheCap() public {
        vm.warp(block.timestamp + 2 hours); // older than staleAfter (1 hour), still answering
        assertEq(_swapFee(key), CAP, "stale: the cap, not the floor");
    }

    function test_zeroPrice_swapsPayTheCap() public {
        source.set(0, block.timestamp);
        assertEq(_swapFee(key), CAP, "no price: the cap");
    }

    function test_futureDatedPrice_swapsPayTheCap() public {
        source.set(1e18, block.timestamp + 1 hours);
        assertEq(_swapFee(key), CAP, "a time from the future: the cap");
    }

    // ---------- issue 4: setSource reads a new source the way swaps read it

    function test_setSource_refusesASourceTooDearForTheSwapRead() public {
        IPriceSource dear = IPriceSource(address(new ExpensiveSource()));
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, dear, 0, 10);
    }

    function test_setSource_stillAcceptsANormalSource() public {
        IPriceSource fresh = IPriceSource(address(new MockPriceSource(1e18)));
        hook.setSource(id, fresh, 0, 10);
        (IPriceSource now_,,,,,,,,,,,) = hook.config(id);
        assertEq(address(now_), address(fresh), "replaced");
    }

    // ---------- issue 5: a price too large for the log is no price

    function test_aHugePrice_swapsPayTheCapInsteadOfReverting() public {
        source.set(1 << 255, block.timestamp);
        assertEq(_swapFee(key), CAP, "the swap goes through, at the cap");
    }

    function test_setSource_refusesAHugePrice() public {
        IPriceSource huge = IPriceSource(address(new MockPriceSource(1 << 255)));
        vm.expectRevert(BandHook.BadConfig.selector);
        hook.setSource(id, huge, 0, 10);
    }

    // ---------- helpers

    function _key(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(HOOK_ADDR)
        });
    }

    function _cfg(IPriceSource src) internal pure returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: src,
            feeFloor: FLOOR,
            feeCap: CAP,
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

    /// A small sell of token0 on `k`; returns the fee from the pool's Swap event.
    function _swapFee(PoolKey memory k) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no Swap event");
    }
}
