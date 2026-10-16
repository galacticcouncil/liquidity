// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Begins the 2-step ownership transfer of one pool's hook to its next owner, NEW_OWNER.
// Run once per pool, right after 01 and before any funding, with that pool's settings loaded.
// A Safe then calls acceptOwnership() and funds with SafeFund; a plain wallet runs script/fund.sh,
// which accepts and funds in one transaction.
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
        console2.log("next: the new owner accepts (a Safe: acceptOwnership(); a wallet: script/fund.sh)");
    }
}
