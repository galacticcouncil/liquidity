// For tests: a made-up pool state shaped like the live ETH/HOLLAR launch, which each test changes in one place.
// The deployer owns the hook and has offered it to the owner; the pool is empty, 200 ticks above the oracle.
import type { Address } from 'viem'
import { POOLS } from '../config'
import { sqrtPriceX96FromPriceX18 } from './math'
import type { PoolState, WalletState } from './poolState'

export const pool = POOLS[0]
export const caps = { max0: pool.anchorMax0, max1: pool.anchorMax1 }
export const OWNER: Address = '0x00000000000000000000000000000000000000a1'
export const DEPLOYER: Address = '0x00000000000000000000000000000000000000d1'
export const ANCHOR: Address = '0x00000000000000000000000000000000000000c1'
export const PRICE = 2_500n * 10n ** 18n // the oracle: 1 ETH = 2,500 HOLLAR
export const ETH = 10n ** 18n
export const FUNDED_CORE = { lower: 77540, upper: 78950, center: 78244, liquidity: 1n }
const empty = { lower: 0, upper: 0, center: 0, liquidity: 0n }

export function launch(over: Partial<PoolState> = {}, wallet: Partial<WalletState> = {}): PoolState {
  return {
    id: '0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e',
    owner: DEPLOYER,
    pendingOwner: OWNER,
    cfg: { ...pool.expected },
    sqrtPriceX96: sqrtPriceX96FromPriceX18((PRICE * 102n) / 100n),
    poolTick: 78444,
    oracle: { priceX18: PRICE, updatedAt: 1000n, fresh: true, tick: 78244, target: sqrtPriceX96FromPriceX18(PRICE) },
    core: empty,
    backstop: empty,
    limit: empty,
    idle0: 0n,
    idle1: 0n,
    now: 1060n,
    wallet: {
      address: OWNER, balance0: 10n * ETH, balance1: 30_000n * ETH,
      allowance0Hook: 0n, allowance1Hook: 0n, allowance0Anchor: 0n, allowance1Anchor: 0n, ...wallet,
    },
    ...over,
  }
}
