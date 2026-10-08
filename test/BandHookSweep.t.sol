// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The owner can recover anything that lands in the hook (audit A-5): ETH on a hook whose pool has
// no ETH leg, a stray token, or a donation of a pool's own token, without touching the positions.

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

contract BandHookSweepTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    Currency constant ETH = Currency.wrap(address(0));
    uint256 constant FUND = 100_000e18;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockPriceSource source;
    BandHook hook;
    MockERC20 t0;
    MockERC20 t1;
    PoolKey key;
    PoolId id;

    address sam = makeAddr("sam");
    address tara = makeAddr("tara");
    address mallory = makeAddr("mallory");

    receive() external payable {} // the test contract is the owner, and sweeps pay it ETH

    /// An HDX/HOLLAR-like hook: two ERC20s, no ETH leg, funded with a backstop.
    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 3000,
                feeCap: 20_000,
                feeSlopePpm: 1_000_000,
                staleAfter: 1 hours,
                halfBandTicks: 1000,
                backstopHalfTicks: 16_000,
                backstopBps: 3500,
                triggerTicks: 500,
                guardTicks: 300,
                enabled: true,
                autoRecenter: false
            })
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        for (uint256 i; i < 2; i++) {
            MockERC20 t = i == 0 ? t0 : t1;
            t.mint(address(this), 10_000_000e18);
            t.approve(address(hook), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
        }
        hook.fund(id, FUND, FUND);
    }

    function test_strayEth_onAHookWithNoEthLeg_isSweptToTheOwner() public {
        vm.deal(sam, 5 ether);
        vm.prank(sam);
        (bool sent,) = HOOK_ADDR.call{value: 5 ether}("");
        assertTrue(sent, "the hook accepts it, as before");

        uint256 before = address(this).balance;
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit BandHook.Swept(ETH, address(this), 5 ether);
        hook.sweep(ETH, address(0), 0); // both defaults: to the owner, the whole balance

        assertEq(address(this).balance - before, 5 ether, "the owner has Sam's 5 ETH");
        assertEq(HOOK_ADDR.balance, 0, "nothing is left stuck");
    }

    function test_aStrayToken_isReturnedToItsSender_exactAmount() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(tara, 1_000e6);
        usdc.mint(address(this), 250e6);
        vm.prank(tara);
        usdc.transfer(HOOK_ADDR, 1_000e6);
        usdc.transfer(HOOK_ADDR, 250e6); // someone else's mistake sits there too

        hook.sweep(Currency.wrap(address(usdc)), tara, 1_000e6);

        assertEq(usdc.balanceOf(tara), 1_000e6, "Tara has exactly her 1,000 back");
        assertEq(usdc.balanceOf(HOOK_ADDR), 250e6, "the rest stays until it is swept too");
    }

    function test_aDonatedPoolToken_isSwept_positionsUntouched() public {
        (int24 cLo, int24 cHi,, uint128 cLiq) = hook.core(id);
        (int24 bLo, int24 bHi,, uint128 bLiq) = hook.backstop(id);
        (int24 lLo, int24 lHi,, uint128 lLiq) = hook.limit(id);
        uint256 idleBefore = t1.balanceOf(HOOK_ADDR); // dust at most, since the limit holds leftovers
        t1.mint(sam, 50_000e18);
        vm.prank(sam);
        t1.transfer(HOOK_ADDR, 50_000e18);

        uint256 before = t1.balanceOf(address(this));
        hook.sweep(key.currency1, address(0), 0);

        assertEq(t1.balanceOf(address(this)) - before, 50_000e18 + idleBefore, "the donation and any dust");
        assertEq(t1.balanceOf(HOOK_ADDR), 0);
        _assertUnchanged(cLo, cHi, cLiq, hook.core, bytes32(0));
        _assertUnchanged(bLo, bHi, bLiq, hook.backstop, bytes32(uint256(1)));
        _assertUnchanged(lLo, lHi, lLiq, hook.limit, bytes32(uint256(2)));

        // and the pool carries on: a move past the trigger, then a recenter
        _moveTo(600);
        hook.recenter(id);
        (,, int24 centre,) = hook.core(id);
        assertApproxEqAbs(centre, 600, 1, "recentred on the oracle after the sweep");
    }

    function test_nothingToSweep_doesNothing() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit BandHook.Swept(Currency.wrap(address(usdc)), address(this), 0);
        hook.sweep(Currency.wrap(address(usdc)), address(0), 0);
    }

    function test_tooMuch_reverts_andNothingMoves() public {
        vm.deal(HOOK_ADDR, 1 ether);
        vm.expectRevert(BandHook.NativeTransferFailed.selector);
        hook.sweep(ETH, address(0), 2 ether);
        assertEq(HOOK_ADDR.balance, 1 ether, "the ETH is still there");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(HOOK_ADDR, 100e6);
        vm.expectRevert(BandHook.TransferFailed.selector);
        hook.sweep(Currency.wrap(address(usdc)), address(0), 101e6);
        assertEq(usdc.balanceOf(HOOK_ADDR), 100e6, "and so is the token");
    }

    function test_notTheOwner_reverts() public {
        vm.deal(HOOK_ADDR, 1 ether);
        vm.expectRevert(BandHook.NotOwner.selector);
        vm.prank(mallory);
        hook.sweep(ETH, mallory, 0);
        assertEq(HOOK_ADDR.balance, 1 ether);
    }

    // ---------- helpers

    /// @dev The record is unchanged and the PoolManager still holds exactly that liquidity.
    function _assertUnchanged(
        int24 lo,
        int24 hi,
        uint128 liq,
        function(PoolId) external view returns (int24, int24, int24, uint128) record,
        bytes32 salt
    ) internal view {
        (int24 loNow, int24 hiNow,, uint128 liqNow) = record(id);
        assertEq(loNow, lo, "same lower edge");
        assertEq(hiNow, hi, "same upper edge");
        assertEq(liqNow, liq, "same liquidity");
        (uint128 held,,) = manager.getPositionInfo(id, HOOK_ADDR, lo, hi, salt);
        assertEq(held, liq, "and the PoolManager still holds it");
    }

    /// @dev The oracle moves to `tick` and a trade takes the pool there.
    function _moveTo(int24 tick) internal {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        source.set((s * s >> 96) * 1e18 >> 96, block.timestamp);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
