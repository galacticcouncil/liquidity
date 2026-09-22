// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Moves a pool's price onto a target in one transaction, the way the Gamma launch did on v3
// (11-anchor-price.js): mint a tiny position straddling the current price, swap to the target,
// burn the position. The caller pays what it costs and gets back whatever is left.

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

contract PoolAnchor is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    IPoolManager public immutable manager;

    error NotManager();
    error AlreadyAtTarget();
    error TargetNotReached();
    error TransferFailed();

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    receive() external payable {}

    /// @notice Move `key`'s price to `target`. `liquidity` sizes the tiny straddling position.
    /// `maxIn` caps what the swap may spend of its input token; if that is not enough to reach
    /// the target, nothing happens. ERC20 amounts are pulled from the caller, who must approve
    /// this contract first; native ETH comes from msg.value, and the unused part is returned.
    function anchor(PoolKey calldata key, uint160 target, uint128 liquidity, uint256 maxIn) external payable {
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (current == target) revert AlreadyAtTarget();
        manager.unlock(abi.encode(msg.sender, key, target, liquidity, maxIn));
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            if (!ok) revert TransferFailed();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (address payer, PoolKey memory key, uint160 target, uint128 liquidity, uint256 maxIn) =
            abi.decode(data, (address, PoolKey, uint160, uint128, uint256));
        (uint160 current, int24 tick,,) = manager.getSlot0(key.toId());

        int24 lo = _floorTick(tick, key.tickSpacing) - key.tickSpacing;
        int24 hi = lo + 2 * key.tickSpacing;
        _modify(key, lo, hi, int256(uint256(liquidity)));
        manager.swap(
            key,
            SwapParams({zeroForOne: target < current, amountSpecified: -maxIn.toInt256(), sqrtPriceLimitX96: target}),
            ""
        );
        (uint160 reached,,,) = manager.getSlot0(key.toId());
        if (reached != target) revert TargetNotReached();
        _modify(key, lo, hi, -int256(uint256(liquidity)));

        _settle(key.currency0, payer);
        _settle(key.currency1, payer);
        return "";
    }

    function _modify(PoolKey memory key, int24 lo, int24 hi, int256 delta) internal {
        manager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: delta, salt: bytes32(0)}), ""
        );
    }

    /// @dev Pay what this contract owes the PoolManager in `c`, or send the payer what it is owed.
    function _settle(Currency c, address payer) internal {
        int256 delta = manager.currencyDelta(address(this), c);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            manager.sync(c);
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                _pull(Currency.unwrap(c), payer, owed);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(c, payer, uint256(delta));
        }
    }

    /// @dev transferFrom the payer straight to the PoolManager; accepts tokens that return nothing.
    function _pull(address token, address payer, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(manager), amount)
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || token.code.length == 0) revert TransferFailed();
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }
}
