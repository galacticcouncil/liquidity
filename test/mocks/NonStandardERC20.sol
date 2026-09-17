// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Minimal ERC20 used to exercise the transfer paths. Shared state and logic for
/// the two non-standard variants below.
abstract contract BaseToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint8 public constant decimals = 18;
    string public name;
    string public symbol;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _spendAllowance(address from, uint256 amount) internal {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    }
}

/// @notice Returns `false` instead of reverting, which is the pattern the hook used to
/// treat as success. The two flags decide which call fails, so a test can fund
/// normally and then make the payout leg fail.
contract FalseReturningERC20 is BaseToken {
    bool public failTransferFrom;
    address public failTransferTo;

    constructor(string memory n, string memory s) BaseToken(n, s) {}

    function setFailTransferFrom(bool v) external {
        failTransferFrom = v;
    }

    /// @notice Transfers to this address return false without moving anything.
    function setFailTransferTo(address who) external {
        failTransferTo = who;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == failTransferTo) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransferFrom) return false;
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}

/// @notice Returns nothing at all, the USDT pattern. The hook's old interface declared
/// `returns (bool)`, so decoding an empty return reverted and these tokens could not
/// be used with it.
contract NoReturnERC20 is BaseToken {
    constructor(string memory n, string memory s) BaseToken(n, s) {}

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        _spendAllowance(from, amount);
        _move(from, to, amount);
    }
}
