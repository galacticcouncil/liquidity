// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Gas of the in-swap recenter, one scenario per test so every measured call starts from the same
// state: first what a trader pays, then what the attempt alone needs, against RECENTER_GAS.
// Run with `forge test --isolate` so each call is its own transaction with cold storage.
// Written by Claude at Yash's request (2026-09-23).

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
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

contract BandHookAfterSwapGasTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;
    uint256 constant UP_4PCT = 1.04e18;
    int24 constant UP_4PCT_TICK = 392;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        // native ETH as currency0, as ETH/HOLLAR will run
        MockERC20 hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        hollar.mint(address(this), 10_000_000e18);
        hollar.approve(address(hook), type(uint256).max);
        hollar.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(hollar)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 800,
                feeCap: 10_000,
                feeSlopePpm: 1_000_000,
                staleAfter: 1 hours,
                halfBandTicks: 700,
                backstopHalfTicks: 11_000,
                backstopBps: 3500,
                triggerTicks: 350,
                guardTicks: 200,
                enabled: true,
                autoRecenter: true
            })
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.fund{value: FUND}(id, FUND, FUND);
    }

    /// A small sale of ETH that leaves the recenter not due.
    function _ordinarySwap() internal {
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The arbitrage that brings the pool to a 4% higher oracle, making the recenter due.
    function _triggeringSwap() internal {
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(UP_4PCT_TICK)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// `vm.lastCallGas()` decoded by hand: this forge-std declares a longer `Gas` struct than the
    /// installed Foundry returns, so only the first two words are read (gas limit, gas used).
    function _log(string memory what) internal {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok, "lastCallGas");
        (, uint256 used) = abi.decode(ret, (uint256, uint256));
        emit log_named_uint(what, used);
    }

    function test_gas_A_ordinarySwap_switchOff() public {
        hook.setAutoRecenter(id, false);
        _ordinarySwap();
        _log("A ordinary swap, switch off");
    }

    function test_gas_B_ordinarySwap_switchOn() public {
        _ordinarySwap();
        _log("B ordinary swap, switch on (checks only)");
    }

    function test_gas_C_triggeringSwap_switchOff_thenManualRecenter() public {
        hook.setAutoRecenter(id, false);
        source.set(UP_4PCT, block.timestamp);
        _triggeringSwap();
        _log("C triggering swap, switch off");
        hook.recenter(id);
        _log("C' then a manual recenter()");
    }

    function test_gas_D_triggeringSwap_switchOn() public {
        source.set(UP_4PCT, block.timestamp);
        _triggeringSwap();
        _log("D triggering swap, switch on (recenters inside)");
        (,, int24 c,) = hook.core(id);
        assertEq(c, UP_4PCT_TICK, "it did recenter");
    }
}

/// The attempt alone, in the dearest shapes measured, called the way `afterSwap` calls it: by the
/// hook, with the PoolManager unlocked. Each must fit in RECENTER_GAS, the least budget an attempt
/// starts with; if a change makes the recenter dearer, this fails before an attempt runs dry.
/// Run with --isolate for the cold costs, the ones a real swap pays; a plain run is warm and lower.
contract BandHookAttemptGasTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant RECENTER_GAS = 600_000; // mirrors BandHook.RECENTER_GAS
    uint256 constant FUND = 100_000e18;

    IPoolManager manager;
    PoolSwapTest pusher;
    MockPriceSource source;
    BandHook hook;
    MockERC20 t0;
    MockERC20 t1;
    PoolId pending; // the pool the unlock callback recenters
    uint256 used; // what that attempt used

    receive() external payable {}

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
            t.mint(address(this), 100_000_000e18);
            t.approve(address(hook), type(uint256).max);
            t.approve(address(pusher), type(uint256).max);
        }
        vm.deal(address(this), 10_000_000 ether);
    }

    /// Native ETH/HOLLAR, two recenters in a row: the dearest native case measured.
    function test_attempt_nativeEthHollar_secondLeg() public {
        (PoolKey memory k, PoolId i) = _pool(true, 10, 700, 11_000, 3500, 10_000, 350, 200);
        _secondLeg(k, i, 392, 800);
        _measureAttempt("native ETH/HOLLAR, second leg", i);
    }

    /// The ETH/HOLLAR shape with two ERC20s and spare tokens in the hook: the dearest case measured.
    function test_attempt_erc20_secondLeg_withSpareTokens() public {
        (PoolKey memory k, PoolId i) = _pool(false, 10, 700, 11_000, 3500, 10_000, 350, 200);
        _moveBoth(k, 392);
        hook.recenter(i);
        t0.transfer(HOOK_ADDR, FUND / 5);
        t1.transfer(HOOK_ADDR, FUND / 5);
        _moveBoth(k, 800);
        _measureAttempt("ERC20 ETH/HOLLAR shape, second leg, spare tokens", i);
    }

    /// The HDX shape: spacing 60, band +-1000, no backstop, 2% cap.
    function test_attempt_hdxShape_secondLeg() public {
        (PoolKey memory k, PoolId i) = _pool(false, 60, 1000, 0, 0, 20_000, 500, 300);
        _secondLeg(k, i, 600, 1200);
        _measureAttempt("HDX shape, second leg", i);
    }

    /// The HDX shape with its backstop, second recenter, the pool 299 ticks short of the oracle
    /// (guard 300): the dearest natural case measured (audit B-3).
    function test_attempt_hdxShape_secondRecenter_poolShortOfTheOracle() public {
        (PoolKey memory k, PoolId i) = _pool(false, 60, 1000, 16_000, 3500, 20_000, 500, 300);
        _moveBoth(k, -542);
        hook.recenter(i);
        _moveOracleAndPool(k, 1029, 730);
        _measureAttempt("HDX shape, second recenter, pool 299 short", i);
    }

    /// The ETH/HOLLAR shape with two ERC20s, second recenter, the pool 199 ticks short (guard 200).
    function test_attempt_erc20_secondRecenter_poolShortOfTheOracle() public {
        (PoolKey memory k, PoolId i) = _pool(false, 10, 700, 11_000, 3500, 10_000, 350, 200);
        _moveBoth(k, -392);
        hook.recenter(i);
        _moveOracleAndPool(k, 708, 509);
        _measureAttempt("ERC20 ETH/HOLLAR shape, second recenter, pool 199 short", i);
    }

    /// The same, with a fifth of the funding of each token donated to the hook: the dearest case
    /// measured, about 2k under the budget. The first test to fail if the attempt gets dearer.
    function test_attempt_erc20_secondRecenter_withDonatedTokensInBoth() public {
        (PoolKey memory k, PoolId i) = _pool(false, 10, 700, 11_000, 3500, 10_000, 350, 200);
        _moveBoth(k, -392);
        hook.recenter(i);
        _moveOracleAndPool(k, 708, 509);
        t0.transfer(HOOK_ADDR, FUND / 5);
        t1.transfer(HOOK_ADDR, FUND / 5);
        _measureAttempt("ERC20 ETH/HOLLAR shape, second recenter, pool 199 short, donated tokens", i);
    }

    function _secondLeg(PoolKey memory k, PoolId i, int24 first, int24 second) internal {
        _moveBoth(k, first);
        hook.recenter(i);
        _moveBoth(k, second);
    }

    function _pool(
        bool native,
        int24 spacing,
        int24 half,
        int24 backstopHalf,
        uint16 backstopBps,
        uint24 cap,
        int24 trigger,
        int24 guard
    ) internal returns (PoolKey memory k, PoolId i) {
        k = PoolKey({
            currency0: native ? Currency.wrap(address(0)) : Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(HOOK_ADDR)
        });
        i = k.toId();
        hook.configure(
            k,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 800,
                feeCap: cap,
                feeSlopePpm: 1_000_000,
                staleAfter: 1 hours,
                halfBandTicks: half,
                backstopHalfTicks: backstopHalf,
                backstopBps: backstopBps,
                triggerTicks: trigger,
                guardTicks: guard,
                enabled: true,
                autoRecenter: false
            })
        );
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        hook.fund{value: native ? FUND : 0}(i, FUND, FUND);
    }

    /// The market moves to `tick`: the oracle follows it and a trade takes the pool there.
    function _moveBoth(PoolKey memory k, int24 tick) internal {
        _moveOracleAndPool(k, tick, tick);
    }

    /// The oracle moves to `oracleTick` and a trade takes the pool to `poolTick`.
    function _moveOracleAndPool(PoolKey memory k, int24 oracleTick, int24 poolTick) internal {
        uint256 s = TickMath.getSqrtPriceAtTick(oracleTick);
        source.set((s * s >> 96) * 1e18 >> 96, block.timestamp);
        (, int24 now_,,) = manager.getSlot0(k.toId());
        bool up = poolTick > now_;
        bool paysEth = !up && k.currency0.isAddressZero();
        pusher.swap{value: paysEth ? 1_000_000 ether : 0}(
            k,
            SwapParams({zeroForOne: !up, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(poolTick)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Opens an unlock whose callback runs the attempt as the hook, and checks what it used.
    function _measureAttempt(string memory what, PoolId i) internal {
        pending = i;
        manager.unlock("");
        emit log_named_uint(what, used);
        assertLt(used, RECENTER_GAS, "the attempt fits in the least budget it starts with");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.prank(HOOK_ADDR);
        uint256 g = gasleft();
        (bool ok,) = HOOK_ADDR.call(abi.encodeCall(BandHook.recenterInSwap, (pending)));
        used = g - gasleft();
        require(ok, "the attempt failed");
        return "";
    }
}
