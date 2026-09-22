// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Begins the 2-step ownership transfer of one pool's hook to the final owner (multisig).
// Run once per pool, with that pool's settings loaded; the multisig must then call
// acceptOwnership() on each hook itself.
//
//   set -a; source .env.eth-hollar; set +a
//   forge script script/03_HandOff.s.sol --rpc-url robinhood --broadcast

import {Script, console2} from "forge-std/Script.sol";
import {BandHook} from "../src/BandHook.sol";

contract HandOff is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        address newOwner = vm.envAddress("NEW_OWNER");

        vm.startBroadcast(pk);
        hook.transferOwnership(newOwner);
        vm.stopBroadcast();

        console2.log("pending owner set:", newOwner);
        console2.log("ACTION REQUIRED: multisig must call acceptOwnership()");
    }
}
