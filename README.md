# Robinhood Chain v4 pools — BandHook launch kit

Uniswap v4 dynamic-fee pools on Robinhood Chain (chain id 4663), market-made by
`BandHook`: hook-owned core band + one-sided limit for the leftover + wide
backstop, oracle-guarded permissionless recentering, divergence-driven dynamic
fee. Pools: **ETH/HOLLAR, HDX/HOLLAR, ETH/HDX** (native ETH).

Design + evidence: garden note `wiki/note-robinhood-pools-proposal`.
Audit + fixes: PR #1 (merged 2026-09-18).

## Layout

- `src/BandHook.sol` — the hook (owner-funded, open to third-party LPs); one deployment per pool
- `src/sources/` — `ChainlinkSource` (one feed, built from the token it prices and the pool's other token), `RatioSource` (two USD feeds, each named with the token it prices; the ETH/HDX source). Both read the tokens' decimals and work out the orientation themselves
- `script/00`, `01`, `03` — per pool: deploy its hook (CREATE2 salt-mined to the flag bits), set it up (source, expected-tick check, configure, initialize), hand it to the Safe
- `script/SafeFund.s.sol` — writes the Safe batch that anchors the pool price onto the oracle and funds it in one transaction
- `script/PoolAnchor.sol` — the helper the batch calls to move the pool price onto the oracle
- `test/` — unit tests (ERC20 + native pools, audit regression suites) and fork tests against the live PoolManager, including the whole per-pool routine

## Prerequisites

Fresh clone: `git clone --recurse-submodules` (or `git submodule update --init
--recursive`) before `forge test`.

Fill `.env` from `.env.example` (deploy key, final owner), and one settings
file per pool from its example: `.env.eth-hollar`, `.env.hdx-hollar`,
`.env.eth-hdx`. Blanks that must exist first:

- bridged HOLLAR + HDX addresses (and confirmed decimals),
- HDX/USD ManagedOracle (wormhole-direct receiver stack, `whm` repo). ETH/HDX
  uses a `RatioSource` of ETH/USD and HDX/USD, each feed named with the token
  it prices, in any order. No HDX/ETH oracle needed,
- each pool's `EXPECTED_TICK`, from the market at launch (worked examples in
  the files); `01_SetupPool` refuses a source that disagrees with it,
- owner multisig on Robinhood Chain — **must accept a plain ETH transfer**
  (`withdraw` on the native pools pushes ETH via call and reverts otherwise).

## Run order

Per pool: `00`, `01`, then `03` hands the hook to the Safe **before any
funding**, and the Safe accepts. The Safe holds the capital; the deploy key
never does. `SafeFund` then writes one batch for the Safe: approve, anchor,
approve, fund.

Until the first `fund`, and again after a full `withdraw`, the pool holds no
liquidity, and **anyone can move an empty pool's price for free**: a 1-wei
swap with a price limit lands exactly on that limit and costs only gas. The
batch's anchor puts the price back exactly on the oracle and `fund` deposits
in the same transaction, so nobody can move it in between; when nothing moved
it, the anchor does nothing. The anchor is free on an empty pool and capped by
`ANCHOR_MAX0/1` if others' liquidity is in the way.

Sign and execute the batch soon after writing it: it targets the oracle price
at writing time, and if the oracle has since moved further than `guardTicks`,
`fund` refuses and the whole batch is undone. Write it again. Try the import
once on a rehearsal Safe first: the file is written for the Safe app's
Transaction Builder.

```sh
forge test                                   # all green, incl. fork tests (uses the "robinhood" rpc alias)

# once per pool, with that pool's settings loaded (three files, three hooks):
set -a; source .env.eth-hollar; set +a
forge script script/00_DeployBandHook.s.sol --rpc-url robinhood --broadcast  # this pool's hook; put the printed HOOK in .env.eth-hollar
set -a; source .env.eth-hollar; set +a                                        # reload with HOOK set
forge script script/01_SetupPool.s.sol --rpc-url robinhood --broadcast       # source, expected-tick check, configure, initialize at the oracle price
forge script script/03_HandOff.s.sol --rpc-url robinhood --broadcast         # before any funding; then the Safe calls acceptOwnership() on this hook
forge script script/SafeFund.s.sol --rpc-url robinhood --broadcast           # once the Safe owns it: writes broadcast/safe-batches/<pool id>.json
# import that file in the Safe app (Transaction Builder), check each call, sign, execute
```

Handover verification, for every hook, before the Safe funds it: assert `owner` is the Safe,
`pendingOwner` is zero, and the deploy key holds no role of any kind.

## Operator notes

`fund` and `recenter` refuse rather than misplace capital. What each revert
means and what to do:

| Revert | Meaning | Response |
|---|---|---|
| `StaleOracle` | price source older than `staleAfter`, zero, or dated in the future | fix the feed/pipeline; nothing moved. Swaps continue at the floor fee |
| `StaleOracle` | price source failing: it reverts, runs out of its 200k gas, or answers malformed | nothing moved. Swaps continue at the **fee cap**; the pool recovers by itself when the source answers again, or replace it with `setSource` |
| `GuardTripped` | pool price > `guardTicks` from the oracle | funded pool: wait for arbitrage to align it. Empty pool: write and run the SafeFund batch again, its anchor puts it back. Never force capital against an unverified price |
| `EmptyBand` | nothing at all could be placed: the hook holds no tokens for this pool. A full band exit no longer causes it; the held token goes into the one-sided limit | fund the pool; nothing moved |

`fund(id, 0, 0)` is the owner's **forced recenter**: it pulls nothing, skips
the drift trigger, but keeps the freshness and guard checks. Useful after
`setParams` changes band geometry.

`sweep(currency, to, amount)` recovers anything the hook holds: ETH
(`currency` 0x0) or any token, including one sent by mistake. `to` of 0 means
the owner, `amount` of 0 means the whole balance. It moves only what sits in
the hook itself, never the positions, so for a pool's own token it takes only
idle amounts such as a donation.

`setSource` is the recovery path for a dead feed: owner-only, validates the
replacement against an expected tick, never calls the old source.

## In-swap recenter (per pool, off by default)

A pool with `autoRecenter` on is also recentered at the end of the swap that
makes it due (the hook's `afterSwap`), so no keeper is needed in the usual
case. The trader whose swap triggers it pays the extra gas: about 390–420k
measured through the Universal Router on a fork of this chain (ETH/HOLLAR),
up to about 560k in the dearest natural case measured (a second recenter on
an HDX pool); roughly $0.10–0.13 at a typical base fee. Every other swap pays
about 12k for the checks.

- **It never fails a swap.** It is skipped whenever a gate says no: the same
  gates as `recenter()`, plus a non-empty core, no currency part-way through
  payment in the PoolManager, and at least 900k gas left (600k for the
  attempt, 300k kept for the rest of the trader's transaction). An attempt
  that does run is a call the hook makes to itself: if anything inside fails,
  all of it is undone and the hook emits `RecenterSkipped(poolId, reason)`
  (the error's first four bytes, or zero when nothing came back, usually
  because it ran out of gas).
- **An empty core is the keeper's job.** After a full band exit the recenter
  leaves no core and the limit holding everything; swaps then skip, and
  `recenter()`, which needs no trigger in that state, places it again.
- **What it guarantees, and the one gap:** the attempt never touches the last
  300k, so a route with a little under 300k gas of work after this pool (about
  290k) always goes through. A longer route whose gas was estimated before the recenter became
  due can run out when the hook sees just enough gas to try: the attempt costs
  up to ~555k (~600k with tokens donated to the hook), so the gap starts at
  ~315–345k of work after this pool. 8 to 9 of 1,512 real v4 swaps on this
  chain had that shape.
- **How often it fires:** only swaps sent with that much gas to spare can pay
  for it: about a quarter of real v4 swaps here, mostly bots and aggregators,
  and about 5% of wallet trades through the Universal Router.
- **Switch:** `setAutoRecenter(poolId, on)`, owner only. `setParams` never
  changes it. `01_SetupPool` reads `AUTO_RECENTER` (default `false`).
- **Fallback:** the manual `recenter()` is unchanged. Keep a keeper that calls
  it when due; as a backup to the in-swap path, a one-hour delay is enough.
- **Address:** the hook carries `afterInitialize | beforeSwap | afterSwap`
  (`0x10C0`); `00_DeployBandHook` mines for it and the constructor checks it.

## Post-launch monitoring

`recenter(poolId)` is permissionless (~490k gas on a Robinhood fork) and safe to call blindly —
the guards decide. Watchdog principle: **alert on work that was due, not on
quiet inactivity** —

- recenter conditions held for > N minutes with no recenter executed,
- feed `updatedAt` older than its heartbeat + margin,
- idle (unplaced) inventory above X% of position value,
- pool price pinned at `guardTicks` distance from the oracle for hours
  (fee dead-band or manipulation — investigate either way),
- any `RecenterSkipped`: one is noise; repeats mean the in-swap recenter cannot
  complete and every due swap pays for a failed attempt — switch that pool's
  `autoRecenter` off and investigate.

**Not audited externally.** Internal audit in PR #1; the hook custodies the LP
capital — cap the pilot size until an external audit lands.
