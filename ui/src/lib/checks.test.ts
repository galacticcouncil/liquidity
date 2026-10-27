// What stops a deposit before any transaction is offered, for made-up pool states that start from the
// live ETH/HOLLAR launch (see testLaunch.ts).
import type { Address } from 'viem'
import { describe, expect, it } from 'vitest'
import { fundingProblems, maxAmount0, settingsDiffer } from './checks'
import { ETH, FUNDED_CORE, OWNER, PRICE, caps, launch, pool } from './testLaunch'

describe('funding checks', () => {
  it('a launch with enough of both tokens has no problems', () => {
    expect(fundingProblems(pool, launch(), ETH, caps)).toEqual([])
  })

  it('a wallet that is neither owner nor offered is refused', () => {
    const stranger = launch({}, { address: '0x00000000000000000000000000000000000000e1' })
    expect(fundingProblems(pool, stranger, ETH, caps)[0]).toMatch(/neither the hook's owner/)
  })

  it('a stale oracle is refused', () => {
    const stale = launch({ oracle: { ...launch().oracle, fresh: false } })
    expect(fundingProblems(pool, stale, ETH, caps)).toContainEqual(expect.stringMatching(/stale/))
  })

  it('too little HOLLAR names the most ETH the wallet can deposit', () => {
    const short = launch({}, { balance1: 1_001n * ETH }) // the price moves down, so no HOLLAR is kept for the anchor
    expect(maxAmount0(pool, short, caps)).toBe((1_001n * ETH * 10n ** 18n) / PRICE)
    expect(fundingProblems(pool, short, ETH, caps)).toEqual([expect.stringMatching(/Not enough HOLLAR.*at most 0.4004 ETH/)])
  })

  it('a funded pool past the guard is refused; an empty one is not, the anchor fixes it', () => {
    const far = { poolTick: 78500 }
    expect(fundingProblems(pool, launch(far), ETH, caps)).toEqual([])
    const funded = launch({ ...far, owner: OWNER, core: FUNDED_CORE })
    expect(fundingProblems(pool, funded, ETH, caps)).toEqual([expect.stringMatching(/256 ticks from the oracle/)])
  })

  it('a hook setting that differs from the agreed file is named', () => {
    const off = launch({ cfg: { ...pool.expected, guardTicks: 300, source: pool.expected.source.toLowerCase() as Address } })
    expect(settingsDiffer(pool, off)).toEqual(['guardTicks'])
  })

  it('a differing setting blocks taking the hook over, but not the owner who changed it later', () => {
    const changed = { cfg: { ...pool.expected, autoRecenter: false } }
    expect(fundingProblems(pool, launch(changed), ETH, caps)).toEqual([expect.stringMatching(/before accepting it/)])
    expect(fundingProblems(pool, launch({ ...changed, owner: OWNER }), ETH, caps)).toEqual([])
  })
})
