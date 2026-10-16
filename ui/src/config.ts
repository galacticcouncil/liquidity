// The chain, the contracts and the pools this console works with: one entry per deployed hook.
// `expected` holds the settings agreed in the pool's settings file, so the console flags a difference.
import { defineChain, type Address } from 'viem'

export const robinhood = defineChain({
  id: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.mainnet.chain.robinhood.com'] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://robinhoodchain.blockscout.com' } },
})

// Reads go here; set VITE_RPC_URL in ui/.env.local to point the console at a local fork.
export const RPC_URL: string = import.meta.env?.VITE_RPC_URL || robinhood.rpcUrls.default.http[0]
export const EXPLORER = robinhood.blockExplorers.default.url

export const MANAGER: Address = '0x8366a39CC670B4001A1121B8F6A443A643e40951'
/** ETH kept back for gas when working out the most the wallet can deposit, as fund.sh does. */
export const GAS_RESERVE = 10n ** 15n

export type Token = { address: Address; symbol: string; decimals: number }

/** The hook's PoolConfig, field for field. */
export type HookConfig = {
  source: Address
  feeFloor: number
  feeCap: number
  feeSlopePpm: number
  staleAfter: number
  halfBandTicks: number
  backstopHalfTicks: number
  backstopBps: number
  triggerTicks: number
  guardTicks: number
  enabled: boolean
  autoRecenter: boolean
}

export type Pool = {
  name: string
  hook: Address
  token0: Token // address 0 is native ETH
  token1: Token
  tickSpacing: number
  settingsFile: string
  expected: HookConfig
  anchorMax0: bigint // the most the anchor may spend to put a moved price back
  anchorMax1: bigint
}

export const POOLS: Pool[] = [
  {
    name: 'ETH / HOLLAR',
    hook: '0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0',
    token0: { address: '0x0000000000000000000000000000000000000000', symbol: 'ETH', decimals: 18 },
    token1: { address: '0xD1dc3517732c98502b5c1ba2389AcA9E9016d89a', symbol: 'HOLLAR', decimals: 18 },
    tickSpacing: 10,
    settingsFile: 'script/mainnet/eth-hollar.env',
    expected: {
      source: '0x321b83Dfb3ae11e4B8d9A10F83551EC762B5e357',
      feeFloor: 800,
      feeCap: 10_000,
      feeSlopePpm: 1_000_000,
      staleAfter: 100_800,
      halfBandTicks: 700,
      backstopHalfTicks: 11_000,
      backstopBps: 3500,
      triggerTicks: 350,
      guardTicks: 200,
      enabled: true,
      autoRecenter: true,
    },
    anchorMax0: 10n ** 15n, // 0.001 ETH
    anchorMax1: 10n ** 18n, // 1 HOLLAR
  },
]
