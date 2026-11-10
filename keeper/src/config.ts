// The keeper's settings, read from the environment once at start, and the chain it runs on.
// Env names follow the team's other agents: PRIVKEY, RPC_ROBINHOOD, REFRESH_INTERVAL; POOLS lists hook:poolId pairs.
import { defineChain, isAddress, isHex, type Address, type Hex } from 'viem'

export const robinhood = defineChain({
  id: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.mainnet.chain.robinhood.com'] } },
})

export type PoolRef = { hook: Address; poolId: Hex }

export type Config = {
  privateKey: Hex
  rpcUrl: string
  pools: PoolRef[]
  intervalMs: number
}

const DEFAULT_INTERVAL_S = 300
const MAX_INTERVAL_S = 86_400 // a longer wait overflows Node's timer, which then fires at once

export function loadConfig(env: Record<string, string | undefined>): Config {
  const privateKey = env.PRIVKEY?.trim()
  if (!privateKey || !isHex(privateKey) || privateKey.length !== 66) {
    throw new Error('PRIVKEY must be a 0x-prefixed 32-byte hex key')
  }
  const interval = env.REFRESH_INTERVAL?.trim() ? Number(env.REFRESH_INTERVAL) : DEFAULT_INTERVAL_S
  if (!Number.isInteger(interval) || interval < 1 || interval > MAX_INTERVAL_S) {
    throw new Error(`REFRESH_INTERVAL must be a whole number of seconds, from 1 to ${MAX_INTERVAL_S}`)
  }
  return {
    privateKey,
    rpcUrl: env.RPC_ROBINHOOD?.trim() || robinhood.rpcUrls.default.http[0],
    pools: parsePools(env.POOLS ?? ''),
    intervalMs: interval * 1000,
  }
}

/** "0xhook:0xpoolId,0xhook:0xpoolId" into a list; refuses an empty list or a malformed entry. */
function parsePools(raw: string): PoolRef[] {
  const entries = raw.split(',').map((e) => e.trim()).filter(Boolean)
  if (entries.length === 0) throw new Error('POOLS must list at least one hook:poolId pair')
  return entries.map((entry) => {
    const [hook, poolId, extra] = entry.split(':')
    if (extra !== undefined || !hook || !isAddress(hook) || !poolId || !isHex(poolId) || poolId.length !== 66) {
      throw new Error(`POOLS entry "${entry}" is not hook:poolId (a 20-byte address and a 32-byte id)`)
    }
    return { hook, poolId }
  })
}
