// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {RatioSource} from "../src/sources/RatioSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {DeployBandHook} from "../script/00_DeployBandHook.s.sol";
import {SetupPool} from "../script/01_SetupPool.s.sol";
import {FundPool} from "../script/02_Fund.s.sol";
import {HandOff} from "../script/03_HandOff.s.sol";
import {AnchorPool} from "../script/AnchorPool.s.sol";
import {MockAggregator} from "./mocks/SourceMocks.sol";

/// The launch routine end to end, with the real scripts, on a fork of Robinhood Chain: three
/// pools on three hooks, ETH/HDX priced through RatioSource, one pool anchored before funding.
/// One test on purpose: the scripts read process-wide environment variables, which tests
/// running in parallel would overwrite under each other.
contract BandHookScriptsForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    // a key nobody else uses: well-known test keys have sweeper code on live chains, which
    // forwards any ETH they receive
    uint256 constant DEPLOYER_PK = uint256(keccak256("bandhook launch routine fork test deployer"));

    address deployer;
    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");
    MockERC20 hollar; // bridged HOLLAR does not exist yet: 18 decimals
    MockERC20 hdx; // bridged HDX does not exist yet: 12 decimals, as on Hydration
    MockAggregator hdxUsd; // stands in for the HDX/USD ManagedOracle: 8 decimals, $0.01
    uint256 ethAnswer; // the live Chainlink ETH/USD answer, 8 decimals

    BandHook ethHollar;
    BandHook hdxHollar;
    BandHook ethHdx;
    PoolKey ethHollarKey;
    PoolKey hdxHollarKey;
    PoolKey ethHdxKey;

    function setUp() public {
        vm.createSelectFork("robinhood");
        deployer = vm.addr(DEPLOYER_PK);
        assertEq(deployer.code.length, 0, "the deployer is a plain account on the fork");
        assertEq(multisig.code.length, 0, "and so is the multisig stand-in");
        hollar = new MockERC20("Hollar", "HOLLAR", 18);
        hdx = new MockERC20("HydraDX", "HDX", 12);
        hdxUsd = new MockAggregator(8, 1e6);
        (, int256 answer,,,) = ETH_USD.latestRoundData();
        ethAnswer = uint256(answer);
        vm.deal(deployer, 100 ether);
        hollar.mint(deployer, 10_000_000e18);
        hdx.mint(deployer, 100_000_000e12);
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.setEnv("NEW_OWNER", vm.toString(multisig));
    }

    function test_launchRoutine_threePoolsOnThreeHooks() public {
        _deployOneHookPerPool();
        _setUpAndFundEthHollar();
        _ethHdxRefusesSwappedFeedsThenFunds();
        _hdxHollarInitializedByAStrangerIsAnchoredThenFunded();
        _withdrawingOnePoolLeavesTheOthersUntouched();
        _handEachHookToTheMultisig();
    }

    // ---------- the phases

    /// 00 once per pool: three mined addresses, each with the hook's permission bits, each
    /// owned by the deployer until the hand-off.
    function _deployOneHookPerPool() internal {
        ethHollar = new DeployBandHook().run();
        hdxHollar = new DeployBandHook().run();
        ethHdx = new DeployBandHook().run();
        assertTrue(address(ethHollar) != address(hdxHollar), "three different hooks");
        assertTrue(address(hdxHollar) != address(ethHdx), "three different hooks");
        BandHook[3] memory hooks = [ethHollar, hdxHollar, ethHdx];
        for (uint256 i; i < 3; i++) {
            assertEq(uint160(address(hooks[i])) & 0x3FFF, 0x10C0, "afterInitialize | beforeSwap | afterSwap");
            assertEq(hooks[i].owner(), deployer, "the deployer owns it until the hand-off");
        }
    }

    /// ETH/HOLLAR: one Chainlink feed, initialized at the oracle price and funded.
    function _setUpAndFundEthHollar() internal {
        ethHollarKey = _key(ethHollar, address(0), address(hollar), 10);
        _poolEnv(ethHollar, address(0), address(hollar), 10, 18, 18);
        _setS("SOURCE", "single");
        _setA("FEED", address(ETH_USD));
        _setU("FEED_PRICES_TOKEN", 0);
        _setI("EXPECTED_TICK", _tickOf(ethAnswer, 1e8)); // raw HOLLAR per raw ETH
        _params(800, 10000, 100800, 700, 11000, 350, 200);
        _setU("FUND_AMOUNT0", 10 ether);
        _setU("FUND_AMOUNT1", 10 * ethAnswer * 1e10);

        new SetupPool().run();
        new FundPool().run();
        (,,, uint128 liq) = ethHollar.core(ethHollarKey.toId());
        assertGt(liq, 0, "ETH/HOLLAR funded");
    }

    /// ETH/HDX: the issue's feed order is refused before anything is configured; the right order
    /// configures a RatioSource with ETH/USD first, and the pool is funded.
    function _ethHdxRefusesSwappedFeedsThenFunds() internal {
        ethHdxKey = _key(ethHdx, address(0), address(hdx), 60);
        _poolEnv(ethHdx, address(0), address(hdx), 60, 18, 12);
        _setS("SOURCE", "ratio");
        _setI("EXPECTED_TICK", _tickOf(ethAnswer * 1e12, 1e6 * 1e18)); // raw HDX per raw ETH
        _params(3000, 20000, 100800, 1000, 16000, 500, 300);
        _setU("FUND_AMOUNT0", 5 ether);
        _setU("FUND_AMOUNT1", 5 * ethAnswer * 1e12 / 1e6);

        _setA("FEED0_USD", address(hdxUsd)); // the order the issue writes: HDX/USD first
        _setA("FEED1_USD", address(ETH_USD));
        SetupPool setup = new SetupPool();
        try setup.run() {
            assertTrue(false, "the swapped feeds should have been refused");
        } catch Error(string memory reason) {
            assertEq(_prefix(reason, 17), "source reads tick", "refused by the expected-tick check");
        }
        (IPriceSource none,,,,,,,,,,,) = ethHdx.config(ethHdxKey.toId());
        assertEq(address(none), address(0), "nothing configured");

        _setA("FEED0_USD", address(ETH_USD));
        _setA("FEED1_USD", address(hdxUsd));
        new SetupPool().run();
        (IPriceSource source,,,,,,,,,,,) = ethHdx.config(ethHdxKey.toId());
        assertEq(address(RatioSource(address(source)).feedBase()), address(ETH_USD), "ETH/USD first");
        new FundPool().run();
        (,,, uint128 liq) = ethHdx.core(ethHdxKey.toId());
        assertGt(liq, 0, "ETH/HDX funded");
    }

    /// HDX/HOLLAR: a stranger initialized the pool first, 2,000 ticks off the oracle. Setup
    /// configures it without moving it, funding is refused, AnchorPool moves it back, and then
    /// funding goes through.
    function _hdxHollarInitializedByAStrangerIsAnchoredThenFunded() internal {
        bool hdxIs0 = address(hdx) < address(hollar);
        (address c0, address c1) = hdxIs0 ? (address(hdx), address(hollar)) : (address(hollar), address(hdx));
        hdxHollarKey = _key(hdxHollar, c0, c1, 60);
        _poolEnv(hdxHollar, c0, c1, 60, hdxIs0 ? 12 : 18, hdxIs0 ? 18 : 12);
        _setS("SOURCE", "single");
        _setA("FEED", address(hdxUsd));
        _setU("FEED_PRICES_TOKEN", hdxIs0 ? 0 : 1);
        int24 expected = hdxIs0 ? _tickOf(1e6 * 1e18, 1e8 * 1e12) : _tickOf(1e8 * 1e12, 1e6 * 1e18);
        _setI("EXPECTED_TICK", expected);
        _params(3000, 20000, 7200, 1000, 16000, 500, 300);
        _setU("FUND_AMOUNT0", hdxIs0 ? 1_000_000e12 : 10_000e18);
        _setU("FUND_AMOUNT1", hdxIs0 ? 10_000e18 : 1_000_000e12);
        _setU("ANCHOR_MAX0", 1e18);
        _setU("ANCHOR_MAX1", 1e18);
        _setU("ANCHOR_LIQUIDITY", 1e12);

        vm.prank(stranger);
        MANAGER.initialize(hdxHollarKey, TickMath.getSqrtPriceAtTick(expected + 2000));

        new SetupPool().run();
        (IPriceSource source,,,,,,,,,,,) = hdxHollar.config(hdxHollarKey.toId());
        assertTrue(address(source) != address(0), "configured");
        assertGt(_gap(hdxHollarKey, expected), 300, "setup does not move the price");

        FundPool fund = new FundPool();
        vm.expectRevert(bytes("pool is further from the oracle than its guard: run AnchorPool first"));
        fund.run();

        new AnchorPool().run();
        assertLe(_gap(hdxHollarKey, expected), 1, "anchored onto the oracle");

        new FundPool().run();
        (,,, uint128 liq) = hdxHollar.core(hdxHollarKey.toId());
        assertGt(liq, 0, "HDX/HOLLAR funded");
    }

    /// Withdrawing ETH/HOLLAR returns its tokens to the deployer and leaves the other two pools'
    /// positions exactly as they were: each pool's tokens sit behind its own hook.
    function _withdrawingOnePoolLeavesTheOthersUntouched() internal {
        (int24 lo, int24 hi,, uint128 ethHdxLiq) = ethHdx.core(ethHdxKey.toId());
        (,,, uint128 hdxHollarLiq) = hdxHollar.core(hdxHollarKey.toId());
        uint256 ethBefore = deployer.balance;
        uint256 hollarBefore = hollar.balanceOf(deployer);

        vm.prank(deployer);
        ethHollar.withdraw(ethHollarKey.toId());

        assertGt(deployer.balance, ethBefore, "the pool's ETH came back");
        assertGt(hollar.balanceOf(deployer), hollarBefore, "the pool's HOLLAR came back");
        (,,, uint128 ethHdxAfter) = ethHdx.core(ethHdxKey.toId());
        (,,, uint128 hdxHollarAfter) = hdxHollar.core(hdxHollarKey.toId());
        assertEq(ethHdxAfter, ethHdxLiq, "ETH/HDX untouched");
        assertEq(hdxHollarAfter, hdxHollarLiq, "HDX/HOLLAR untouched");
        (uint128 held,,) = MANAGER.getPositionInfo(ethHdxKey.toId(), address(ethHdx), lo, hi, bytes32(0));
        assertEq(held, ethHdxLiq, "and the PoolManager still holds it");
    }

    /// 03 once per pool: each hook's pending owner becomes the multisig, which accepts each one.
    function _handEachHookToTheMultisig() internal {
        BandHook[3] memory hooks = [ethHollar, hdxHollar, ethHdx];
        for (uint256 i; i < 3; i++) {
            _setA("HOOK", address(hooks[i]));
            new HandOff().run();
            assertEq(hooks[i].pendingOwner(), multisig, "handed off");
            vm.prank(multisig);
            hooks[i].acceptOwnership();
            assertEq(hooks[i].owner(), multisig, "the multisig owns it");
            assertEq(hooks[i].pendingOwner(), address(0), "nothing pending");
        }
    }

    // ---------- helpers

    function _key(BandHook hook, address c0, address c1, int24 spacing) internal pure returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(hook)));
    }

    /// The pool tick at the raw price num / den (raw token1 per raw token0), worked out apart
    /// from the scripts, the way an operator would from the market.
    function _tickOf(uint256 num, uint256 den) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1 << 192, den))));
    }

    function _gap(PoolKey memory key, int24 tick) internal view returns (uint256) {
        (, int24 t,,) = MANAGER.getSlot0(key.toId());
        int256 d = int256(t) - int256(tick);
        return uint256(d < 0 ? -d : d);
    }

    function _poolEnv(BandHook hook, address c0, address c1, int24 spacing, uint8 dec0, uint8 dec1) internal {
        _setA("HOOK", address(hook));
        _setA("CURRENCY0", c0);
        _setA("CURRENCY1", c1);
        _setI("TICK_SPACING", spacing);
        _setU("TOKEN0_DECIMALS", dec0);
        _setU("TOKEN1_DECIMALS", dec1);
        _setU("TICK_TOLERANCE", 100);
    }

    function _params(uint256 floor, uint256 cap, uint256 stale, int24 half, int24 backstop, int24 trigger, int24 guard)
        internal
    {
        _setU("FEE_FLOOR_PPM", floor);
        _setU("FEE_CAP_PPM", cap);
        _setU("FEE_SLOPE_PPM", 1_000_000);
        _setU("STALE_AFTER_S", stale);
        _setI("HALF_BAND_TICKS", half);
        _setI("BACKSTOP_HALF_TICKS", backstop);
        _setU("BACKSTOP_BPS", 3500);
        _setI("TRIGGER_TICKS", trigger);
        _setI("GUARD_TICKS", guard);
    }

    function _setU(string memory name, uint256 value) internal {
        vm.setEnv(name, vm.toString(value));
    }

    function _setI(string memory name, int256 value) internal {
        vm.setEnv(name, vm.toString(value));
    }

    function _setA(string memory name, address value) internal {
        vm.setEnv(name, vm.toString(value));
    }

    function _setS(string memory name, string memory value) internal {
        vm.setEnv(name, value);
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n < b.length ? n : b.length);
        for (uint256 i; i < out.length; i++) {
            out[i] = b[i];
        }
        return string(out);
    }
}
