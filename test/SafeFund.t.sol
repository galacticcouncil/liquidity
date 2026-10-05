// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The Safe batch from SafeFund, run the way the Safe runs it: every call from the hook's owner, in
// one transaction, all or nothing. Mallory moves the empty pool's price for free before it runs.

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolAnchor} from "../script/PoolAnchor.sol";
import {SafeFund} from "../script/SafeFund.s.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Stands in for the Safe: owns the hook and runs a batch of calls in one transaction, all or nothing.
contract SafeLike {
    function execute(SafeFund.Call[] calldata calls) external {
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    receive() external payable {}
}

contract SafeFundTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant MAX0 = 1e18; // the anchor's cap per token
    uint256 constant MAX1 = 1e18;
    uint256 constant AMOUNT = 10e18; // what the Safe funds, of each token
    uint160 constant FLOOR = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant CEILING = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 t0;
    MockERC20 t1;
    MockERC20 hollar;
    MockPriceSource source;
    BandHook hook;
    PoolAnchor helper;
    SafeFund script;
    SafeLike safe;
    PoolKey key;
    PoolId id;
    PoolKey nativeKey;
    address mallory = makeAddr("mallory");

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        source = new MockPriceSource(1e18); // the oracle at tick 0

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        key = PoolKey(
            Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(HOOK_ADDR)
        );
        id = key.toId();
        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        nativeKey = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(hollar)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(HOOK_ADDR)
        );
        hook.configure(nativeKey, _cfg());
        manager.initialize(nativeKey, TickMath.getSqrtPriceAtTick(0));

        // the hand-off happens before any funding: the Safe owns the hook and holds the capital
        safe = new SafeLike();
        hook.transferOwnership(address(safe));
        safe.execute(_one(address(hook), 0, abi.encodeCall(BandHook.acceptOwnership, ())));
        MockERC20[3] memory tokens = [t0, t1, hollar];
        for (uint256 i; i < 3; i++) {
            tokens[i].mint(address(safe), 1_000e18);
            tokens[i].mint(mallory, 1);
            vm.prank(mallory);
            tokens[i].approve(address(swapRouter), type(uint256).max);
        }
        vm.deal(address(safe), 100 ether);

        helper = new PoolAnchor(manager);
        script = new SafeFund();
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

    function _one(address to, uint256 value, bytes memory data) internal pure returns (SafeFund.Call[] memory c) {
        c = new SafeFund.Call[](1);
        c[0] = SafeFund.Call(to, value, data);
    }

    /// The batch SafeFund writes for `k`, anchoring onto `target`.
    function batchFor(PoolKey memory k, uint160 target) internal view returns (SafeFund.Call[] memory) {
        return script.calls(hook, k, helper, target, MAX0, MAX1, AMOUNT, AMOUNT);
    }

    function price(PoolId pid) internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(pid);
    }

    function setOracleTick(int24 t) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(t);
        source.set(FullMath.mulDiv(FullMath.mulDiv(s, s, 1 << 96), 1e18, 1 << 96), block.timestamp);
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

    /// 1. Nobody moved the price: the Safe runs the batch, the anchor does nothing, and the pool is
    /// funded around the oracle with exactly the amounts in the batch.
    function test_nobodyMovedThePrice_fundsAroundTheOracle() public {
        SafeFund.Call[] memory b = batchFor(key, TickMath.getSqrtPriceAtTick(0));

        safe.execute(b);

        (,, int24 center, uint128 liq) = hook.core(id);
        assertEq(center, 0, "funded around the oracle");
        assertGt(liq, 0);
        assertEq(t0.balanceOf(address(safe)), 1_000e18 - AMOUNT, "the Safe paid exactly the token0 amount");
        assertEq(t1.balanceOf(address(safe)), 1_000e18 - AMOUNT, "the Safe paid exactly the token1 amount");
    }

    /// 2. Mallory parks the price on the floor after the batch was written: the same batch still
    /// anchors and funds, in one transaction.
    function test_malloryOnTheFloor_theSameBatchAnchorsAndFunds() public {
        uint160 target = TickMath.getSqrtPriceAtTick(0);
        SafeFund.Call[] memory b = batchFor(key, target);
        malloryParksThePriceAt(key, FLOOR);

        safe.execute(b);

        assertEq(price(id), target, "back on the oracle");
        (,, int24 center, uint128 liq) = hook.core(id);
        assertEq(center, 0, "funded around the oracle");
        assertGt(liq, 0);
    }

    /// 3. Mallory nudges the price 150 ticks, inside the guard, where fund alone would accept it: the
    /// batch puts it back exactly on the oracle first, so the book is not split at her price.
    function test_malloryInsideTheGuard_putBackExactlyOnTheOracle() public {
        uint160 target = TickMath.getSqrtPriceAtTick(0);
        SafeFund.Call[] memory b = batchFor(key, target);
        malloryParksThePriceAt(key, TickMath.getSqrtPriceAtTick(150));

        safe.execute(b);

        assertEq(price(id), target, "funded with the pool exactly on the oracle");
        (,,, uint128 liq) = hook.core(id);
        assertGt(liq, 0);
    }

    /// 4. An ETH pool parked on the ceiling: the batch sends ETH to the anchor and to fund; the anchor
    /// hands its ETH back, so the Safe spends exactly the fund's ETH.
    function test_ethPool_theSafeSpendsExactlyTheFundsEth() public {
        uint160 target = TickMath.getSqrtPriceAtTick(0);
        SafeFund.Call[] memory b = batchFor(nativeKey, target);
        assertEq(b.length, 4, "no ETH approvals");
        assertEq(b[1].value, MAX0, "the anchor gets its ETH cap");
        assertEq(b[3].value, AMOUNT, "fund gets the ETH it deposits");
        malloryParksThePriceAt(nativeKey, CEILING);
        uint256 ethBefore = address(safe).balance;

        safe.execute(b);

        assertEq(price(nativeKey.toId()), target, "back on the oracle");
        assertEq(address(safe).balance, ethBefore - AMOUNT, "the Safe spent exactly the fund's ETH");
        assertEq(address(helper).balance, 0, "the anchor keeps no ETH");
    }

    /// 5. If any call fails, nothing happens: the oracle moves past the guard after the batch was
    /// written, so fund refuses, and the anchor's move is undone with it.
    function test_ifFundRefuses_nothingHappens() public {
        SafeFund.Call[] memory b = batchFor(key, TickMath.getSqrtPriceAtTick(0));
        malloryParksThePriceAt(key, FLOOR);
        setOracleTick(2000);

        vm.expectRevert(BandHook.GuardTripped.selector);
        safe.execute(b);

        assertEq(price(id), FLOOR, "the price stays where Mallory left it");
        assertEq(t0.balanceOf(address(safe)), 1_000e18, "no token0 spent");
        assertEq(t1.balanceOf(address(safe)), 1_000e18, "no token1 spent");
    }

    /// 6. The file for the Safe app lists the same calls, in the same order, for this chain and Safe.
    function test_theFile_listsTheSameCalls() public view {
        SafeFund.Call[] memory b = batchFor(key, TickMath.getSqrtPriceAtTick(0));

        string memory json = script.toJson(b, block.chainid, address(safe));

        assertEq(vm.parseJsonString(json, ".chainId"), vm.toString(block.chainid));
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), address(safe));
        assertEq(vm.parseJsonAddress(json, ".transactions[2].to"), address(helper), "third: the anchor");
        assertEq(vm.parseJsonAddress(json, ".transactions[5].to"), address(hook), "last: fund");
        assertEq(vm.parseJsonBytes(json, ".transactions[5].data"), b[5].data);
        assertFalse(vm.keyExistsJson(json, ".transactions[6]"), "six calls, no more");
    }
}
