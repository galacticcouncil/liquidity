// The round's own rules, without a chain: when a recenter counts as a repeat, how a line reads,
// and that a node that does not answer turns into an error line rather than a crash.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { describe, it } from 'node:test'
import { createPublicClient, createWalletClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { robinhood, type PoolRef } from './config.js'
import { checkPool, formatLine, samePrices, type Keeper } from './round.js'

const POOL: PoolRef = {
  hook: '0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0',
  poolId: '0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e',
}
const prices = { oraclePriceX18: 2_036n * 10n ** 18n, sqrtPriceX96: 3_595_000_000_000_000_000_000_000_000n }

describe('samePrices', () => {
  it('is false before this keeper has recentered the pool', () => {
    assert.equal(samePrices(undefined, prices), false)
  })

  it('is true only when both the oracle price and the pool price are unchanged', () => {
    assert.equal(samePrices({ ...prices }, prices), true)
    assert.equal(samePrices({ ...prices, oraclePriceX18: prices.oraclePriceX18 + 1n }, prices), false)
    assert.equal(samePrices({ ...prices, sqrtPriceX96: prices.sqrtPriceX96 - 1n }, prices), false)
  })
})

describe('formatLine', () => {
  const at = new Date('2026-11-10T20:00:00.000Z')

  it('shows the tx, its status and the gas for a send', () => {
    const line = formatLine(at, POOL, { result: 'sent', tx: '0xabc', ok: true, gasUsed: 301_872n })
    assert.equal(line, `2026-11-10T20:00:00.000Z pool=${POOL.poolId} result=sent tx=0xabc status=success gas=301872`)
  })

  it('shows the hook\'s reason when it refuses', () => {
    assert.match(formatLine(at, POOL, { result: 'not-due', reason: 'DriftBelowTrigger' }), /result=not-due reason=DriftBelowTrigger$/)
  })
})

describe('checkPool', () => {
  it('turns a node that does not answer into an error outcome', async () => {
    const outcome = await checkPool(keeperOn('http://127.0.0.1:1'), POOL)
    assert.equal(outcome.result, 'error')
  })

  it('reports a node\'s internal error as an error, not as the hook refusing', async () => {
    const node = createServer((req, res) => {
      req.resume().on('end', () => {
        res.setHeader('content-type', 'application/json')
        res.end(JSON.stringify({ jsonrpc: '2.0', id: 0, error: { code: -32603, message: 'internal error' } }))
      })
    })
    await new Promise<void>((ok) => node.listen(0, '127.0.0.1', ok))
    try {
      const outcome = await checkPool(keeperOn(`http://127.0.0.1:${(node.address() as AddressInfo).port}`), POOL)
      assert.equal(outcome.result, 'error')
    } finally {
      node.close()
    }
  })
})

function keeperOn(url: string): Keeper {
  const transport = http(url, { retryCount: 0 })
  return {
    client: createPublicClient({ chain: robinhood, transport }),
    signer: createWalletClient({ chain: robinhood, transport, account: privateKeyToAccount(`0x${'11'.repeat(32)}`) }),
    pools: [POOL],
    lastSent: new Map(),
  }
}
