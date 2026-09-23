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
            source = _deploySource();
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

    /// @dev SOURCE=ratio divides FEED0_USD (prices token0) by FEED1_USD (prices token1).
    /// SOURCE=single reads FEED, which prices pool token FEED_PRICES_TOKEN (0 or 1) in a
    /// USD-stable other token. Decimals are always the pool tokens' own, TOKEN0/TOKEN1_DECIMALS.
    function _deploySource() internal returns (IPriceSource) {
        uint8 dec0 = uint8(vm.envUint("TOKEN0_DECIMALS"));
        uint8 dec1 = uint8(vm.envUint("TOKEN1_DECIMALS"));
        bytes32 kind = keccak256(bytes(vm.envString("SOURCE")));
        if (kind == keccak256("ratio")) {
            IAggregatorV3 feed0 = IAggregatorV3(vm.envAddress("FEED0_USD"));
            IAggregatorV3 feed1 = IAggregatorV3(vm.envAddress("FEED1_USD"));
            return IPriceSource(address(new RatioSource(feed0, feed1, dec0, dec1)));
        }
        require(kind == keccak256("single"), "SOURCE must be single or ratio");
        uint256 pricesToken = vm.envUint("FEED_PRICES_TOKEN");
        require(pricesToken <= 1, "FEED_PRICES_TOKEN must be 0 or 1");
        bool invert = pricesToken == 1;
        IAggregatorV3 feed = IAggregatorV3(vm.envAddress("FEED"));
        return IPriceSource(address(new ChainlinkSource(feed, invert, invert ? dec1 : dec0, invert ? dec0 : dec1)));
    }

    /// @dev The one mistake nothing else catches: a source the wrong way up or with the wrong
    /// decimals. The operator states the tick the market implies; the source must agree.
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
                    ": check the feed order, the feed addresses and the token decimals"
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
