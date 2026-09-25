// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Sets up one pool on its own hook: deploys the pool's price source, checks it against the
// tick the operator expects (a mismatch stops the script before anything is configured),
// configures the hook, and initializes the pool at the oracle price. Run once per pool, with that pool's settings loaded:
//
//   set -a; source .env.eth-hollar; set +a
//   forge script script/01_SetupPool.s.sol --rpc-url robinhood --broadcast
//
// Caller must be the hook's owner. If someone initialized the pool first, the script checks
// its price against the oracle instead of initializing: further than GUARD_TICKS away, it
// says so, and the pool must go through AnchorPool before 02_Fund.

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BandHook} from "../src/BandHook.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {RatioSource} from "../src/sources/RatioSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolScript} from "./PoolScript.sol";

contract SetupPool is PoolScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        PoolKey memory key = _poolKey(address(hook));
        PoolId id = key.toId();

        (IPriceSource source,,,,,,,,,,,) = hook.config(id);
        if (address(source) == address(0)) {
            vm.startBroadcast(pk);
            source = _deploySource(key);
            vm.stopBroadcast();
            _checkExpectedTick(source);
            vm.startBroadcast(pk);
            hook.configure(key, _configFromEnv(source));
            vm.stopBroadcast();
        }
        (uint160 sqrtOracle, int24 oracleTick) = _oracle(source, vm.envUint("STALE_AFTER_S"));
        (uint160 sqrtPool, int24 poolTick,,) = MANAGER.getSlot0(id);
        vm.startBroadcast(pk);
        if (sqrtPool == 0) {
            MANAGER.initialize(key, sqrtOracle);
            console2.log("pool initialized at the oracle price, tick", int256(oracleTick));
        } else {
            hook.syncFee(id);
        }
        vm.stopBroadcast();
        if (sqrtPool != 0) _reportExistingPool(poolTick, oracleTick);

        console2.log("source:", address(source));
        console2.log("POOL_ID:");
        console2.logBytes32(PoolId.unwrap(id));
    }

    /// @dev Every feed is named with the token it prices, by address, and the source works out the
    /// orientation and the decimals itself. SOURCE=single reads FEED, which prices FEED_PRICES in
    /// the pool's other, USD-stable token. SOURCE=ratio divides two USD feeds, FEED_A (prices
    /// FEED_A_PRICES) and FEED_B (prices FEED_B_PRICES), named in any order.
    function _deploySource(PoolKey memory key) internal returns (IPriceSource) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bytes32 kind = keccak256(bytes(vm.envString("SOURCE")));
        if (kind == keccak256("ratio")) {
            address tokenA = vm.envAddress("FEED_A_PRICES");
            address tokenB = vm.envAddress("FEED_B_PRICES");
            require(
                (tokenA == c0 && tokenB == c1) || (tokenA == c1 && tokenB == c0),
                "FEED_A_PRICES and FEED_B_PRICES must be the pool's two tokens"
            );
            IAggregatorV3 feedA = IAggregatorV3(vm.envAddress("FEED_A"));
            IAggregatorV3 feedB = IAggregatorV3(vm.envAddress("FEED_B"));
            return IPriceSource(address(new RatioSource(tokenA, feedA, tokenB, feedB)));
        }
        require(kind == keccak256("single"), "SOURCE must be single or ratio");
        address priced = vm.envAddress("FEED_PRICES");
        require(priced == c0 || priced == c1, "FEED_PRICES must be one of the pool's two tokens");
        IAggregatorV3 feed = IAggregatorV3(vm.envAddress("FEED"));
        return IPriceSource(address(new ChainlinkSource(feed, priced, priced == c0 ? c1 : c0)));
    }

    /// @dev The one mistake nothing else catches: the wrong feed, or a feed named with the wrong
    /// token. The operator states the tick the market implies; the source must agree.
    function _checkExpectedTick(IPriceSource source) internal view {
        (, int24 tick) = _oracle(source, vm.envUint("STALE_AFTER_S"));
        int24 expected = int24(vm.envInt("EXPECTED_TICK"));
        if (_absDiff(tick, expected) > vm.envUint("TICK_TOLERANCE")) {
            revert(
                string.concat(
                    "source reads tick ",
                    vm.toString(int256(tick)),
                    ", expected ",
                    vm.toString(int256(expected)),
                    ": check each feed's address and the token it is named with"
                )
            );
        }
    }

    function _configFromEnv(IPriceSource source) internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: source,
            feeFloor: uint24(vm.envUint("FEE_FLOOR_PPM")),
            feeCap: uint24(vm.envUint("FEE_CAP_PPM")),
            feeSlopePpm: uint32(vm.envUint("FEE_SLOPE_PPM")),
            staleAfter: uint32(vm.envUint("STALE_AFTER_S")),
            halfBandTicks: int24(int256(vm.envInt("HALF_BAND_TICKS"))),
            backstopHalfTicks: int24(int256(vm.envInt("BACKSTOP_HALF_TICKS"))),
            backstopBps: uint16(vm.envUint("BACKSTOP_BPS")),
            triggerTicks: int24(int256(vm.envInt("TRIGGER_TICKS"))),
            guardTicks: int24(int256(vm.envInt("GUARD_TICKS"))),
            enabled: true,
            autoRecenter: vm.envOr("AUTO_RECENTER", false)
        });
    }

    /// @dev Somebody initialized the pool before us. Within the guard it can be funded as is;
    /// further out, funding would be refused, so the pool must be anchored first.
    function _reportExistingPool(int24 poolTick, int24 oracleTick) internal view {
        uint256 gap = _absDiff(poolTick, oracleTick);
        console2.log("pool was already initialized; ticks from the oracle:", gap);
        if (gap > vm.envUint("GUARD_TICKS")) {
            console2.log("OFF THE ORACLE BY MORE THAN GUARD_TICKS: run AnchorPool before 02_Fund");
        }
    }
}
