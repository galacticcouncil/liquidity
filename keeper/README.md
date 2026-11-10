# BandHook keeper

Checks every listed BandHook pool each `REFRESH_INTERVAL` and calls `recenter(poolId)` on the ones that are due.
The hook decides what is due: each round simulates the call first and sends only when it would go through.

One line per pool per round:

- `result=sent tx=... status=success gas=...`: recentered.
- `result=not-due reason=...`: the hook refused, with its error name (`DriftBelowTrigger`, `GuardTripped`,
  `StaleOracle`, `NotEnabled`, `EmptyBand`).
- `result=unchanged`: the hook would accept, but the oracle price and the pool price are exactly what they were at
  this keeper's last recenter, so the same bands would come back. This happens while the core is empty (the price
  left the band and the hook holds one token), when the hook accepts a recenter on every call. After the owner
  changes the pool's settings or sends tokens to the hook, call `recenter` by hand once: the keeper only notices a
  change in the two prices.
- `result=error message=...`: the node or the network failed; the next round tries again.

## Settings

| Variable | Meaning |
| --- | --- |
| `PRIVKEY` | 0x-prefixed key of the wallet that pays gas. A fresh wallet with a little ETH, never the hook owner: `recenter` is open to anyone, so this key can only spend its own gas. |
| `POOLS` | `hook:poolId` pairs, comma separated. ETH/HOLLAR: `0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0:0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e` |
| `RPC_ROBINHOOD` | Robinhood Chain node; defaults to the public one. |
| `REFRESH_INTERVAL` | Seconds between rounds; defaults to 300. |

A recenter costs about 0.3M gas with an empty core and up to about 0.5M with a full one: at 0.02 gwei, around
0.00001 ETH.

## Run

```sh
npm ci && npm run build
PRIVKEY=0x... POOLS=0xhook:0xpoolId npm start
```

Docker, from this folder:

```sh
docker build -t galacticcouncil/bandhook-keeper:latest .
docker run -d --restart unless-stopped --stop-timeout 130 -e PRIVKEY=0x... -e POOLS=0xhook:0xpoolId galacticcouncil/bandhook-keeper:latest
```

SIGTERM lets the round in progress finish, so a sent recenter is followed to its receipt (up to 120 s); hence the
130 s stop timeout above, where Docker's default is 10 s.

## Tests

```sh
npm test            # settings and round rules, no chain
npm run test:fork   # the keeper against the live hook on an anvil fork; needs anvil and forge
```
