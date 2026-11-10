// Settings parsing: what the keeper accepts at start, and what it refuses with a plain message.
import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { loadConfig } from './config.js'

const KEY = '0x' + '11'.repeat(32)
const HOOK = '0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0'
const ID = '0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e'

describe('loadConfig', () => {
  it('reads two pools and falls back to the public node and a 5 minute interval', () => {
    const cfg = loadConfig({ PRIVKEY: KEY, POOLS: ` ${HOOK}:${ID} , ${HOOK}:${ID}` })
    assert.equal(cfg.pools.length, 2)
    assert.deepEqual(cfg.pools[0], { hook: HOOK, poolId: ID })
    assert.equal(cfg.rpcUrl, 'https://rpc.mainnet.chain.robinhood.com')
    assert.equal(cfg.intervalMs, 300_000)
  })

  it('takes the node and the interval from the environment', () => {
    const cfg = loadConfig({ PRIVKEY: KEY, POOLS: `${HOOK}:${ID}`, RPC_ROBINHOOD: 'http://node:8547', REFRESH_INTERVAL: '60' })
    assert.equal(cfg.rpcUrl, 'http://node:8547')
    assert.equal(cfg.intervalMs, 60_000)
  })

  it('refuses a missing or short key', () => {
    assert.throws(() => loadConfig({ POOLS: `${HOOK}:${ID}` }), /PRIVKEY/)
    assert.throws(() => loadConfig({ PRIVKEY: '0x1234', POOLS: `${HOOK}:${ID}` }), /PRIVKEY/)
  })

  it('refuses no pools, a pool without an id, and a short id', () => {
    assert.throws(() => loadConfig({ PRIVKEY: KEY, POOLS: ' , ' }), /at least one/)
    assert.throws(() => loadConfig({ PRIVKEY: KEY, POOLS: HOOK }), /not hook:poolId/)
    assert.throws(() => loadConfig({ PRIVKEY: KEY, POOLS: `${HOOK}:0x14f5` }), /not hook:poolId/)
  })

  it('refuses an interval that is not a whole number of seconds, or longer than a day', () => {
    for (const bad of ['0', '-5', '2.5', 'often', '86401']) {
      assert.throws(() => loadConfig({ PRIVKEY: KEY, POOLS: `${HOOK}:${ID}`, REFRESH_INTERVAL: bad }), /REFRESH_INTERVAL/)
    }
  })
})
