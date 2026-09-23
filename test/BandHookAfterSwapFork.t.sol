// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The in-swap recenter on a fork of Robinhood Chain: the real PoolManager, the real Chainlink
// ETH/USD feed, and trades sent through Uniswap's deployed Universal Router with Permit2. Gas is
// read per call, so run with `forge test --isolate`. Written by Claude at Yash's request (2026-09-23).

import {Test} from "forge-std/Test.sol";
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
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract BandHookAfterSwapForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// The deployed router's own struct (its v4-periphery added `minHopPriceX36`).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IUniversalRouter constant ROUTER = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant HOOK_ADDR = address(uint160(0x10000000000000000000000000000000000010c0));

    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    BandHook hook;
    ChainlinkSource source;
    PoolSwapTest pusher;
    MockERC20 hollar;
    PoolKey key;
    PoolId id;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("robinhood");
        pusher = new PoolSwapTest(MANAGER);
        hollar = new MockERC20("Hollar", "HOLLAR", 18);
        source = new ChainlinkSource(ETH_USD, false, 18, 18); // native ETH is currency0
        deployCodeTo("BandHook.sol:BandHook", abi.encode(MANAGER, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

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
                staleAfter: 100_800,
                halfBandTicks: 700,
                backstopHalfTicks: 11_000,
                backstopBps: 3500,
                triggerTicks: 350,
                guardTicks: 200,
                enabled: true,
                autoRecenter: true
            })
        );
        (uint256 px,) = source.priceX18();
        MANAGER.initialize(key, _sqrtPriceX96(px));

        vm.deal(address(this), 10_000 ether);
        hollar.mint(address(this), 100_000_000e18);
        hollar.approve(address(hook), type(uint256).max);
        hollar.approve(address(pusher), type(uint256).max);
        hollar.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(hollar), address(ROUTER), type(uint160).max, type(uint48).max);

        // 100 ETH and the matching HOLLAR at the oracle price
        hook.fund{value: 100 ether}(id, 100 ether, 100 * px);
    }

    // ---------- the measured trades

    /// Sell `amountIn` HOLLAR for ETH through the Universal Router: swap, pay, collect.
    function _routerBuyEth(uint128 amountIn) internal {
        _routerSwap(false, amountIn, 0);
    }

    /// Sell `amountIn` ETH for HOLLAR through the Universal Router.
    function _routerSellEth(uint128 amountIn) internal {
        _routerSwap(true, amountIn, amountIn);
    }

    function _routerSwap(bool zeroForOne, uint128 amountIn, uint256 value) internal {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, 0, 0, ""));
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        ROUTER.execute{value: value}(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 60);
    }

    /// Put the market 4% higher: the feed reads 4% up, and arbitrage (with the switch off, so it
    /// does not recenter yet) brings the pool to 20 ticks under the new oracle price.
    function _makeRecenterDue() internal {
        (uint80 r, int256 ans,,,) = ETH_USD.latestRoundData();
        vm.mockCall(
            address(ETH_USD),
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r, ans * 104 / 100, block.timestamp, block.timestamp, r)
        );
        hook.setAutoRecenter(id, false);
        (, int24 poolTick,,) = MANAGER.getSlot0(id);
        pusher.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -10_000_000e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(poolTick + 392 - 20)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        hook.setAutoRecenter(id, true);
    }

    function _log(string memory what) internal {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok, "lastCallGas");
        (, uint256 used) = abi.decode(ret, (uint256, uint256));
        emit log_named_uint(what, used);
    }

    function _centre() internal view returns (int24 c) {
        (,, c,) = hook.core(id);
    }

    // ---------- scenarios

    function test_fork_A_routerSwap_switchOff() public {
        hook.setAutoRecenter(id, false);
        _routerBuyEth(1000e18);
        _log("A router swap (1,000 HOLLAR -> ETH), switch off");
    }

    function test_fork_B_routerSwap_switchOn_notDue() public {
        _routerBuyEth(1000e18);
        _log("B router swap, switch on, not due (checks only)");
    }

    function test_fork_C_routerSwap_due_switchOff_thenManualRecenter() public {
        _makeRecenterDue();
        int24 before = _centre();
        hook.setAutoRecenter(id, false);
        _routerBuyEth(1000e18);
        _log("C router swap, due, switch off");
        assertEq(_centre(), before, "nothing moved");
        hook.recenter(id);
        _log("C' manual recenter() as its own transaction");
    }

    function test_fork_D_routerSwap_due_switchOn() public {
        _makeRecenterDue();
        int24 before = _centre();
        _routerBuyEth(1000e18);
        _log("D router swap, due, switch on (recenters inside)");
        assertTrue(_centre() != before, "recentered inside the router's swap");
    }

    function test_fork_E_routerSellsEth_due_switchOn() public {
        _makeRecenterDue();
        int24 before = _centre();
        _routerSellEth(0.2 ether);
        _log("E router swap selling ETH, due, switch on");
        assertTrue(_centre() != before, "recentered inside the router's swap");
    }

    function test_fork_F_routerSellsEth_due_switchOff() public {
        _makeRecenterDue();
        hook.setAutoRecenter(id, false);
        _routerSellEth(0.2 ether);
        _log("F router swap selling ETH, due, switch off");
    }

    /// @dev sqrtPriceX96 = sqrt(priceX18/1e18) * 2^96, exact to integer sqrt
    function _sqrtPriceX96(uint256 priceX18) internal pure returns (uint160) {
        uint256 inner = priceX18 * (uint256(1) << 128) / 1e18;
        return uint160(_sqrt(inner) << 32);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
