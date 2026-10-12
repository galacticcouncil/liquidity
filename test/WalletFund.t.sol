// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BandHook} from "../src/BandHook.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {SafeFund} from "../script/SafeFund.s.sol";
import {PoolAnchor} from "../script/PoolAnchor.sol";
import {WalletFund} from "../script/WalletFund.s.sol";

interface IMintable {
    function minter() external view returns (address);
    function mint(address to, uint256 amount) external;
}

/// WalletFund's dry run on a fork of Robinhood Chain, with the real ETH/USD feed, HOLLAR and
/// Simple7702Account. The hook is left the way 00, 01 and 03 leave it (configured, initialized at the
/// oracle price, offered to the owner's wallet), but built directly: the launch scripts read
/// process-wide environment variables, and building it here lets each case run on its own.
contract WalletFundForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant HOLLAR = 0xD1dc3517732c98502b5c1ba2389AcA9E9016d89a;
    address constant SIMPLE7702 = 0x4Cd241E8d1510e30b2076397afc7508Ae59C66c9;
    // a key nobody else uses: well-known test keys have sweeper code on live chains
    uint256 constant OWNER_PK = uint256(keccak256("wallet fund fork test owner"));

    address owner;
    address deployer = makeAddr("deployer");
    address attacker = makeAddr("attacker");
    BandHook hook;
    ChainlinkSource source;
    PoolKey key;
    WalletFund script;
    WalletFund.Settings settings;

    function setUp() public {
        vm.createSelectFork("robinhood");
        owner = vm.addr(OWNER_PK);
        // any address with the hook's permission bits will do; 00 mines one through the CREATE2 proxy
        address at = address((uint160(uint256(keccak256("wallet fund fork test hook"))) & ~uint160(0x3FFF)) | 0x10C0);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(MANAGER, deployer), at);
        hook = BandHook(payable(at));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(HOLLAR), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(at));
        source = new ChainlinkSource(IAggregatorV3(ETH_USD), address(0), HOLLAR);

        vm.startPrank(deployer);
        hook.configure(key, _ethHollarConfig());
        MANAGER.initialize(key, _oracleSqrtPrice());
        hook.transferOwnership(owner);
        vm.stopPrank();

        vm.deal(owner, 20 ether);
        // as the bridge would: forge-std's deal() needs a cheatcode this forge does not have
        vm.prank(IMintable(HOLLAR).minter());
        IMintable(HOLLAR).mint(owner, 50_000e18);
        script = new WalletFund();
        settings = WalletFund.Settings(
            4663, owner, hook, key, ETH_USD, address(0), _ethHollarConfig(), SIMPLE7702, 7.5 ether, 1e15, 1e18
        );
    }

    /// Nobody touched the pool since setup: the dry run accepts the hook, the anchor does nothing, and
    /// the deposit lands at the oracle price, the ETH and HOLLAR of equal value.
    function test_nobodyMovedThePrice_checkFundsAtTheOracle() public {
        uint256 eth0 = owner.balance;
        uint256 hollar0 = IERC20Minimal(HOLLAR).balanceOf(owner);
        (uint256 px,) = source.priceX18();

        SafeFund.Call[] memory batch = script.check(settings, OWNER_PK);

        assertEq(batch.length, 5, "accept, approve, anchor, approve, fund");
        assertEq(batch[0].to, address(hook), "accept goes to the hook");
        assertEq(batch[0].data, abi.encodeCall(BandHook.acceptOwnership, ()), "accept first");
        assertEq(hook.owner(), owner, "the wallet owns the hook");
        assertEq(hook.pendingOwner(), address(0), "nothing pending");
        assertEq(_poolTick(), _oracleTick(), "the pool sits on the oracle");
        (,,, uint128 core) = hook.core(key.toId());
        (,,, uint128 backstop) = hook.backstop(key.toId());
        assertGt(core, 0, "core band placed");
        assertGt(backstop, 0, "backstop placed");
        assertEq(eth0 - owner.balance, 7.5 ether, "spent exactly the ETH deposit; the anchor's ETH came back");
        assertEq(hollar0 - IERC20Minimal(HOLLAR).balanceOf(owner), 7.5 ether * px / 1e18, "HOLLAR of equal value");
    }

    /// An attacker moved the empty pool 2,000 ticks up for free before the owner funds: the batch's
    /// anchor puts it back on the oracle, and the deposit lands there.
    function test_anAttackerMovedTheEmptyPool_theBatchPutsItBack() public {
        int24 oracleTick = _oracleTick();
        vm.startPrank(attacker);
        new PoolAnchor(MANAGER).anchor(key, TickMath.getSqrtPriceAtTick(oracleTick + 2000), 0, 1);
        vm.stopPrank();
        assertGe(_poolTick(), oracleTick + 1999, "moved, and it cost nothing");

        script.check(settings, OWNER_PK);

        assertEq(_poolTick(), oracleTick, "put back on the oracle");
        (,,, uint128 core) = hook.core(key.toId());
        assertGt(core, 0, "core band placed");
    }

    /// The wallet accepted the hook by hand earlier: the batch leaves the accept out and still funds.
    function test_alreadyAccepted_theBatchLeavesAcceptOut() public {
        vm.prank(owner);
        hook.acceptOwnership();

        SafeFund.Call[] memory batch = script.check(settings, OWNER_PK);

        assertEq(batch.length, 4, "approve, anchor, approve, fund");
        assertEq(batch[0].to, HOLLAR, "starts with the anchor's approval");
        (,,, uint128 core) = hook.core(key.toId());
        assertGt(core, 0, "core band placed");
    }

    /// After the batch and the clearing transaction, verify passes; while the wallet still carries the
    /// borrowed code it does not.
    function test_verify_passesOnceTheBorrowedCodeIsCleared() public {
        script.check(settings, OWNER_PK);
        vm.expectRevert(bytes("the wallet still has borrowed code: clear it"));
        script.verify(settings);

        vm.etch(owner, ""); // what the clearing transaction does
        script.verify(settings);
    }

    // ---------- refusals: each stops the check before anything would be sent

    function test_refuses_settingsForAnotherChain() public {
        settings.chainId = 46630;
        _expectRefusal("RPC is chain 4663, settings are for 46630");
    }

    function test_refuses_aKeyThatIsNotNewOwner() public {
        settings.owner = makeAddr("another wallet");
        _expectRefusal("the key in .env is not NEW_OWNER");
    }

    function test_refuses_aWalletThatAlreadyHasCode() public {
        vm.etch(owner, abi.encodePacked(hex"ef0100", makeAddr("some smart wallet")));
        _expectRefusal(
            string.concat(
                "the wallet already has code (an EIP-7702 delegation); clear it with: cast send ",
                vm.toString(owner),
                " --auth 0x0000000000000000000000000000000000000000 --private-key <key> --rpc-url <rpc>"
            )
        );
    }

    function test_refuses_aDelegateThatIsNotSimple7702Account() public {
        settings.simple7702 = makeAddr("no code here");
        _expectRefusal("SIMPLE7702 is not Simple7702Account");
    }

    function test_refuses_aHookOfferedToAnotherWallet() public {
        vm.prank(deployer);
        hook.transferOwnership(makeAddr("another wallet"));
        _expectRefusal("the hook is not offered to this wallet");
    }

    function test_refuses_aHookSettingThatDiffersFromTheFile() public {
        settings.cfg.feeCap = 20000;
        _expectRefusal("the hook's setting differs from the file: FEE_CAP_PPM");
    }

    function test_refuses_anAutoRecenterThatDiffersFromTheFile() public {
        settings.cfg.autoRecenter = false;
        _expectRefusal("the hook's setting differs from the file: AUTO_RECENTER");
    }

    function test_refuses_aSourceOnAnotherFeed() public {
        settings.feed = makeAddr("another feed");
        _expectRefusal("the pool's price source does not read FEED for FEED_PRICES");
    }

    function test_refuses_aFeedNamedWithTheWrongToken() public {
        settings.feedPrices = HOLLAR;
        _expectRefusal("the pool's price source does not read FEED for FEED_PRICES");
    }

    function test_refuses_aPoolNotInitialized() public {
        address at = address((uint160(uint256(keccak256("wallet fund fork test hook 2"))) & ~uint160(0x3FFF)) | 0x10C0);
        deployCodeTo("BandHook.sol:BandHook", abi.encode(MANAGER, deployer), at);
        settings.hook = BandHook(payable(at));
        settings.key.hooks = IHooks(at);
        vm.startPrank(deployer);
        settings.hook.configure(settings.key, _ethHollarConfig());
        settings.hook.transferOwnership(owner);
        vm.stopPrank();
        _expectRefusal("the pool is not initialized: the deployer runs 01 first");
    }

    /// A second send after the first went through would deposit again: the check stops it.
    function test_refuses_aPoolAlreadyFunded() public {
        script.check(settings, OWNER_PK);
        vm.etch(owner, ""); // the clearing transaction
        _expectRefusal("the pool is already funded: fund.sh deposits once");
    }

    function test_refuses_aStaleFeed() public {
        vm.warp(block.timestamp + 29 hours);
        _expectRefusal("oracle stale");
    }

    function test_refuses_aZeroDeposit() public {
        settings.amount0 = 0;
        _expectRefusal("FUND_ETH is zero");
    }

    function test_refuses_tooLittleEth_sayingHowMuchIsNeeded() public {
        vm.deal(owner, 7.5 ether);
        _expectRefusal("the wallet holds too little ETH: needs 7502000000000000000 wei");
    }

    function test_refuses_tooLittleHollar_sayingTheMostEthItCanMatch() public {
        settings.amount0 = 30 ether;
        vm.deal(owner, 40 ether); // enough ETH, so the HOLLAR side is what runs short
        (uint256 px,) = source.priceX18();
        uint256 most = (50_000e18 - 1e18) * 1e18 / px;
        _expectRefusal(
            string.concat("the wallet holds too little token1: FUND_ETH can be at most ", vm.toString(most), " wei")
        );
    }

    // ---------- helpers

    function _expectRefusal(string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.check(settings, OWNER_PK);
    }

    /// The ETH/HOLLAR settings from the pool's settings file, with the in-swap recenter on.
    function _ethHollarConfig() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: source,
            feeFloor: 800,
            feeCap: 10000,
            feeSlopePpm: 1_000_000,
            staleAfter: 100800,
            halfBandTicks: 700,
            backstopHalfTicks: 11000,
            backstopBps: 3500,
            triggerTicks: 350,
            guardTicks: 200,
            enabled: true,
            autoRecenter: true
        });
    }

    /// The feed's price as a pool price, worked out apart from the scripts.
    function _oracleSqrtPrice() internal view returns (uint160) {
        (uint256 px,) = source.priceX18();
        return uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(px, 1 << 192, 1e18)));
    }

    function _oracleTick() internal view returns (int24) {
        return TickMath.getTickAtSqrtPrice(_oracleSqrtPrice());
    }

    function _poolTick() internal view returns (int24 tick) {
        (, tick,,) = MANAGER.getSlot0(key.toId());
    }
}
