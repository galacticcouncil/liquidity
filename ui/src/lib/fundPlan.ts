// The owner's funding as plain transactions, worked out again from the chain after each one: accept, approve,
// anchor, fund. fund.sh's single EIP-7702 transaction is not signable from a Ledger in MetaMask.
import { encodeDeployData, encodeFunctionData, isAddressEqual, zeroAddress, type Address, type Hex } from 'viem'
import { bandHookAbi, erc20Abi, poolAnchorAbi } from '../abi'
import { anchorBytecode } from '../anchorBytecode'
import { MANAGER, type Pool, type Token } from '../config'
import { formatAmount } from './format'
import { amount1For } from './math'
import { poolKey, type PoolState } from './poolState'

export type Tx = { to?: Address; data: Hex; value: bigint } // no `to`: a contract deployment
export type StepKey = 'accept' | 'approve0' | 'approve1' | 'deployAnchor' | 'approveAnchor' | 'anchor' | 'fund'
/** One transaction still to send. `tx` is missing while it waits for the anchor's address. */
export type Step = { key: StepKey; title: string; why: string; tx?: Tx }
/** The most the anchor may spend of each token to put the price back. */
export type Caps = { max0: bigint; max1: bigint }

/** Extra token1 approved for the hook, so a feed update between approve and fund needs no second approve. */
const HEADROOM_BPS = 100n

/** When the hook holds nothing and the pool is more than a tick off the oracle, which way to move it:
 * 'down' sells token0, 'up' sells token1. Null when no anchor is needed. */
export function anchorDirection(s: PoolState): 'down' | 'up' | null {
  const placed = s.core.liquidity + s.backstop.liquidity + s.limit.liquidity
  if (placed > 0n || Math.abs(s.poolTick - s.oracle.tick) <= 1) return null
  return s.oracle.target < s.sqrtPriceX96 ? 'down' : 'up'
}

/** The transactions still to send, in order. Only the first is ever sent; then the list is worked out again. */
export function fundingSteps(pool: Pool, s: PoolState, amount0: bigint, caps: Caps, anchor?: Address): Step[] {
  const w = s.wallet
  if (!w || amount0 === 0n) return []
  const native = pool.token0.address === zeroAddress
  const amount1 = amount1For(amount0, s.oracle.priceX18)
  const steps: Step[] = []
  if (!isAddressEqual(s.owner, w.address)) {
    steps.push({
      key: 'accept',
      title: 'Accept ownership of the hook',
      why: 'The deployer offered your wallet the hook. Only the owner can deposit.',
      tx: { to: pool.hook, data: encodeFunctionData({ abi: bandHookAbi, functionName: 'acceptOwnership' }), value: 0n },
    })
  }
  if (!native && w.allowance0Hook < amount0) steps.push(approve('approve0', pool.token0, pool.hook, amount0, 'the hook'))
  if (w.allowance1Hook < amount1) {
    steps.push(approve('approve1', pool.token1, pool.hook, amount1 + (amount1 * HEADROOM_BPS) / 10_000n, 'the hook'))
  }
  const direction = anchorDirection(s)
  if (direction) steps.push(...anchorSteps(pool, s, direction, caps, anchor))
  const data = encodeFunctionData({ abi: bandHookAbi, functionName: 'fund', args: [s.id, amount0, amount1] })
  steps.push({
    key: 'fund',
    title: `Deposit ${formatAmount(amount0, pool.token0.decimals)} ${pool.token0.symbol} and ` +
      `${formatAmount(amount1, pool.token1.decimals)} ${pool.token1.symbol}`,
    why: 'The hook takes both tokens and places them around the oracle price. It refuses if the pool price ' +
      'is further than the guard from the oracle; then the console puts the price back again.',
    tx: { to: pool.hook, data, value: native ? amount0 : 0n },
  })
  return steps
}

/** Deploy the anchor if the page has none yet, let it spend the token it sells, then the anchor itself. */
function anchorSteps(pool: Pool, s: PoolState, direction: 'down' | 'up', caps: Caps, anchor?: Address): Step[] {
  const w = s.wallet!
  const native = pool.token0.address === zeroAddress
  const steps: Step[] = []
  if (!anchor) {
    steps.push({
      key: 'deployAnchor',
      title: 'Deploy the anchor',
      why: `The hook holds nothing yet and the pool price is ${Math.abs(s.poolTick - s.oracle.tick)} ticks from ` +
        'the oracle. Only a contract can swap on Uniswap v4, so your wallet deploys this small helper ' +
        '(script/PoolAnchor.sol). It has no rights over the hook and spends only what you send it.',
      tx: { data: encodeDeployData({ abi: poolAnchorAbi, bytecode: anchorBytecode, args: [MANAGER] }), value: 0n },
    })
  }
  if (direction === 'down' && !native && w.allowance0Anchor < caps.max0) {
    steps.push(approve('approveAnchor', pool.token0, anchor, caps.max0, 'the anchor'))
  }
  if (direction === 'up' && w.allowance1Anchor < caps.max1) {
    steps.push(approve('approveAnchor', pool.token1, anchor, caps.max1, 'the anchor'))
  }
  const args = [poolKey(pool), s.oracle.target, caps.max0, caps.max1] as const
  steps.push({
    key: 'anchor',
    title: 'Put the pool price back on the oracle',
    why: 'One swap whose price limit is the oracle price: free on an empty pool, and unused ETH comes back. ' +
      'Send the deposit right after it.',
    tx: anchor && {
      to: anchor,
      data: encodeFunctionData({ abi: poolAnchorAbi, functionName: 'anchor', args }),
      value: direction === 'down' && native ? caps.max0 : 0n,
    },
  })
  return steps
}

function approve(key: StepKey, token: Token, spender: Address | undefined, amount: bigint, who: string): Step {
  return {
    key,
    title: `Let ${who} spend up to ${formatAmount(amount, token.decimals)} ${token.symbol}`,
    why: who === 'the hook'
      ? 'The hook takes the deposit from your wallet. The 1% extra covers a price feed update before the deposit.'
      : 'The most the anchor may spend if others\' liquidity is in the way. On an empty pool it spends nothing.',
    tx: spender && {
      to: token.address,
      data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [spender, amount] }),
      value: 0n,
    },
  }
}
