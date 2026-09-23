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
import {FalseReturningERC20, NoReturnERC20} from "./mocks/NonStandardERC20.sol";

/// The hook moves tokens in four places. A transfer that does not happen must not
/// be treated as one that did.
contract BandHookSafeTransferTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    MockPriceSource source;
    BandHook hook;

    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));
    uint256 constant FUND = 100_000e18;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        source = new MockPriceSource(1e18);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));
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

    /// Wire up a pool from two already-deployed tokens, sorted, and approve the hook.
    function _makePool(address a, address b) internal returns (PoolKey memory key, PoolId id) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        (bool ok0,) = c0.call(abi.encodeWithSignature("mint(address,uint256)", address(this), 10_000_000e18));
        (bool ok1,) = c1.call(abi.encodeWithSignature("mint(address,uint256)", address(this), 10_000_000e18));
        require(ok0 && ok1, "mint failed");
        (ok0,) = c0.call(abi.encodeWithSignature("approve(address,uint256)", HOOK_ADDR, type(uint256).max));
        (ok1,) = c1.call(abi.encodeWithSignature("approve(address,uint256)", HOOK_ADDR, type(uint256).max));
        require(ok0 && ok1, "approve failed");
    }

    function _balance(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(data, (uint256));
    }

    // ---------- a token that returns false

    /// The case that used to succeed silently: transferFrom returns false, so no tokens
    /// arrive, and fund() must refuse rather than emit an event for money it never got.
    function test_fund_revertsWhenTransferFromReturnsFalse() public {
        FalseReturningERC20 bad = new FalseReturningERC20("BAD", "BAD");
        MockERC20 good = new MockERC20("GOOD", "GOOD", 18);
        (, PoolId id) = _makePool(address(bad), address(good));

        bad.setFailTransferFrom(true);

        vm.expectRevert(BandHook.TransferFailed.selector);
        hook.fund(id, FUND, FUND);
    }

    /// The payout leg: funding works, then the token starts refusing transfers to the
    /// owner. withdraw() must revert rather than report money it did not send.
    function test_withdraw_revertsWhenTransferToOwnerReturnsFalse() public {
        FalseReturningERC20 bad = new FalseReturningERC20("BAD", "BAD");
        MockERC20 good = new MockERC20("GOOD", "GOOD", 18);
        (, PoolId id) = _makePool(address(bad), address(good));

        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "funded normally first");

        bad.setFailTransferTo(address(this));

        vm.expectRevert(BandHook.TransferFailed.selector);
        hook.withdraw(id);
    }

    // ---------- a token that returns nothing

    /// USDT-shaped tokens: both legs return no data. These used to be unusable, because
    /// the old call site declared `returns (bool)` and decoding empty data reverts.
    function test_fundAndWithdraw_workWithNoReturnTokens() public {
        NoReturnERC20 a = new NoReturnERC20("NR0", "NR0");
        NoReturnERC20 b = new NoReturnERC20("NR1", "NR1");
        (PoolKey memory key, PoolId id) = _makePool(address(a), address(b));

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        uint256 before0 = _balance(c0, address(this));
        uint256 before1 = _balance(c1, address(this));

        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);
        assertGt(cliq, 0, "core minted");
        assertGt(bliq, 0, "backstop minted");

        hook.withdraw(id);
        assertApproxEqAbs(_balance(c0, address(this)), before0, 1e15, "token0 returned");
        assertApproxEqAbs(_balance(c1, address(this)), before1, 1e15, "token1 returned");
        assertEq(_balance(c0, HOOK_ADDR), 0, "nothing left in the hook");
        assertEq(_balance(c1, HOOK_ADDR), 0, "nothing left in the hook");
    }

    // ---------- no regression on ordinary tokens

    /// A well-behaved pair still funds and withdraws exactly as before.
    function test_standardTokens_unchanged() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (PoolKey memory key, PoolId id) = _makePool(address(a), address(b));

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        uint256 before0 = _balance(c0, address(this));
        uint256 before1 = _balance(c1, address(this));

        hook.fund(id, FUND, FUND);
        (,,, uint128 cliq) = hook.core(id);
        assertGt(cliq, 0, "core minted");

        hook.withdraw(id);
        assertApproxEqAbs(_balance(c0, address(this)), before0, 1e15, "token0 returned");
        assertApproxEqAbs(_balance(c1, address(this)), before1, 1e15, "token1 returned");
    }

    /// The failure is reported, not swallowed: the owner keeps their tokens and the
    /// hook records nothing.
    function test_failedFund_movesNothingAndRecordsNothing() public {
        FalseReturningERC20 bad = new FalseReturningERC20("BAD", "BAD");
        MockERC20 good = new MockERC20("GOOD", "GOOD", 18);
        (PoolKey memory key, PoolId id) = _makePool(address(bad), address(good));

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        uint256 before0 = _balance(c0, address(this));
        uint256 before1 = _balance(c1, address(this));

        bad.setFailTransferFrom(true);
        vm.expectRevert(BandHook.TransferFailed.selector);
        hook.fund(id, FUND, FUND);

        assertEq(_balance(c0, address(this)), before0, "owner keeps token0");
        assertEq(_balance(c1, address(this)), before1, "owner keeps token1");
        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);
        assertEq(cliq, 0, "no core recorded");
        assertEq(bliq, 0, "no backstop recorded");
    }

    // ---------- an address with no code (issue #2)

    /// Bob funds a pool whose token address holds no contract: TransferFailed, nothing recorded.
    /// The old helpers treated the empty return as success and failed later, with no reason.
    function test_fund_revertsWhenATokenHasNoCode() public {
        MockERC20 good = new MockERC20("GOOD", "GOOD", 18);
        address ghost = makeAddr("no contract here");
        (, PoolId id) = _makePool(ghost, address(good));
        uint256 before = _balance(address(good), address(this));

        vm.expectRevert(BandHook.TransferFailed.selector);
        hook.fund(id, FUND, FUND);

        assertEq(_balance(address(good), address(this)), before, "Bob keeps the real token");
        (,,, uint128 cliq) = hook.core(id);
        assertEq(cliq, 0, "no core recorded");
    }
}
