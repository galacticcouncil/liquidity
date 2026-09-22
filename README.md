# Robinhood Chain v4 pools — BandHook launch kit

Uniswap v4 dynamic-fee pools on Robinhood Chain (chain id 4663), market-made by
`BandHook`: hook-owned core band + one-sided limit for the leftover + wide
backstop, oracle-guarded permissionless recentering, divergence-driven dynamic
fee. Pools: **ETH/HOLLAR, HDX/HOLLAR, ETH/HDX** (native ETH).

Design + evidence: garden note `wiki/note-robinhood-pools-proposal`.
Audit + fixes: PR #1 (merged 2026-09-18).

## Layout

- `src/BandHook.sol` — the hook (owner-funded, open to third-party LPs)
- `src/sources/` — `ChainlinkSource` (single feed + invert + decimals), `RatioSource` (two-feed ratio; the ETH/HDX source)
- `script/00–03` — deploy hook (CREATE2 salt-mined to the flag bits), setup pool, fund, hand off ownership
- `test/` — unit tests (ERC20 + native pools, audit regression suites) and fork tests against the live PoolManager

## Prerequisites

Fresh clone: `git clone --recurse-submodules` (or `git submodule update --init
--recursive`) before `forge test`.

Fill `.env` from `.env.example`. Blanks that must exist first:

- bridged HOLLAR + HDX addresses (and confirmed decimals),
- HDX/USD ManagedOracle (wormhole-direct receiver stack, `whm` repo; ETH/HDX
  uses `RatioSource(HDX/USD, Chainlink ETH/USD)` — no HDX/ETH oracle needed),
- owner multisig on Robinhood Chain — **must accept a plain ETH transfer**
  (`withdraw` on the native pools pushes ETH via call and reverts otherwise).

## Run order

Per pool, the initialize → fund sequence must run in **immediate succession**:
an empty pool cannot be arbitraged, so its price freezes at `initialize` and
drifts from market; `fund` refuses against a price outside `guardTicks` of the
oracle. If the pool sat idle after initialization, anchor its price back onto
the oracle first (tiny straddling position, one swap with `sqrtPriceLimitX96`
at the oracle price, withdraw and burn — costs gas only).

```sh
forge test                                   # all green, incl. fork tests (uses the "robinhood" rpc alias)

forge script script/00_DeployBandHook.s.sol --rpc-url robinhood --broadcast   # once
# per pool (three env files):
set -a; source .env.eth-hollar; set +a
forge script script/01_SetupPool.s.sol --rpc-url robinhood --broadcast       # source + configure + initialize at oracle price
forge script script/02_Fund.s.sol --rpc-url robinhood --broadcast            # POOL_ID + FUND_AMOUNT0/1, immediately after 01
# after all pools:
forge script script/03_HandOff.s.sol --rpc-url robinhood --broadcast         # multisig then calls acceptOwnership()
```

Handover verification: after `acceptOwnership`, assert `owner` is the multisig,
`pendingOwner` is zero, and the deploy key holds no role of any kind.

## Operator notes

`fund` and `recenter` refuse rather than misplace capital. What each revert
means and what to do:

| Revert | Meaning | Response |
|---|---|---|
| `StaleOracle` | price source older than `staleAfter` (or unusable) | fix the feed/pipeline; nothing moved. Swaps continue at the floor fee |
| `GuardTripped` | pool price > `guardTicks` from the oracle | wait for arbitrage to align the pool, or anchor (empty pool). Never force capital against an unverified price |
| `EmptyBand` | nothing at all could be placed: the hook holds no tokens for this pool. A full band exit no longer causes it; the held token goes into the one-sided limit | fund the pool; nothing moved |

`fund(id, 0, 0)` is the owner's **forced recenter**: it pulls nothing, skips
the drift trigger, but keeps the freshness and guard checks. Useful after
`setParams` changes band geometry.

`setSource` is the recovery path for a dead feed: owner-only, validates the
replacement against an expected tick, never calls the old source.

## Post-launch monitoring

`recenter(poolId)` is permissionless (~490k gas on a Robinhood fork) and safe to call blindly —
the guards decide. Watchdog principle: **alert on work that was due, not on
quiet inactivity** —

- recenter conditions held for > N minutes with no recenter executed,
- feed `updatedAt` older than its heartbeat + margin,
- idle (unplaced) inventory above X% of position value,
- pool price pinned at `guardTicks` distance from the oracle for hours
  (fee dead-band or manipulation — investigate either way).

**Not audited externally.** Internal audit in PR #1; the hook custodies the LP
capital — cap the pilot size until an external audit lands.
