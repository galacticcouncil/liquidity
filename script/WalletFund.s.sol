// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Funds one pool from the owner's plain wallet in one EIP-7702 transaction: the wallet borrows
// Simple7702Account's code and runs accept, approve, anchor, approve, fund as one batch, so nobody can
// move the price between the anchor and the fund. Driven by script/fund.sh:
//
//   run      the check: every refusal below, then a dry run of that transaction against the live chain
//   prepare  the same with the anchor fund.sh has just deployed; writes the batch's calldata
//   verify   after the batch: the wallet owns the hook, the pool sits on the oracle, the wallet is plain
//
// Nothing here sends a transaction: the dry run pretends to be the wallet, so --broadcast sends nothing.
// env: the pool's settings file, PRIVATE_KEY (the owner's wallet), FUND_AMOUNT0 (ETH to deposit, wei)

import {console2} from "forge-std/Script.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BandHook} from "../src/BandHook.sol";
import {ChainlinkSource} from "../src/sources/ChainlinkSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {SafeFund} from "./SafeFund.s.sol";
import {PoolAnchor} from "./PoolAnchor.sol";

/// @notice The batch entry point of Simple7702Account (eth-infinitism, ERC-4337 v0.8). It runs only
/// for the account itself or the EntryPoint.
interface ISimple7702 {
    function executeBatch(SafeFund.Call[] calldata calls) external;
}

contract WalletFund is SafeFund {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    /// @dev keccak256 of Simple7702Account's runtime code, as deployed on Robinhood Chain.
    bytes32 internal constant SIMPLE7702_CODEHASH = 0x82c1e6c0f83d22eef579344e8eff26baf24db4dabe5408d681b00d0512bc3ec4;
    /// @dev ETH kept back for the anchor deployment, the batch and the clearing transaction.
    uint256 internal constant GAS_RESERVE = 0.001 ether;

    /// @notice What the check needs, from the pool's settings file.
    struct Settings {
        uint256 chainId; // CHAIN_ID
        address owner; // NEW_OWNER: the wallet the hook was offered to
        BandHook hook;
        PoolKey key;
        address feed; // FEED, the one feed the pool's source reads
        address feedPrices; // FEED_PRICES, the token that feed prices
        BandHook.PoolConfig cfg; // the hook settings agreed in the file; the source is checked apart
        address simple7702; // the code the wallet borrows for the batch
        uint256 amount0; // ETH to deposit, wei; token1 of equal value is worked out at the oracle price
        uint256 anchorMax0;
        uint256 anchorMax1;
    }

    function run() external override {
        check(_settings(), vm.envUint("PRIVATE_KEY"));
    }

    /// @notice The check, then the dry run with an anchor of its own. Returns the batch.
    function check(Settings memory s, uint256 pk) public returns (Call[] memory batch) {
        vm.startPrank(vm.addr(pk), vm.addr(pk));
        PoolAnchor anchor = new PoolAnchor(MANAGER);
        vm.stopPrank();
        batch = _dryRun(s, pk, anchor);
    }

    /// @notice For fund.sh send, once it has deployed the anchor from the wallet: the check and the dry
    /// run with that anchor, then the batch's calldata written to `path` for `cast send --auth`.
    function prepare(PoolAnchor anchor, string calldata path) external {
        Call[] memory batch = _dryRun(_settings(), vm.envUint("PRIVATE_KEY"), anchor);
        vm.writeFile(path, vm.toString(abi.encodeCall(ISimple7702.executeBatch, (batch))));
    }

    /// @notice After fund.sh send: the wallet owns the hook and holds no borrowed code, the pool sits on
    /// the oracle, and the core band and the backstop are placed.
    function verify() external view {
        verify(_settings());
    }

    function verify(Settings memory s) public view {
        PoolId id = s.key.toId();
        require(s.hook.owner() == s.owner && s.hook.pendingOwner() == address(0), "the wallet does not own the hook");
        require(s.owner.code.length == 0, "the wallet still has borrowed code: clear it");
        (IPriceSource source,,,, uint32 staleAfter,,,,,,,) = s.hook.config(id);
        (, int24 oracleTick) = _oracle(source, staleAfter);
        (, int24 poolTick,,) = MANAGER.getSlot0(id);
        require(_absDiff(poolTick, oracleTick) <= 1, "the pool is not on the oracle");
        (,,, uint128 core) = s.hook.core(id);
        (,,, uint128 backstop) = s.hook.backstop(id);
        require(core > 0 && backstop > 0, "the core band or the backstop is not placed");
        console2.log("funded: the wallet owns the hook, the pool is on the oracle at tick", int256(poolTick));
    }

    /// @dev Every refusal, then the batch run as the wallet with Simple7702Account's code. Any failing
    /// call reverts the whole run.
    function _dryRun(Settings memory s, uint256 pk, PoolAnchor anchor) internal returns (Call[] memory batch) {
        address wallet = vm.addr(pk);
        _checkWallet(s, wallet);
        BandHook.PoolConfig memory c = _checkHook(s, wallet);
        (uint160 target, uint256 px) = _oraclePrice(c);
        uint256 amount1 = s.amount0 * px / 1e18;
        _checkBalances(s, wallet, amount1, px);

        batch = _batch(s, wallet, anchor, target, amount1);
        vm.startPrank(wallet, wallet);
        vm.signAndAttachDelegation(s.simple7702, pk);
        ISimple7702(wallet).executeBatch(batch);
        vm.stopPrank();

        // a call to an account whose borrowed code is missing succeeds and does nothing
        (,,, uint128 core) = s.hook.core(s.key.toId());
        require(s.hook.owner() == wallet && core > 0, "dry run placed nothing: check SIMPLE7702");
        console2.log("ready: deposits ETH (wei)", s.amount0);
        console2.log("and token1 (raw)", amount1);
    }

    /// @dev The right chain, the right key, a wallet with no code of its own, the right delegate.
    function _checkWallet(Settings memory s, address wallet) internal view {
        require(
            block.chainid == s.chainId,
            string.concat("RPC is chain ", vm.toString(block.chainid), ", settings are for ", vm.toString(s.chainId))
        );
        require(wallet == s.owner, "the key in .env is not NEW_OWNER");
        require(
            wallet.code.length == 0,
            string.concat(
                "the wallet already has code (an EIP-7702 delegation); clear it with: cast send ",
                vm.toString(wallet),
                " --auth 0x0000000000000000000000000000000000000000 --private-key <key> --rpc-url <rpc>"
            )
        );
        require(s.simple7702.codehash == SIMPLE7702_CODEHASH, "SIMPLE7702 is not Simple7702Account");
        require(s.key.currency0.isAddressZero(), "this script funds pools whose token0 is native ETH");
    }

    /// @dev The hook is a BandHook on this PoolManager, offered to or owned by the wallet, set up as the
    /// file says, with a live pool at the floor fee. Returns its settings.
    function _checkHook(Settings memory s, address wallet) internal view returns (BandHook.PoolConfig memory c) {
        require(
            address(s.hook.manager()) == address(MANAGER) && uint160(address(s.hook)) & 0x3FFF == 0x10C0,
            "HOOK is not a BandHook on this PoolManager"
        );
        require(s.hook.pendingOwner() == wallet || s.hook.owner() == wallet, "the hook is not offered to this wallet");
        PoolId id = s.key.toId();
        // the getter returns the struct's fields in order, which decodes as the struct
        (, bytes memory raw) = address(s.hook).staticcall(abi.encodeCall(s.hook.config, (id)));
        c = abi.decode(raw, (BandHook.PoolConfig));
        _checkConfig(c, s.cfg);
        ChainlinkSource source = ChainlinkSource(address(c.source));
        require(
            address(source.feed()) == s.feed && source.invert() == (s.feedPrices == Currency.unwrap(s.key.currency1)),
            "the pool's price source does not read FEED for FEED_PRICES"
        );
        (uint160 sqrtP,,, uint24 lpFee) = MANAGER.getSlot0(id);
        require(sqrtP != 0, "the pool is not initialized: the deployer runs 01 first");
        require(lpFee == c.feeFloor, "the pool's fee is not at the floor: the deployer runs 01 again");
        (,,, uint128 core) = s.hook.core(id);
        (,,, uint128 backstop) = s.hook.backstop(id);
        require(core == 0 && backstop == 0, "the pool is already funded: fund.sh deposits once");
    }

    function _checkConfig(BandHook.PoolConfig memory c, BandHook.PoolConfig memory want) internal pure {
        _same("FEE_FLOOR_PPM", c.feeFloor, want.feeFloor);
        _same("FEE_CAP_PPM", c.feeCap, want.feeCap);
        _same("FEE_SLOPE_PPM", c.feeSlopePpm, want.feeSlopePpm);
        _same("STALE_AFTER_S", c.staleAfter, want.staleAfter);
        _same("HALF_BAND_TICKS", c.halfBandTicks, want.halfBandTicks);
        _same("BACKSTOP_HALF_TICKS", c.backstopHalfTicks, want.backstopHalfTicks);
        _same("BACKSTOP_BPS", c.backstopBps, want.backstopBps);
        _same("TRIGGER_TICKS", c.triggerTicks, want.triggerTicks);
        _same("GUARD_TICKS", c.guardTicks, want.guardTicks);
        require(c.enabled, "the pool is not enabled on the hook");
        require(c.autoRecenter == want.autoRecenter, "the hook's setting differs from the file: AUTO_RECENTER");
    }

    function _same(string memory name, uint256 actual, uint256 wanted) internal pure {
        require(actual == wanted, string.concat("the hook's setting differs from the file: ", name));
    }

    function _same(string memory name, int256 actual, int256 wanted) internal pure {
        require(actual == wanted, string.concat("the hook's setting differs from the file: ", name));
    }

    /// @dev The oracle price as the anchor's target, and as raw token1 per raw token0 (1e18).
    function _oraclePrice(BandHook.PoolConfig memory c) internal view returns (uint160 target, uint256 px) {
        (target,) = _oracle(c.source, c.staleAfter);
        (px,) = c.source.priceX18();
    }

    /// @dev ETH for the deposit, the anchor's cap and gas; token1 for the deposit and the anchor's cap.
    function _checkBalances(Settings memory s, address wallet, uint256 amount1, uint256 px) internal view {
        require(s.amount0 > 0, "FUND_ETH is zero");
        uint256 need0 = s.amount0 + s.anchorMax0 + GAS_RESERVE;
        require(
            wallet.balance >= need0,
            string.concat("the wallet holds too little ETH: needs ", vm.toString(need0), " wei")
        );
        uint256 have1 = IERC20Minimal(Currency.unwrap(s.key.currency1)).balanceOf(wallet);
        if (have1 < amount1 + s.anchorMax1) {
            uint256 most = have1 > s.anchorMax1 ? (have1 - s.anchorMax1) * 1e18 / px : 0;
            revert(
                string.concat("the wallet holds too little token1: FUND_ETH can be at most ", vm.toString(most), " wei")
            );
        }
    }

    /// @dev SafeFund's calls, with acceptOwnership first while the hook is only offered to the wallet.
    function _batch(Settings memory s, address wallet, PoolAnchor anchor, uint160 target, uint256 amount1)
        internal
        view
        returns (Call[] memory batch)
    {
        Call[] memory fund = calls(s.hook, s.key, anchor, target, s.anchorMax0, s.anchorMax1, s.amount0, amount1);
        if (s.hook.pendingOwner() != wallet) return fund;
        batch = new Call[](fund.length + 1);
        batch[0] = Call(address(s.hook), 0, abi.encodeCall(BandHook.acceptOwnership, ()));
        for (uint256 i; i < fund.length; i++) {
            batch[i + 1] = fund[i];
        }
    }

    function _settings() internal view returns (Settings memory s) {
        s.chainId = vm.envUint("CHAIN_ID");
        s.owner = vm.envAddress("NEW_OWNER");
        s.hook = BandHook(payable(vm.envAddress("HOOK")));
        s.key = _poolKey(address(s.hook));
        s.feed = vm.envAddress("FEED");
        s.feedPrices = vm.envAddress("FEED_PRICES");
        s.cfg = _configFromEnv(IPriceSource(address(0)));
        s.simple7702 = vm.envAddress("SIMPLE7702");
        s.amount0 = vm.envUint("FUND_AMOUNT0");
        s.anchorMax0 = vm.envUint("ANCHOR_MAX0");
        s.anchorMax1 = vm.envUint("ANCHOR_MAX1");
    }
}
