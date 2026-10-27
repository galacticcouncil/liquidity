// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// The two-step handover: who can do what, and what an observer can see. Nothing in the
/// suite exercised either function before this file.
contract BandHookOwnershipTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager manager;
    MockERC20 t0;
    MockERC20 t1;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;

    address dave = makeAddr("dave"); // the deployer, initial owner
    address alice = makeAddr("alice"); // the multisig
    address bob = makeAddr("bob");
    address carol = makeAddr("carol"); // a stranger

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        source = new MockPriceSource(1e18);

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, dave), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();

        vm.prank(dave);
        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        for (uint256 i = 0; i < 3; i++) {
            address who = i == 0 ? dave : (i == 1 ? alice : bob);
            t0.mint(who, 1_000_000e18);
            t1.mint(who, 1_000_000e18);
            vm.startPrank(who);
            t0.approve(address(hook), type(uint256).max);
            t1.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
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
            guardTicks: 300,
            enabled: true,
            autoRecenter: false
        });
    }

    // ---------- what an observer can see

    /// The first half of the handover, which is the one script 03 sends.
    function test_transferOwnership_emitsStarted() public {
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit OwnershipTransferStarted(dave, alice);
        vm.prank(dave);
        hook.transferOwnership(alice);

        assertEq(hook.owner(), dave, "still Dave until Alice accepts");
        assertEq(hook.pendingOwner(), alice, "Alice is nominated");
    }

    /// The second half, which the multisig sends on its own schedule.
    function test_acceptOwnership_emitsTransferred() public {
        vm.prank(dave);
        hook.transferOwnership(alice);

        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit OwnershipTransferred(dave, alice);
        vm.prank(alice);
        hook.acceptOwnership();

        assertEq(hook.owner(), alice, "Alice owns it");
        assertEq(hook.pendingOwner(), address(0), "nothing pending");
    }

    /// Nominating the zero address cancels a pending handover, and says so.
    function test_cancellingAPendingHandover_isVisible() public {
        vm.prank(dave);
        hook.transferOwnership(alice);

        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit OwnershipTransferStarted(dave, address(0));
        vm.prank(dave);
        hook.transferOwnership(address(0));

        assertEq(hook.pendingOwner(), address(0), "cancelled");
        vm.prank(alice);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.acceptOwnership();
    }

    /// Re-pointing a pending handover emits again, so the last event is the truth.
    function test_retargetingAPendingHandover_emitsAgain() public {
        vm.prank(dave);
        hook.transferOwnership(alice);

        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit OwnershipTransferStarted(dave, bob);
        vm.prank(dave);
        hook.transferOwnership(bob);

        assertEq(hook.pendingOwner(), bob, "Bob is now the nominee");
    }

    // ---------- who can do what

    /// Dave hands over to Alice; Alice accepts; Alice can fund; Dave cannot.
    function test_afterHandover_thePowerMovesCompletely() public {
        vm.prank(dave);
        hook.transferOwnership(alice);
        vm.prank(alice);
        hook.acceptOwnership();

        vm.prank(alice);
        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "Alice can fund");

        vm.prank(dave);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.fund(id, FUND, FUND);

        vm.prank(dave);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.withdraw(id);

        MockPriceSource replacement = new MockPriceSource(1e18);
        vm.prank(dave);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.setSource(id, IPriceSource(address(replacement)), 0, 50);
    }

    /// A stranger cannot accept a handover meant for somebody else.
    function test_strangerCannotAcceptAPendingHandover() public {
        vm.prank(dave);
        hook.transferOwnership(alice);

        vm.prank(carol);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.acceptOwnership();

        assertEq(hook.owner(), dave, "Dave is still owner");
        assertEq(hook.pendingOwner(), alice, "Alice is still the nominee");
    }

    function test_strangerCannotStartAHandover() public {
        vm.prank(carol);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.transferOwnership(carol);
        assertEq(hook.pendingOwner(), address(0), "nothing nominated");
    }

    /// Dave nominates Alice and then Bob. Only Bob can accept.
    function test_onlyTheLatestNomineeCanAccept() public {
        vm.prank(dave);
        hook.transferOwnership(alice);
        vm.prank(dave);
        hook.transferOwnership(bob);

        vm.prank(alice);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.acceptOwnership();

        vm.prank(bob);
        hook.acceptOwnership();
        assertEq(hook.owner(), bob, "Bob owns it");
    }

    /// Accepting twice fails, because the pending slot was cleared.
    function test_acceptingTwiceFails() public {
        vm.prank(dave);
        hook.transferOwnership(alice);
        vm.prank(alice);
        hook.acceptOwnership();

        vm.prank(alice);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.acceptOwnership();
        assertEq(hook.owner(), alice, "and Alice is still owner");
    }

    /// The window the events exist to make visible: between the two halves, Dave still
    /// holds every power. This is the state an alert needs to notice.
    function test_duringTheHandoverWindow_theOldOwnerStillHoldsEverything() public {
        vm.prank(dave);
        hook.transferOwnership(alice);

        vm.prank(dave);
        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "Dave can still fund while Alice has not accepted");

        vm.prank(alice);
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.fund(id, FUND, FUND);
    }
}
