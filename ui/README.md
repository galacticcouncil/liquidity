# BandHook console

A page in the browser for the hook's owner: fund the pool from MetaMask, also with a Ledger behind it,
and make every other BandHook call. It does what `script/fund.sh` does, for a wallet whose key cannot be
put in `.env`.

## Run it

```sh
cd ui
npm install
npm run dev        # then open http://localhost:5173
```

It reads Robinhood Chain from its public RPC. To read a local fork instead, put
`VITE_RPC_URL=http://127.0.0.1:8545` in `ui/.env.local`.

## Fund the pool with a Ledger

Step by step for the owner, every button explained: `fund_ui.md`.

1. In MetaMask, pick the Ledger account the hook was offered to. Close Ledger Live.
2. On the Ledger, open the Ethereum app and turn on Blind signing in its settings.
3. Connect wallet (top right), switch to Robinhood Chain if asked, open Fund.
4. Enter the ETH to deposit. The console adds HOLLAR of the same value at the oracle price and lists
   the transactions still to send. Send the first; when it lands the list is worked out again.

A first funding is usually five transactions, each one confirm in MetaMask and one on the Ledger:

- accept ownership of the hook,
- let the hook take the HOLLAR (1% extra, in case the price feed updates before the deposit),
- deploy the anchor, the helper in `script/PoolAnchor.sol`: only a contract can swap on Uniswap v4,
- anchor: move the empty pool's price back onto the oracle (free on an empty pool),
- deposit.

Once the hook holds liquidity, the same page adds more: no anchor is needed then, only approve and
deposit. Every transaction is dry-run against the chain first, so a refusal shows in plain words before the
Ledger asks anything. Funding refuses while the feed is stale or the wallet holds too little, and,
before the hook is accepted, while its settings differ from `script/mainnet/eth-hollar.env`.

## Why several transactions, not one

`fund.sh` sends accept, anchor and deposit as one EIP-7702 transaction, so nobody can move the price
between the anchor and the deposit. MetaMask does not let a page ask for that kind of transaction, and
not from a Ledger. So the console sends them one by one, with the anchor right before the deposit:

- someone moves the price further than the guard (200 ticks) in between: the hook refuses the deposit,
  only gas is lost, and the console offers the anchor again;
- someone moves it up to about 111 ticks: the deposit is placed around the oracle anyway, and the fee
  (up to its 1% cap) costs more than trading back pays;
- someone moves it 112 to 200 ticks: trading back to about 1% from the oracle pays a little. Only the
  slice of the band in that stretch trades: by a rough estimate a few hundredths of a percent of the
  deposit at most (about $5 on $20,000), the same exposure every recenter has. fund.sh's single transaction has none of it.

## Manage

Hand the hook on (for example to governance) or cancel an offer, accept an offer, switch the pool or its
in-swap recenter on and off, recenter, force a recenter, sync the fee, take everything out, sweep idle
tokens, change the settings, replace the price source.

## Checks

```sh
npm run typecheck
npm test               # unit tests: maths, pool id, the funding plan and its refusals
npm run test:fork      # the whole funding run on a local anvil fork of mainnet (needs anvil + forge)
```

`test:fork` drives the same plan and send code as the page, with anvil signing as the owner, including an
attacker who moves the price between the anchor and the deposit.

## Layout

- `src/config.ts`: the chain, and one entry per pool with the settings agreed for it.
- `src/lib/poolState.ts`: reads the hook, the pool, the oracle and the wallet.
- `src/lib/fundPlan.ts`, `src/lib/checks.ts`: the transactions still to send, and what stands in the way.
- `src/lib/send.ts`, `src/lib/errors.ts`: dry run, send, receipt; refusals in plain words.
- `src/components/`: the three views (Overview, Fund, Manage).
- `src/anchorBytecode.ts`: `PoolAnchor`'s creation code; `test:fork` checks it matches `forge inspect`.

A new pool is one more entry in `POOLS` in `src/config.ts`, once its hook is deployed.
