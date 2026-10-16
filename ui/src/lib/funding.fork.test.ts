// The owner's whole funding run on a local copy of Robinhood mainnet, through the same plan and send code
// the console uses; anvil stands in for MetaMask and signs as the owner. Run: npm run test:fork
import { execSync, spawn, type ChildProcess } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import {
  createPublicClient, createTestClient, createWalletClient, encodeDeployData, encodeFunctionData, http, isAddressEqual, parseEther, zeroAddress,
  type Address, type PublicClient, type WalletClient,
} from 'viem'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { poolAnchorAbi } from '../abi'
import { anchorBytecode } from '../anchorBytecode'
import { MANAGER, POOLS, robinhood } from '../config'
import { fundingProblems } from './checks'
import { explain } from './errors'
import { fundingSteps, type StepKey } from './fundPlan'
import { sqrtPriceX96FromPriceX18 } from './math'
import { poolKey, readPool } from './poolState'
import { runTx } from './send'

const LOCAL = 'http://127.0.0.1:8599'
const REPO = fileURLToPath(new URL('../../..', import.meta.url))
const pool = POOLS[0]
const caps = { max0: pool.anchorMax0, max1: pool.anchorMax1 }
const ETH = parseEther('1')
const ATTACKER: Address = '0x000000000000000000000000000000000000a77a'

let anvil: ChildProcess
let client: PublicClient
let wallet: WalletClient
const test = createTestClient({ mode: 'anvil', chain: robinhood, transport: http(LOCAL) })
let owner: Address // the wallet the hook is offered to on chain
let anchor: Address | undefined
let snapshot: `0x${string}`

describe.runIf(process.env.FORK)('funding on a fork of Robinhood mainnet', () => {
  beforeAll(async () => {
    const rpc = process.env.FORK_RPC ?? robinhood.rpcUrls.default.http[0]
    anvil = spawn('anvil', ['--fork-url', rpc, '--port', '8599', '--auto-impersonate', '--silent'], { stdio: 'inherit' })
    client = createPublicClient({ chain: robinhood, transport: http(LOCAL) })
    wallet = createWalletClient({ chain: robinhood, transport: http(LOCAL) })
    await waitForNode()
    owner = (await readPool(client, pool)).pendingOwner
    snapshot = await test.snapshot()
  })
  afterAll(() => anvil?.kill())
  beforeEach(async () => {
    await test.revert({ id: snapshot })
    snapshot = await test.snapshot() // a snapshot is used up by reverting to it
    anchor = undefined
  })

  it('the embedded anchor code is script/PoolAnchor.sol as forge compiles it', () => {
    const forge = execSync('forge inspect script/PoolAnchor.sol:PoolAnchor bytecode', { cwd: REPO }).toString().trim()
    expect(anchorBytecode).toBe(forge)
  })

  it('the owner accepts, puts the price back and deposits, ending on the oracle with exact HOLLAR spent', async () => {
    const before = await readPool(client, pool, owner)
    expect(before.wallet && fundingProblems(pool, before, ETH, caps)).toEqual([])
    const sent = await fund()
    expect(sent.at(-1)).toBe('fund')
    expect(sent).toContain('accept')
    const after = await expectFundedOnOracle()
    expect(before.wallet!.balance1 - after.wallet!.balance1).toBe((ETH * after.oracle.priceX18) / 10n ** 18n)
  })

  it('an attacker moves the price past the guard right before the deposit: it is refused, the anchor runs again', async () => {
    await fund('fund') // everything up to the deposit
    const s = await readPool(client, pool, owner, anchor)
    const deposit = fundingSteps(pool, s, ETH, caps, anchor).find((step) => step.key === 'fund')!
    await attackerMovesPrice((s.oracle.priceX18 * 106n) / 100n) // about 580 ticks up, guard is 200
    const refusal = await runTx(client, wallet, owner, deposit.tx!).catch(explain)
    expect(refusal).toMatch(/^GuardTripped/)
    expect(await fund()).toEqual(['anchor', 'fund'])
    await expectFundedOnOracle()
  })
})

/** Sends the plan's first step until the deposit has gone (or `until` is next), as the console does. */
async function fund(until?: StepKey): Promise<StepKey[]> {
  const sent: StepKey[] = []
  for (let i = 0; i < 10; i++) {
    const s = await readPool(client, pool, owner, anchor)
    const [step] = fundingSteps(pool, s, ETH, caps, anchor)
    if (!step || step.key === until) return sent
    const receipt = await runTx(client, wallet, owner, step.tx!)
    if (step.key === 'deployAnchor') anchor = receipt.contractAddress!
    sent.push(step.key)
    if (step.key === 'fund') return sent
  }
  throw new Error('the plan did not finish in 10 steps')
}

async function expectFundedOnOracle() {
  const s = await readPool(client, pool, owner)
  expect(isAddressEqual(s.owner, owner)).toBe(true)
  expect(s.pendingOwner).toBe(zeroAddress)
  expect(s.core.liquidity > 0n && s.backstop.liquidity > 0n).toBe(true)
  expect(Math.abs(s.poolTick - s.oracle.tick)).toBeLessThanOrEqual(1)
  return s
}

/** The attacker deploys its own anchor and moves the empty pool's price for free. */
async function attackerMovesPrice(priceX18: bigint) {
  await test.setBalance({ address: ATTACKER, value: ETH })
  const deploy = { data: encodeDeployData({ abi: poolAnchorAbi, bytecode: anchorBytecode, args: [MANAGER] }), value: 0n }
  const own = (await runTx(client, wallet, ATTACKER, deploy)).contractAddress!
  // a swap of zero is refused; 1 wei is enough, since crossing an empty range costs nothing
  const args = [poolKey(pool), sqrtPriceX96FromPriceX18(priceX18), 1n, 1n] as const
  await runTx(client, wallet, ATTACKER, { to: own, data: encodeFunctionData({ abi: poolAnchorAbi, functionName: 'anchor', args }), value: 0n })
}

async function waitForNode() {
  for (let i = 0; i < 60; i++) {
    try {
      return await client.getChainId()
    } catch {
      await new Promise((r) => setTimeout(r, 1000))
    }
  }
  throw new Error('anvil did not start')
}
