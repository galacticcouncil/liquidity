# Funding the ETH/HOLLAR pool from MetaMask with a Ledger

This is the owner's part of the launch, done in the browser instead of the terminal. The deployer has
already deployed the hook, created the pool and offered the hook to your wallet. You start a small web
page on your own computer, connect MetaMask with your Ledger account, type how much ETH to deposit, and
confirm a few transactions one by one.

You end up owning the hook, with your ETH and HOLLAR placed in the pool at the oracle price. The page
also has every other owner call: take everything out, hand the hook on, change settings.

## What you need first

- The Ledger account the hook was offered to, already added in MetaMask:
  `0x59197B192F4104982196dA9A003C934736f0aC3D`. Nothing else is accepted.
- On Robinhood Chain, in that account:
  - ETH: the amount you deposit, plus 0.002 ETH (0.001 the anchor may send and gets back, 0.001 for gas).
  - HOLLAR: the same dollar value as the ETH you deposit, plus 1 HOLLAR.
  - Example: $10,000 a side at an ETH price of $2,500 means 4 ETH + 0.002, and 10,001 HOLLAR.
- A computer with `git` and Node.js 18 or newer (`node --version` to check; install from nodejs.org).

## Step 1: start the page

```sh
git clone https://github.com/galacticcouncil/liquidity.git
cd liquidity
git fetch origin pull/6/head:eth-hollar-launch
git checkout eth-hollar-launch
cd ui
npm install        # once, about a minute
npm run dev        # starts the page; leave this terminal open
```

Open http://localhost:5173 in the browser where MetaMask is installed. The page runs only on your
computer and reads the chain directly; it never sees your keys. `Ctrl+C` in the terminal stops it, and
`npm run dev` from the `ui` folder starts it again.

Already cloned for the terminal guide (`script/mainnet/FUNDING.md`)? Then only
`git checkout eth-hollar-launch && git pull origin pull/6/head`, and continue from `cd ui`.

## Step 2: get the Ledger and MetaMask ready

- Plug in the Ledger, unlock it, and open the Ethereum app.
- In the Ethereum app's settings, turn on **Blind signing** (older versions call it "Contract data").
  The hook's calls and the anchor's deployment are contract calls the Ledger cannot show in full, so it
  refuses them without this.
- Close Ledger Live: it holds on to the device and MetaMask cannot reach it.
- In MetaMask, pick the Ledger account above.

## Step 3: connect

Top right of the page:

- **Connect wallet**: asks MetaMask to connect. If you have more than one wallet extension, a short
  list opens; pick MetaMask. In MetaMask, choose the Ledger account and confirm.
- **Switch to Robinhood Chain** (pink, only when MetaMask is on another network): asks MetaMask to
  switch. If MetaMask does not know the network yet, it offers to add it; approve that.
- A white **Robinhood Chain** pill with a green dot means you are on the right network.
- Your address in a dark pill means you are connected. Clicking it disconnects the page (MetaMask itself
  stays connected).

Below the top bar are the three views: **Overview**, **Fund**, **Manage**.

## Step 4: look at the Overview first

The page reads the chain every 15 seconds. Before funding, check:

- **Prices**: the pool price, the oracle price with a green `fresh` badge, how many ticks apart they are
  (a tick is 0.01%), and the fee a swap pays now. Before funding the pool is usually some ticks off the
  oracle; the funding puts it back.
- **Ownership**: `Owner` is the deployer, `Offered to` is your address, and `This wallet` says
  "offered the hook: accept it under Fund".
- **Liquidity placed**: the core band, the backstop and the limit all say `empty`.
- **Hook settings**: a green badge `match script/mainnet/eth-hollar.env`. A red badge means the hook was
  set up differently from what was agreed: stop and ask the deployer.

## Step 5: fund

Open **Fund**.

**Deposit** card:

- Type the ETH to deposit. The line under it shows the HOLLAR of equal value at the oracle price; that
  is what the hook takes with your ETH.
- **Max** fills in the most your wallet can deposit, keeping back gas and the anchor's limit.
- Red boxes say what stops the deposit and what to do (see "What the messages mean" below). No
  transaction is offered until they are gone.

**Transactions to send** card: the numbered list of what is left to send, worked out from the chain.
Only the first one has a button. Click it, and the line under the button tells you where it is:

1. "Checking it would go through…": the page runs the transaction against the chain without sending
   it. If it would fail, you see why here, and MetaMask is never asked.
2. "Confirm in MetaMask, then on your Ledger.": MetaMask opens. Check it (below), confirm, then confirm
   on the Ledger.
3. "Sent, waiting for the chain…" with a link to the explorer.
4. The step moves to "Sent from this page" with its link, the page reads the chain again, and the next
   step gets its button.

A first funding is usually these five:

| Step | What it does | In MetaMask you should see |
|---|---|---|
| Accept ownership of the hook | makes your wallet the hook's owner | to the hook `0x5C9c…50c0`, 0 ETH |
| Let the hook spend up to N HOLLAR | lets the hook take your HOLLAR at the deposit; N is 1% above the deposit, in case the price feed updates in between | a spending cap for HOLLAR, the hook `0x5C9c…50c0` as spender; leave the cap as it is |
| Deploy the anchor | your wallet deploys the small helper in `script/PoolAnchor.sol`: only a contract can move a Uniswap v4 price | a contract deployment, 0 ETH |
| Put the pool price back on the oracle | one swap with the oracle price as its limit; free on an empty pool | to the anchor you just deployed, 0.001 ETH that comes back unused (0 ETH when the price must go up) |
| Deposit N ETH and M HOLLAR (pink **Deposit** button) | the hook takes both and places them around the oracle price | to the hook `0x5C9c…50c0`, your ETH amount |

Sometimes the list is different, and that is fine: when the pool price sits below the oracle there is
one more step, "Let the anchor spend up to 1 HOLLAR", before the anchor; when the pool is already on the
oracle there is no anchor at all.

Send the deposit right after the anchor. Between the two, anyone could move the pool's price. If they
move it far, the hook refuses the deposit (you lose only gas) and the list offers the anchor again: send
it, then the deposit. Keep the page open from the anchor's deployment to the deposit: after a reload it
asks to deploy a new anchor, which costs one more confirm and nothing else.

When the deposit lands, the amount field clears and a green box says the hook already holds liquidity.
In **Overview**, the pool is now 0 or 1 tick from the oracle, the fee is 0.08%, and the three
positions show what they hold.

Two more cards on **Fund**:

- **Before you start**: the Ledger checklist from step 2.
- **Anchor limits**: the most the anchor may spend if someone else's liquidity sits between the pool
  price and the oracle (0.001 ETH and 1 HOLLAR). On an empty pool it spends nothing. Raise them only
  if the anchor is refused with `TargetNotReached`.

To add more later, type a new amount on **Fund**: once the hook holds liquidity, only approve and deposit
are needed.

## Manage: every other call

Each button runs the same three stages as on Fund: check, MetaMask and Ledger, wait. A button that would
fail says why without asking MetaMask. Buttons that are hard to undo ask first, in a yellow box: **Yes, send
it** sends, **Cancel** goes back.

**Ownership**

- **Accept ownership**: only shown while the hook is offered to the connected wallet.
- **Hand the hook to** and **Offer the hook**: type the next owner's address (for example governance)
  and offer it the hook. It must accept before it owns the hook; until then you stay the owner. A
  contract as owner must be able to receive plain ETH, or taking everything out fails later.
- **Cancel the open offer**: shown while an offer is open; withdraws it.

**Switches**

- **Switch the pool off / on**: off stops deposits and recentering for this pool. Swaps still trade
  what is placed; to stop that, take everything out.
- **Turn in-swap recenter off / on**: whether the swap that makes a recenter due also does it, paid by
  that trader.

**Recenter**

- The line on top says whether a recenter is due, and if not, why.
- **Recenter**: anyone may call it; it acts only when due, otherwise it is refused with nothing sent.
- **Force recenter**: owner only. Places the band again around the oracle now, adding nothing. Use it
  after changing the settings.
- **Sync fee**: sets the resting fee to the floor. Only needed when a pool was set up after it was
  created; not for this pool.

**Take everything out**

- Shows about how much would come back. **Withdraw** (red, asks first) takes every position out of the
  pool and sends both tokens to the owner in one transaction. The pool is then empty, and its price can
  be moved by anyone until the next deposit, which anchors it again.

**Sweep**

- Sends tokens that sit idle in the hook, never the positions: pick ETH, HOLLAR, or another token sent
  to the hook by mistake (another token always sends its whole balance). An empty amount means all of
  it, an empty "To" means the owner.

**Settings**

- The hook's numbers, filled in with the live values: fee floor and cap in ppm (800 = 0.08%), stale
  limit in seconds, widths in ticks, backstop share in bps. **Save settings** asks first, naming what
  changes. The hook refuses values outside its limits. **Reset to the live values** undoes your typing.
  After saving, **Force recenter** moves the band to the new widths now.

**Price source**

- For replacing a price feed that stopped answering. Type the new source's address, the tick you expect
  it to report (filled in with the current oracle tick) and how many ticks of difference to accept. The
  hook reads the new source and refuses it if it lands outside that.

## What the messages mean

| Message | What to do |
|---|---|
| `No wallet found: install MetaMask` | Install MetaMask in this browser, then reload. |
| `Switch the wallet to Robinhood Chain first (top right).` | Click **Switch to Robinhood Chain**. |
| `This wallet is neither the hook's owner ... nor the wallet it was offered to.` | Pick the Ledger account from "What you need first" in MetaMask. |
| `The hook's settings differ from script/mainnet/eth-hollar.env: ...` | Stop. Ask the deployer before accepting the hook. |
| `The price feed is stale ...` | The ETH/USD feed has not updated for 28 hours. Wait and try later. |
| `Not enough ETH` / `Not enough HOLLAR ... You can deposit at most N` | Lower the amount (or press **Max**), or add tokens to the wallet. |
| `The pool price is N ticks from the oracle, more than the guard` | Only on a pool that already holds liquidity: wait for trading to bring it closer. |
| `Declined in the wallet: nothing was sent.` | You rejected it in MetaMask or on the Ledger. Click again when ready. |
| `... On the Ledger: unlock it, open the Ethereum app, and turn on Blind signing` | Step 2. |
| `GuardTripped: ...` | Someone moved the price between the anchor and the deposit. Send the anchor step again, then the deposit. |
| `TargetNotReached: ...` | Raise **Anchor limits** to 0.01 ETH and 25 HOLLAR, then send the anchor again. |
| `NotOwner: ...` | Wrong account for this call: connect the owner's Ledger account. |
| `It reverted on chain: ...` | Nothing changed, only gas was spent. The list is read again; send again. |
| `Sent, waiting for the chain…` for a long time | It waits for as long as it takes. Open the link; do not send the same step again. |
| `Could not read the chain: ...` | The public node is busy. The page tries again every 15 seconds. |
| Yellow box `Reading from ..., not the live chain` | The page was started for testing against a local copy of the chain. Do not use it with your Ledger; start it again with plain `npm run dev`. |

## Addresses

| What | Address |
|---|---|
| Your wallet | `0x59197B192F4104982196dA9A003C934736f0aC3D` |
| Hook | `0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0` |
| Pool id | `0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e` |
| HOLLAR | `0xD1dc3517732c98502b5c1ba2389AcA9E9016d89a` |
| Explorer | https://robinhoodchain.blockscout.com |
