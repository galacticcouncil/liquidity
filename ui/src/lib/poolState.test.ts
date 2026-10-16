// The pool's id and the PoolManager's slot0 word, decoded the way Uniswap v4 encodes them; checked
// against the live ETH/HOLLAR pool (id from cast, slot0 word read on 2026-10-16).
import { describe, expect, it } from 'vitest'
import { POOLS } from '../config'
import { decodeSlot0, poolId } from './poolState'

describe('poolState', () => {
  it('the ETH/HOLLAR pool id is the one 01_SetupPool created', () => {
    expect(poolId(POOLS[0])).toBe('0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e')
  })

  it('slot0 splits into price, tick and fee', () => {
    const live = decodeSlot0('0x0000000003200000000131da0000000000000032228bd12b503487a400000000')
    expect(live).toEqual({ sqrtPriceX96: 3972099644509653353754752188416n, tick: 78298, lpFee: 800 })
  })

  it('a negative tick keeps its sign', () => {
    const word = `0x${(((1n << 24n) - 5n) << 160n).toString(16).padStart(64, '0')}` as const
    expect(decodeSlot0(word).tick).toBe(-5)
  })
})
