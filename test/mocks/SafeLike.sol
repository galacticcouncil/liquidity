// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Stands in for the Safe in tests: owns hooks and runs a batch of calls in one transaction, all or
// nothing, as the Safe runs a Transaction Builder batch.

import {SafeFund} from "../../script/SafeFund.s.sol";

contract SafeLike {
    function execute(SafeFund.Call[] calldata calls) external {
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    receive() external payable {}
}
