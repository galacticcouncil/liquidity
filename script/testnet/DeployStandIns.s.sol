// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Deploys what Robinhood testnet lacks, so the real launch scripts can run there: HDX and HOLLAR
// stand-ins (HDX at the lower address, as on mainnet), ETH/USD and HDX/USD feeds at today's mainnet
// prices, and a byte-for-byte copy of mainnet's Simple7702Account; then mints tokens to the owner and the attacker.
// Run by script/testnet/rehearse.sh, which fetches the answers and the code from mainnet:
//
//   env: PRIVATE_KEY (the deployer), OWNER, ATTACKER, ETH_USD_ANSWER, HDX_USD_ANSWER (8 decimals), SIMPLE7702_CODE
//
// Writes broadcast/testnet/<chain id>/standins.env with the addresses.

import {Script, console2} from "forge-std/Script.sol";
import {TestToken, TestFeed} from "./StandIns.sol";

contract DeployStandIns is Script {
    /// @dev keccak256 of Simple7702Account's runtime code on Robinhood mainnet (and Ethereum).
    bytes32 constant SIMPLE7702_CODEHASH = 0x82c1e6c0f83d22eef579344e8eff26baf24db4dabe5408d681b00d0512bc3ec4;
    uint256 constant MINT_HDX = 1_000_000e12; // 12 decimals
    uint256 constant MINT_HOLLAR = 100_000e18; // 18 decimals

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bytes memory runtime = vm.envBytes("SIMPLE7702_CODE");
        require(keccak256(runtime) == SIMPLE7702_CODEHASH, "SIMPLE7702_CODE is not mainnet's Simple7702Account");

        // The next two contracts land at the deployer's next two nonces: HDX takes the lower address.
        uint64 n = vm.getNonce(deployer);
        bool hdxFirst = vm.computeCreateAddress(deployer, n) < vm.computeCreateAddress(deployer, n + 1);

        vm.startBroadcast(pk);
        TestToken hdx;
        TestToken hollar;
        if (hdxFirst) {
            hdx = new TestToken("HDX (testnet stand-in)", "HDX", 12);
            hollar = new TestToken("HOLLAR (testnet stand-in)", "HOLLAR", 18);
        } else {
            hollar = new TestToken("HOLLAR (testnet stand-in)", "HOLLAR", 18);
            hdx = new TestToken("HDX (testnet stand-in)", "HDX", 12);
        }
        TestFeed ethUsd = new TestFeed(8, vm.envInt("ETH_USD_ANSWER"));
        TestFeed hdxUsd = new TestFeed(8, vm.envInt("HDX_USD_ANSWER"));
        address simple7702 = _copy(runtime);
        address[2] memory people = [vm.envAddress("OWNER"), vm.envAddress("ATTACKER")];
        for (uint256 i; i < 2; i++) {
            hdx.mint(people[i], MINT_HDX);
            hollar.mint(people[i], MINT_HOLLAR);
        }
        vm.stopBroadcast();

        require(address(hdx) < address(hollar), "HDX must sort below HOLLAR, as on mainnet");
        require(simple7702.codehash == SIMPLE7702_CODEHASH, "Simple7702Account copy differs");

        string memory dir = string.concat("broadcast/testnet/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory out = string.concat(
            "HDX=", vm.toString(address(hdx)), "\nHOLLAR=", vm.toString(address(hollar)),
            "\nETH_USD_FEED=", vm.toString(address(ethUsd)), "\nHDX_USD_FEED=", vm.toString(address(hdxUsd)),
            "\nSIMPLE7702=", vm.toString(simple7702), "\n"
        );
        vm.writeFile(string.concat(dir, "/standins.env"), out);
        console2.log(out);
    }

    /// @dev Deploys `runtime` unchanged behind a 12-byte constructor that only returns it:
    /// PUSH2 len, DUP1, PUSH1 12, PUSH1 0, CODECOPY, PUSH1 0, RETURN.
    function _copy(bytes memory runtime) internal returns (address a) {
        bytes memory init = abi.encodePacked(hex"61", uint16(runtime.length), hex"80600c6000396000f3", runtime);
        assembly {
            a := create(0, add(init, 32), mload(init))
        }
        require(a != address(0), "copy failed");
    }
}
