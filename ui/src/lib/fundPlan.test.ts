// Which transactions the funding plan offers, in which order and with which amounts, for made-up pool states
// that start from the live ETH/HOLLAR launch (see testLaunch.ts).
import { decodeFunctionData, zeroAddress, type Address } from 'viem'
import { describe, expect, it } from 'vitest'
import { bandHookAbi, erc20Abi } from '../abi'
import { fundingSteps } from './fundPlan'
import { sqrtPriceX96FromPriceX18 } from './math'
import type { PoolState } from './poolState'
import { ANCHOR, ETH, FUNDED_CORE, OWNER, PRICE, caps, launch, pool } from './testLaunch'

const keys = (s: PoolState, anchor?: Address) => fundingSteps(pool, s, ETH, caps, anchor).map((step) => step.key)

describe('funding plan', () => {
  it('the offered wallet on an empty pool above the oracle: accept, approve, deploy, anchor, fund', () => {
    expect(keys(launch())).toEqual(['accept', 'approve1', 'deployAnchor', 'anchor', 'fund'])
  })

  it('the anchor waits for its address, then sells ETH sent as value', () => {
    const [anchorStep] = fundingSteps(pool, launch(), ETH, caps).filter((s) => s.key === 'anchor')
    expect(anchorStep.tx).toBeUndefined()
    const [ready] = fundingSteps(pool, launch(), ETH, caps, ANCHOR).filter((s) => s.key === 'anchor')
    expect(ready.tx).toMatchObject({ to: ANCHOR, value: caps.max0 })
  })

  it('a pool below the oracle needs the anchor allowed to spend HOLLAR, and sends no ETH', () => {
    const below = launch({ sqrtPriceX96: sqrtPriceX96FromPriceX18((PRICE * 98n) / 100n), poolTick: 78042 })
    expect(keys(below, ANCHOR)).toEqual(['accept', 'approve1', 'approveAnchor', 'anchor', 'fund'])
    const anchorStep = fundingSteps(pool, below, ETH, caps, ANCHOR).find((s) => s.key === 'anchor')
    expect(anchorStep?.tx?.value).toBe(0n)
  })

  it('the owner of a pool on the oracle with enough allowance only funds, sending the ETH as value', () => {
    const ready = launch({ owner: OWNER, pendingOwner: zeroAddress, poolTick: 78245 }, { allowance1Hook: 10n ** 30n })
    const steps = fundingSteps(pool, ready, ETH, caps)
    expect(steps.map((s) => s.key)).toEqual(['fund'])
    const call = decodeFunctionData({ abi: bandHookAbi, data: steps[0].tx!.data })
    expect(call.args).toEqual([ready.id, ETH, 2_500n * ETH])
    expect(steps[0].tx?.value).toBe(ETH)
  })

  it('a pool the hook already holds liquidity in is never anchored, even off the oracle', () => {
    expect(keys(launch({ owner: OWNER, core: FUNDED_CORE }))).toEqual(['approve1', 'fund'])
  })

  it('the hook is approved for 1% more HOLLAR than the deposit', () => {
    const approve = fundingSteps(pool, launch(), ETH, caps).find((s) => s.key === 'approve1')
    const call = decodeFunctionData({ abi: erc20Abi, data: approve!.tx!.data })
    expect(call.args).toEqual([pool.hook, 2_525n * ETH])
  })

  it('nothing to send without an amount', () => {
    expect(fundingSteps(pool, launch(), 0n, caps)).toEqual([])
  })
})
