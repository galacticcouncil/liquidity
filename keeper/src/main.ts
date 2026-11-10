// Entry point: reads the settings, then runs a round over every pool each REFRESH_INTERVAL until stopped.
// SIGTERM or SIGINT lets the round in progress finish, so a sent recenter is always followed to its receipt.
import { setTimeout as sleep } from 'node:timers/promises'
import { createPublicClient, createWalletClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { loadConfig, robinhood } from './config.js'
import { runRound, type Keeper } from './round.js'

const config = loadConfig(process.env)
const transport = http(config.rpcUrl)
const keeper: Keeper = {
  client: createPublicClient({ chain: robinhood, transport }),
  signer: createWalletClient({ chain: robinhood, transport, account: privateKeyToAccount(config.privateKey) }),
  pools: config.pools,
  lastSent: new Map(),
}

const stop = new AbortController()
process.on('SIGTERM', () => stop.abort())
process.on('SIGINT', () => stop.abort())

const started = `keeper ${keeper.signer.account.address} started, ${config.pools.length} pool(s), every ${config.intervalMs / 1000}s`
console.log(`${new Date().toISOString()} ${started}`)
while (!stop.signal.aborted) {
  await runRound(keeper)
  await sleep(config.intervalMs, undefined, { signal: stop.signal }).catch(() => {}) // aborted: the loop ends
}
console.log(`${new Date().toISOString()} keeper stopped`)
