# Funding the ETH/HOLLAR pool from your wallet

This is the owner's part of the launch, step by step. The deployer has already deployed the hook,
created the pool at the oracle price and offered the hook to your wallet. You add your key, set how
much to deposit, run one check, then one send. About 15 minutes, most of it installing tools.

You end up owning the hook, with your ETH and HOLLAR placed in the pool at the oracle price.

Wallet on a Ledger? Its key never leaves the device, so step 3 cannot work. Use the console in `ui/`
instead, from MetaMask with the Ledger: `ui/fund_ui.md`.

## What you need first

- The wallet the hook was offered to: `NEW_OWNER` in `script/mainnet/eth-hollar.env`
  (`0x59197B192F4104982196dA9A003C934736f0aC3D`). Nothing else will be accepted.
- On Robinhood Chain, in that wallet:
  - ETH: the amount you deposit, plus 0.002 ETH (0.001 the anchor may need and gets back, 0.001 for gas).
  - HOLLAR: the same dollar value as the ETH you deposit, plus 1 HOLLAR.
  - Example: $10,000 a side at an ETH price of $2,513 means 3.98 ETH + 0.002, and 10,001 HOLLAR.
- A Mac or Linux terminal with `git` and `curl`.

## Step 1: install Foundry

```sh
curl -L https://foundry.paradigm.xyz | bash   # installs foundryup; open a new terminal after it
foundryup                                     # installs forge and cast
cast --version                                # must say 1.0.0 or newer
```

Foundry is the toolkit the scripts use: `forge` runs the checks, `cast` sends the transactions.
Version 1.0 or newer is needed for the one-transaction funding (EIP-7702).

## Step 2: get the code

```sh
git clone --recurse-submodules https://github.com/galacticcouncil/liquidity.git
cd liquidity
git fetch origin pull/6/head:eth-hollar-launch
git checkout eth-hollar-launch
forge build                                   # about a minute the first time
```

This downloads the repository with its libraries and switches to the launch version (pull request
6). Once that pull request is merged, `main` has the same files and the fetch and checkout lines can
be skipped. `forge build` compiles everything once so the next steps start fast. Run every later
command from this `liquidity` folder.

## Step 3: put your key in `.env`

```sh
nano .env
```

Type one line, with your wallet's private key (the 64 hex characters, with `0x` in front):

```
PRIVATE_KEY=0x...
```

Save with `Ctrl+O`, `Enter`, then quit with `Ctrl+X`.

- What it does: the scripts sign with this key. `.env` is ignored by git, so it is never committed.
- Use a file, not a command line: a key typed after `echo` stays in your shell history.
- In MetaMask: Account details, then Show private key.
- Keep the key afterwards in your password manager: as owner of the hook you need it later for
  `withdraw` and for handing the hook on. Delete `.env` when you are done with this machine.

## Step 4: set how much to deposit

Open `script/mainnet/eth-hollar.env` and find the line `FUND_ETH=`. Put the ETH amount after it, in
ETH (not wei):

```
FUND_ETH=3.98
```

Suggested value: your dollar amount per side divided by the ETH price. For $10,000 a side:

```sh
cast call 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9 "latestAnswer()(int256)" --rpc-url robinhood
# prints e.g. 251351280432, which is $2,513.51 (8 decimals)
# FUND_ETH = 10000 / 2513.51 = 3.98
```

- What it does: you deposit `FUND_ETH` of ETH, and the script adds HOLLAR of the same value at the
  oracle price. Equal value on both sides is what the pool's bands take, so almost nothing sits idle.
- Change nothing else in this file. The check compares every other value with what the deployer set
  up on chain and stops on any difference.
- `ANCHOR_MAX0` and `ANCHOR_MAX1` are the most the anchor may spend if someone left liquidity in its
  way (step 5). Leave them unless the check tells you otherwise.

## Step 5: check (sends nothing)

```sh
script/fund.sh check
```

It reads the chain and refuses, with the reason, if anything is off: the network, your key, the
hook and its settings, the price feed and its age, your balances, or a wallet that already carries
code of its own. Then it does a dry run of your whole funding transaction against the live chain and
checks that it would end with you owning the hook and the liquidity placed. Nothing is sent.

You should see:

```
== check: wallet 0x59197B192F4104982196dA9A003C934736f0aC3D, hook 0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0, 3.98 ETH
  ready: deposits ETH (wei) 3980000000000000000
  and token1 (raw) 10003...
check passed: nothing was sent. Next: script/fund.sh send
```

The amounts are raw units with 18 decimals: `3980000000000000000` is 3.98 ETH, and `10003...` with 22
digits is about 10,003 HOLLAR. If it stops instead, see "If something stops" below. Run it again
until it passes; it costs nothing.

## Step 6: send

```sh
script/fund.sh send
```

What happens, in order:

1. The same check again, so nothing is spent if anything changed since step 5.
2. Your wallet deploys a small helper, the anchor. It can move the pool price back onto the oracle
   with one swap, which a wallet cannot do by itself. One transaction.
3. Your one funding transaction. Your wallet borrows the code of Simple7702Account (a standard,
   audited smart-account contract already on Robinhood Chain) for this one transaction, which runs
   five calls in a row, all or nothing:
   - accept ownership of the hook,
   - approve the anchor for up to `ANCHOR_MAX1` HOLLAR,
   - anchor: if someone moved the empty pool's price, put it back on the oracle (free on an empty
     pool; unused ETH comes back),
   - approve the hook for your HOLLAR deposit,
   - fund: the hook takes your ETH and HOLLAR and places them around the oracle price.
   Nobody can move the price between the anchor and the deposit, because they are one transaction.
4. A second small transaction removes the borrowed code. Your wallet is a plain wallet again.
5. A final check: you own the hook, the pool sits on the oracle, the liquidity is placed.

You should see at the end:

```
== result
  funded: the wallet owns the hook, the pool is on the oracle at tick 78...
```

Gas for all three transactions is under 0.0001 ETH.

## If something stops

Every stop happens before your money moves, or undoes itself completely. Read the line it prints:

| Message | What to do |
|---|---|
| `put the wallet's key in .env` | Step 3. |
| `FUND_ETH is empty` or `FUND_ETH is zero` | Step 4. |
| `the key in .env is not NEW_OWNER` | The key is for another wallet. Use the key of the `NEW_OWNER` wallet. |
| `the wallet already has code (an EIP-7702 delegation); clear it with: cast send ...` | Your wallet carries a smart-account upgrade (for example MetaMask's). Run the printed command with your key, then check again. Decline MetaMask's smart-account offer until funding is done. |
| `the wallet holds too little ETH: needs N wei` | Add ETH, or lower `FUND_ETH`. N is in wei: divide by 10^18. |
| `the wallet holds too little token1: FUND_ETH can be at most N wei` | Not enough HOLLAR for that much ETH. Lower `FUND_ETH` to at most N / 10^18, or add HOLLAR. |
| `oracle stale` | The ETH/USD feed has not updated for 28 hours. Wait and try again later. |
| `the pool is already funded` | Funding already went through. Look up the hook on the explorer (below). |
| `TargetNotReached` | Someone left liquidity between the moved price and the oracle, and crossing it costs more than the anchor limits. Raise `ANCHOR_MAX0` to `10000000000000000` (0.01 ETH) and `ANCHOR_MAX1` to `25000000000000000000` (25 HOLLAR), then check again. Crossing it is at a better price than the oracle's, so it costs you at most the 1% fee on that amount. |
| `the hook is not offered to this wallet`, `the hook's setting differs from the file`, `price source does not read FEED`, `pool is not initialized`, `fee is not at the floor`, `HOOK is not a BandHook`, `SIMPLE7702 is not Simple7702Account` | The settings file was changed, or the deployer's setup differs. Undo your edits other than `FUND_ETH` (`git checkout script/mainnet/eth-hollar.env`, then step 4 again) and ask the deployer. |
| `cast send did not confirm the batch` | The node did not answer in time. Run `script/fund.sh check` before anything else: it tells you if the funding already went through or if the borrowed code needs clearing. |
| `429`, `could not instantiate forked environment` | The public RPC is busy. Run the same command again. |

## After funding

- See it on the explorer: `https://robinhoodchain.blockscout.com/address/0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0`.
- Take everything back at any time, both tokens, in one transaction (emergency or end of pilot):

  ```sh
  set -a; source .env; set +a
  cast send 0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0 "withdraw(bytes32)" \
    0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e \
    --private-key "$PRIVATE_KEY" --rpc-url robinhood
  ```

- Recentering: when the oracle price drifts far enough from the band, a swap sent with enough spare
  gas also moves the band back around the oracle price. Anyone can also call `recenter(poolId)` on
  the hook at any time; it only acts when a recenter is due.
- Handing the hook on later (for example to governance): `script/03_HandOff.s.sol` with `NEW_OWNER`
  set to the new owner, then the new owner accepts.

## Addresses

| What | Address |
|---|---|
| Your wallet (`NEW_OWNER`) | `0x59197B192F4104982196dA9A003C934736f0aC3D` |
| Hook (`HOOK`) | `0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0` |
| Pool id | `0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e` |
| Price source (reads Chainlink ETH/USD) | `0x321b83Dfb3ae11e4B8d9A10F83551EC762B5e357` |
| HOLLAR | `0xD1dc3517732c98502b5c1ba2389AcA9E9016d89a` |
| Chainlink ETH/USD | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Simple7702Account | `0x4Cd241E8d1510e30b2076397afc7508Ae59C66c9` |
