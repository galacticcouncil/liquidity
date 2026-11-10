// The keeper against the live ETH/HOLLAR hook on an anvil fork of Robinhood mainnet, after the owner (impersonated)
// sets a price source the test can move and leaves an empty core. Needs anvil and forge. Run: npm run test:fork
import assert from 'node:assert/strict'
import { execSync, spawn, type ChildProcess } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { after, before, beforeEach, describe, it } from 'node:test'
import {
  createPublicClient, createTestClient, createWalletClient, http, parseAbi, parseEther, parseEventLogs,
  type Address, type Hex, type PublicClient,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { robinhood, type PoolRef } from './config.js'
import { hookAbi, readPrices } from './hook.js'
import { checkPool, runRound, type Keeper } from './round.js'

const LOCAL = 'http://127.0.0.1:8598'
const REPO = fileURLToPath(new URL('../..', import.meta.url))
const POOL: PoolRef = {
  hook: '0x5C9c3b13986d2b9F49849064190C52Da5Ca050c0',
  poolId: '0x14f58518054cb26b7b029a4c1ccce1dbfec4db50192362d3b001ef61e476b16e',
}
const KEEPER_KEY = generatePrivateKey() // fresh each run, so its nonce starts at 0 on the fork
const ownerAbi = parseAbi([
  'function owner() view returns (address)',
  'function setSource(bytes32 id, address source, int24 expectedTick, int24 tolerance)',
  'function withdraw(bytes32 id)',
  'function fund(bytes32 id, uint256 amount0, uint256 amount1) payable',
  'function core(bytes32 id) view returns (int24 lower, int24 upper, int24 center, uint128 liquidity)',
  'function limit(bytes32 id) view returns (int24 lower, int24 upper, int24 center, uint128 liquidity)',
])
const mockAbi = parseAbi(['constructor(uint256 price)', 'function set(uint256 price, uint256 updatedAt)'])

let anvil: ChildProcess
let client: PublicClient
const test = createTestClient({ mode: 'anvil', chain: robinhood, transport: http(LOCAL) })
const owner = createWalletClient({ chain: robinhood, transport: http(LOCAL) })
let keeper: Keeper
let ownerAddress: Address
let mock: Address
let price: bigint // the mock's price at the snapshot: the pool's own price
let snapshot: Hex

describe('keeper on a fork of Robinhood mainnet', { skip: !process.env.FORK }, () => {
  before(async () => {
    const rpc = process.env.FORK_RPC ?? robinhood.rpcUrls.default.http[0]
    anvil = spawn('anvil', ['--fork-url', rpc, '--port', '8598', '--auto-impersonate', '--silent'], { stdio: 'inherit' })
    client = createPublicClient({ chain: robinhood, transport: http(LOCAL) })
    await waitForNode()
    await test.setBalance({ address: privateKeyToAccount(KEEPER_KEY).address, value: parseEther('1') })
    await emptyCoreOnTheOraclePrice()
    snapshot = await test.snapshot()
  })
  after(() => anvil?.kill())
  beforeEach(async () => {
    await test.revert({ id: snapshot })
    snapshot = await test.snapshot() // reverting uses a snapshot up
    keeper = newKeeper([POOL])
  })

  it('recenters a due pool once, then sends nothing while both prices stay the same', async () => {
    const first = await checkPool(keeper, POOL)
    assert.equal(first.result, 'sent')
    assert.ok(first.result === 'sent' && first.ok)
    const receipt = await client.getTransactionReceipt({ hash: first.tx })
    assert.equal(parseEventLogs({ abi: hookAbi, logs: receipt.logs, eventName: 'Recentered' }).length, 1)

    const nonce = await client.getTransactionCount({ address: keeper.signer.account.address })
    assert.deepEqual(await checkPool(keeper, POOL), { result: 'unchanged' })
    assert.equal(await client.getTransactionCount({ address: keeper.signer.account.address }), nonce)
  })

  it('recenters again once the oracle moves, inside the guard', async () => {
    assert.equal((await checkPool(keeper, POOL)).result, 'sent')
    await setMock((price * 1003n) / 1000n) // about 30 ticks
    const again = await checkPool(keeper, POOL)
    assert.ok(again.result === 'sent' && again.ok)
  })

  it('logs the hook\'s reason and sends nothing when the pool is too far from the oracle', async () => {
    await setMock((price * 106n) / 100n) // about 580 ticks, past the 200 tick guard
    assert.deepEqual(await checkPool(keeper, POOL), { result: 'not-due', reason: 'GuardTripped' })
    assert.equal(await client.getTransactionCount({ address: keeper.signer.account.address }), 0)
  })

  it('logs a stale oracle as a refusal', async () => {
    const now = (await client.getBlock()).timestamp
    await setMock(price, now - 29n * 3600n) // the pool allows 28h
    assert.deepEqual(await checkPool(keeper, POOL), { result: 'not-due', reason: 'StaleOracle' })
  })

  it('keeps going to the next pool when one is refused', async () => {
    const unknown: PoolRef = { hook: POOL.hook, poolId: `0x${'ab'.repeat(32)}` }
    const lines: string[] = []
    await runRound(newKeeper([unknown, POOL]), (line) => lines.push(line))
    assert.equal(lines.length, 2)
    assert.match(lines[0], /result=not-due reason=NotEnabled$/)
    assert.match(lines[1], /result=sent tx=0x[0-9a-f]{64} status=success/)
  })
})

function newKeeper(pools: PoolRef[]): Keeper {
  const account = privateKeyToAccount(KEEPER_KEY)
  return { client, signer: createWalletClient({ chain: robinhood, transport: http(LOCAL), account }), pools, lastSent: new Map() }
}

/** Mock source at the pool's price, then everything withdrawn and 1 ETH funded back: no HOLLAR, so no core. */
async function emptyCoreOnTheOraclePrice() {
  const hook = { address: POOL.hook, abi: ownerAbi } as const
  const account = (ownerAddress = await client.readContract({ ...hook, functionName: 'owner' }))
  await test.setBalance({ address: account, value: parseEther('10') })
  const { sqrtPriceX96 } = await readPrices(client, POOL)
  price = (sqrtPriceX96 * sqrtPriceX96 * 10n ** 18n) >> 192n
  const bytecode = execSync('forge inspect test/mocks/SourceMocks.sol:ToggleRevertSource bytecode', { cwd: REPO })
    .toString().trim() as Hex
  const deployed = await owner.deployContract({ abi: mockAbi, bytecode, args: [price], account, chain: robinhood })
  mock = (await client.waitForTransactionReceipt({ hash: deployed })).contractAddress!
  const tick = Math.floor(Math.log(Number(price) / 1e18) / Math.log(1.0001))
  const base = { ...hook, account, chain: robinhood }
  await confirm(await owner.writeContract({ ...base, functionName: 'setSource', args: [POOL.poolId, mock, tick, 2] }))
  await confirm(await owner.writeContract({ ...base, functionName: 'withdraw', args: [POOL.poolId] }))
  await confirm(await owner.writeContract({
    ...base, functionName: 'fund', args: [POOL.poolId, parseEther('1'), 0n], value: parseEther('1'),
  }))
  const [core, limit] = await Promise.all([
    client.readContract({ ...hook, functionName: 'core', args: [POOL.poolId] }),
    client.readContract({ ...hook, functionName: 'limit', args: [POOL.poolId] }),
  ])
  assert.equal(core[3], 0n, 'setup: the core should be empty')
  assert.ok(limit[3] > 0n, 'setup: the limit should hold the ETH')
}

async function setMock(newPrice: bigint, updatedAt?: bigint) {
  const at = updatedAt ?? (await client.getBlock()).timestamp
  await confirm(await owner.writeContract({
    address: mock, abi: mockAbi, functionName: 'set', args: [newPrice, at], account: ownerAddress, chain: robinhood,
  }))
}

async function confirm(hash: Hex) {
  const receipt = await client.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success', `setup tx ${hash} reverted`)
}

async function waitForNode() {
  for (let i = 0; i < 60; i++) {
    try {
      await client.getChainId()
      return
    } catch {
      await new Promise((r) => setTimeout(r, 500))
    }
  }
  throw new Error('anvil did not start')
}
