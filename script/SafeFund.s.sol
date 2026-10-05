// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Writes the Safe batch that funds one pool in a single transaction: approve, anchor the price onto
// the oracle, approve, fund. Nobody can move the price between the anchor and the fund. Run it once
// the Safe owns the hook (after 03_HandOff and acceptOwnership); the Safe holds the capital.
//
//   set -a; source .env.eth-hollar; set +a
//   forge script script/SafeFund.s.sol --rpc-url robinhood --broadcast
//
// Broadcasts one transaction from PRIVATE_KEY, which deploys the PoolAnchor the batch calls, then
// writes broadcast/safe-batches/<pool id>.json for the Safe app's Transaction Builder. Sign and run
// it soon: the anchor targets the oracle price read now, and fund refuses if the oracle has moved
// further than the guard since.

import {console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PoolScript} from "./PoolScript.sol";
import {PoolAnchor} from "./PoolAnchor.sol";

interface IApprovable {
    function approve(address, uint256) external returns (bool);
}

contract SafeFund is PoolScript {
    using PoolIdLibrary for PoolKey;

    /// @notice One call the Safe makes: to whom, how much ETH, and what.
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function run() external {
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        PoolKey memory key = _poolKey(address(hook));
        PoolId id = key.toId();
        address safe = hook.owner();
        require(safe.code.length > 0, "the hook's owner is not the Safe yet: run 03_HandOff, then acceptOwnership");
        (IPriceSource source,,,, uint32 staleAfter,,,,,,,) = hook.config(id);
        require(address(source) != address(0), "pool not configured: run 01_SetupPool first");
        (uint160 target,) = _oracle(source, staleAfter);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PoolAnchor helper = new PoolAnchor(MANAGER);
        vm.stopBroadcast();

        Call[] memory batch = calls(
            hook,
            key,
            helper,
            target,
            vm.envUint("ANCHOR_MAX0"),
            vm.envUint("ANCHOR_MAX1"),
            vm.envUint("FUND_AMOUNT0"),
            vm.envUint("FUND_AMOUNT1")
        );
        vm.createDir("broadcast/safe-batches", true);
        string memory path = string.concat("broadcast/safe-batches/", vm.toString(PoolId.unwrap(id)), ".json");
        vm.writeFile(path, toJson(batch, block.chainid, safe));
        console2.log("Safe batch written:", path);
        console2.log("import it in the Safe app's Transaction Builder, check each call, sign and execute");
    }

    /// @notice The batch, in order: approve the anchor, anchor, approve the hook, fund. Native ETH
    /// needs no approval and travels as value; the anchor returns whatever ETH it does not use.
    function calls(
        BandHook hook,
        PoolKey memory key,
        PoolAnchor helper,
        uint160 target,
        uint256 max0,
        uint256 max1,
        uint256 amount0,
        uint256 amount1
    ) public pure returns (Call[] memory c) {
        bool native = key.currency0.isAddressZero();
        c = new Call[](native ? 4 : 6);
        uint256 i;
        if (!native) {
            c[i++] = Call(Currency.unwrap(key.currency0), 0, abi.encodeCall(IApprovable.approve, (address(helper), max0)));
        }
        c[i++] = Call(Currency.unwrap(key.currency1), 0, abi.encodeCall(IApprovable.approve, (address(helper), max1)));
        c[i++] = Call(address(helper), native ? max0 : 0, abi.encodeCall(PoolAnchor.anchor, (key, target, max0, max1)));
        if (!native) {
            c[i++] = Call(Currency.unwrap(key.currency0), 0, abi.encodeCall(IApprovable.approve, (address(hook), amount0)));
        }
        c[i++] = Call(Currency.unwrap(key.currency1), 0, abi.encodeCall(IApprovable.approve, (address(hook), amount1)));
        c[i++] = Call(address(hook), native ? amount0 : 0, abi.encodeCall(BandHook.fund, (key.toId(), amount0, amount1)));
    }

    /// @notice The batch as a file for the Safe app's Transaction Builder.
    function toJson(Call[] memory c, uint256 chainId, address safe) public view returns (string memory json) {
        json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(chainId),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"BandHook: anchor and fund","description":"","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":['
        );
        for (uint256 i; i < c.length; i++) {
            json = string.concat(
                json,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(c[i].to),
                '","value":"',
                vm.toString(c[i].value),
                '","data":"',
                vm.toString(c[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        json = string.concat(json, "]}");
    }
}
