// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Test doubles for the in-swap recenter: a token that pays one wei short, a router that pays
// before it swaps, and a contract that tries the in-swap entry from inside its own unlock.

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BaseToken} from "./NonStandardERC20.sol";

/// @notice Honest everywhere except one route: a transfer from `shortFrom` to `shortTo` moves one
/// wei less than asked, the way a rounding or fee-taking token would. The call still succeeds.
contract ShortPayERC20 is BaseToken {
    address public shortFrom;
    address public shortTo;

    constructor(string memory n, string memory s) BaseToken(n, s) {}

    function setShortPay(address from, address to) external {
        shortFrom = from;
        shortTo = to;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 moved = (msg.sender == shortFrom && to == shortTo && amount > 0) ? amount - 1 : amount;
        _move(msg.sender, to, moved);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}

interface ITransferFrom {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Pays before it swaps: sync, transfer in, swap, settle, take. The v4 interface only asks
/// that sync comes before the transfer, so this order is allowed, and the payment is still open
/// while the swap and its hooks run.
contract PrepayRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    /// @notice Sell exactly `amountIn` of currency1 for currency0.
    function buyZero(PoolKey memory key, uint256 amountIn) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, amountIn)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (address payer, PoolKey memory key, uint256 amountIn) = abi.decode(data, (address, PoolKey, uint256));
        manager.sync(key.currency1);
        ITransferFrom(Currency.unwrap(key.currency1)).transferFrom(payer, address(manager), amountIn);
        BalanceDelta d = manager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        manager.settle();
        manager.take(key.currency0, payer, uint256(int256(d.amount0())));
        return abi.encode(d);
    }
}

interface IRecenterInSwap {
    function recenterInSwap(PoolId id) external;
}

/// @notice Opens its own unlock and calls the hook's in-swap entry from inside it, the one place
/// where that entry could do real work if it trusted any caller.
contract SelfCallProbe is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function probe(address hook, PoolId id) external {
        manager.unlock(abi.encode(hook, id));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address hook, PoolId id) = abi.decode(data, (address, PoolId));
        IRecenterInSwap(hook).recenterInSwap(id);
        return "";
    }
}

/// @notice Runs a third party's code in the middle of one transfer route (`watchFrom` to `watchTo`),
/// once, the way an ERC777-style send hook does. The move itself happens after the callback.
contract CallbackOnTransferERC20 is BaseToken {
    address public watchFrom;
    address public watchTo;
    address public callback;

    constructor(string memory n, string memory s) BaseToken(n, s) {}

    function watch(address from, address to, address c) external {
        (watchFrom, watchTo, callback) = (from, to, c);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        address c = callback;
        if (c != address(0) && msg.sender == watchFrom && to == watchTo) {
            callback = address(0);
            IPoke2(c).poke();
        }
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}

interface IPoke2 {
    function poke() external;
}

/// @notice Clears the PoolManager's shared "synced currency" slot when poked: the one thing code
/// running inside the hook's payment can do to make that payment count for nothing.
contract SyncClearer is IPoke2 {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function poke() external {
        manager.sync(Currency.wrap(address(0)));
    }
}

/// @notice Reverts with `size` bytes of data on one transfer route, to make any caller that copies
/// the revert pay for the memory.
contract BombERC20 is BaseToken {
    address public watchFrom;
    address public watchTo;
    uint256 public size;

    constructor(string memory n, string memory s) BaseToken(n, s) {}

    function arm(address from, address to, uint256 bytes_) external {
        (watchFrom, watchTo, size) = (from, to, bytes_);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (size != 0 && msg.sender == watchFrom && to == watchTo) {
            uint256 n = size;
            assembly {
                revert(0, n)
            }
        }
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}

/// @notice A route with work after our pool: swap, then spend `tailWrites` fresh storage writes
/// (standing in for more hops), then pay and collect. Sells currency1 for currency0.
contract TailRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    uint256 internal slotBase;

    constructor(IPoolManager m) {
        manager = m;
    }

    function run(PoolKey memory key, uint256 amountIn, uint160 limit, uint256 tailWrites) external {
        manager.unlock(abi.encode(msg.sender, key, amountIn, limit, tailWrites));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory key, uint256 amountIn, uint160 limit, uint256 tailWrites) =
            abi.decode(data, (address, PoolKey, uint256, uint160, uint256));
        BalanceDelta d = manager.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        uint256 base = slotBase;
        for (uint256 i = 0; i < tailWrites; i++) {
            assembly {
                sstore(add(0x1000000, add(base, i)), 1)
            }
        }
        slotBase = base + tailWrites;
        manager.sync(key.currency1);
        ITransferFrom(Currency.unwrap(key.currency1)).transferFrom(payer, address(manager), uint256(int256(-d.amount1())));
        manager.settle();
        manager.take(key.currency0, payer, uint256(int256(d.amount0())));
        return "";
    }
}

/// @notice Burns gas when the PoolManager pays the watched address: an attempt that collects from
/// the PoolManager runs out of gas inside, the one failure a try/catch cannot turn into a reason.
contract GasGuzzlerERC20 is BaseToken {
    address public payer;
    address public payee;
    uint256 internal junk;

    constructor(string memory n, string memory s) BaseToken(n, s) {}

    function watch(address from, address to) external {
        (payer, payee) = (from, to);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (payer != address(0) && msg.sender == payer && to == payee) {
            while (gasleft() > 5_000) {
                junk = uint256(keccak256(abi.encode(junk)));
            }
        }
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}
