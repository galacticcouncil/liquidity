// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Deploys one pool's BandHook via the canonical CREATE2 proxy, at a salt-mined address whose
// low bits encode AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP (0x10C0). Each pool gets its own
// hook: run this once per pool. Every run mines the next free salt, so three runs give three hooks.
// Put the printed address in that pool's settings file as HOOK.
//
//   forge script script/00_DeployBandHook.s.sol --rpc-url robinhood --broadcast
//
// env: PRIVATE_KEY (deployer; the hook's first owner until 03_HandOff)

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BandHook} from "../src/BandHook.sol";
import {HookMiner} from "./HookMiner.sol";

contract DeployBandHook is Script {
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function run() external returns (BandHook hook) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory creationCode = abi.encodePacked(type(BandHook).creationCode, abi.encode(MANAGER, deployer));
        (address expected, bytes32 salt) = HookMiner.find(flags, creationCode);
        console2.log("mined hook address:", expected);
        console2.log("salt:", uint256(salt));

        vm.startBroadcast(pk);
        hook = new BandHook{salt: salt}(MANAGER, deployer);
        vm.stopBroadcast();

        require(address(hook) == expected, "address mismatch");
        console2.log("BandHook deployed:", address(hook));
        console2.log("owner (deployer, hand off via 03):", deployer);
        console2.log("set HOOK in this pool's settings file to:", address(hook));
    }
}
