// Reads everything the console shows and decides from: the hook, its pool, the oracle and the connected
// wallet. Each refresh builds a fresh PoolState from the chain; nothing is kept between refreshes.
import { encodeAbiParameters, keccak256, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'
import { bandHookAbi, erc20Abi, managerAbi, priceSourceAbi } from '../abi'
import { MANAGER, type HookConfig, type Pool } from '../config'
import { sqrtPriceX96FromPriceX18, tickFromPriceX18, type Pos } from './math'

const DYNAMIC_FEE = 0x800000 // LPFeeLibrary.DYNAMIC_FEE_FLAG
const POOLS_SLOT = 6n // where the PoolManager keeps its pools, as StateLibrary reads it

export type Oracle = { priceX18: bigint; updatedAt: bigint; fresh: boolean; tick: number; target: bigint }

export type WalletState = {
  address: Address
  balance0: bigint
  balance1: bigint
  allowance0Hook: bigint
  allowance1Hook: bigint
  allowance0Anchor: bigint
  allowance1Anchor: bigint
}

export type PoolState = {
  id: Hex
  owner: Address
  pendingOwner: Address
  cfg: HookConfig
  sqrtPriceX96: bigint // 0 until the pool is initialized
  poolTick: number
  oracle: Oracle
  core: Pos
  backstop: Pos
  limit: Pos
  idle0: bigint // tokens in the hook that are not placed
  idle1: bigint
  now: bigint
  wallet?: WalletState
}

export function poolKey(pool: Pool) {
  const { token0, token1, tickSpacing, hook } = pool
  return { currency0: token0.address, currency1: token1.address, fee: DYNAMIC_FEE, tickSpacing, hooks: hook }
}

/** keccak256 of the encoded key, as PoolIdLibrary.toId. */
export function poolId(pool: Pool): Hex {
  const k = poolKey(pool)
  const types = [{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }]
  return keccak256(encodeAbiParameters(types, [k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks]))
}

/** The pool's slot0 word, split as StateLibrary.getSlot0 splits it. */
export function decodeSlot0(word: Hex) {
  const v = BigInt(word)
  return {
    sqrtPriceX96: v & ((1n << 160n) - 1n),
    tick: Number(BigInt.asIntN(24, v >> 160n)),
    lpFee: Number((v >> 208n) & 0xffffffn),
  }
}

export async function readPool(client: PublicClient, pool: Pool, wallet?: Address, anchor?: Address): Promise<PoolState> {
  const id = poolId(pool)
  const hook = { address: pool.hook, abi: bandHookAbi } as const
  const slot = keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'uint256' }], [id, POOLS_SLOT]))
  const [owner, pendingOwner, raw, core, backstop, limit, slot0, block, idle0, idle1] = await Promise.all([
    client.readContract({ ...hook, functionName: 'owner' }),
    client.readContract({ ...hook, functionName: 'pendingOwner' }),
    client.readContract({ ...hook, functionName: 'config', args: [id] }),
    client.readContract({ ...hook, functionName: 'core', args: [id] }),
    client.readContract({ ...hook, functionName: 'backstop', args: [id] }),
    client.readContract({ ...hook, functionName: 'limit', args: [id] }),
    client.readContract({ address: MANAGER, abi: managerAbi, functionName: 'extsload', args: [slot] }),
    client.getBlock(),
    balanceOf(client, pool.token0.address, pool.hook),
    balanceOf(client, pool.token1.address, pool.hook),
  ])
  const [source, feeFloor, feeCap, feeSlopePpm, staleAfter, halfBandTicks, backstopHalfTicks, backstopBps,
    triggerTicks, guardTicks, enabled, autoRecenter] = raw
  const cfg: HookConfig = { source, feeFloor, feeCap, feeSlopePpm, staleAfter, halfBandTicks, backstopHalfTicks,
    backstopBps, triggerTicks, guardTicks, enabled, autoRecenter }
  const [oracle, walletState] = await Promise.all([
    readOracle(client, cfg, block.timestamp),
    wallet ? readWallet(client, pool, wallet, anchor) : undefined,
  ])
  const { sqrtPriceX96, tick } = decodeSlot0(slot0)
  return {
    id, owner, pendingOwner, cfg, sqrtPriceX96, poolTick: tick, oracle,
    core: toPos(core), backstop: toPos(backstop), limit: toPos(limit),
    idle0, idle1, now: block.timestamp, wallet: walletState,
  }
}

/** The oracle as the hook sees it: no price, a future time or one older than staleAfter is not fresh. */
async function readOracle(client: PublicClient, cfg: HookConfig, now: bigint): Promise<Oracle> {
  const none = { priceX18: 0n, updatedAt: 0n, fresh: false, tick: 0, target: 0n }
  if (cfg.source === zeroAddress) return none
  try {
    const [priceX18, updatedAt] = await client.readContract({
      address: cfg.source, abi: priceSourceAbi, functionName: 'priceX18',
    })
    if (priceX18 === 0n) return none
    const fresh = updatedAt <= now && now - updatedAt <= BigInt(cfg.staleAfter)
    return { priceX18, updatedAt, fresh, tick: tickFromPriceX18(priceX18), target: sqrtPriceX96FromPriceX18(priceX18) }
  } catch {
    return none // a source that reverts gives no price, as the hook treats it
  }
}

async function readWallet(client: PublicClient, pool: Pool, address: Address, anchor?: Address): Promise<WalletState> {
  const [balance0, balance1, allowance0Hook, allowance1Hook, allowance0Anchor, allowance1Anchor] = await Promise.all([
    balanceOf(client, pool.token0.address, address),
    balanceOf(client, pool.token1.address, address),
    allowance(client, pool.token0.address, address, pool.hook),
    allowance(client, pool.token1.address, address, pool.hook),
    anchor ? allowance(client, pool.token0.address, address, anchor) : 0n,
    anchor ? allowance(client, pool.token1.address, address, anchor) : 0n,
  ])
  return { address, balance0, balance1, allowance0Hook, allowance1Hook, allowance0Anchor, allowance1Anchor }
}

function balanceOf(client: PublicClient, token: Address, who: Address): Promise<bigint> {
  if (token === zeroAddress) return client.getBalance({ address: who })
  return client.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [who] })
}

/** Native ETH needs no approval: it travels as the transaction's value. */
async function allowance(client: PublicClient, token: Address, owner: Address, spender: Address): Promise<bigint> {
  if (token === zeroAddress) return 0n
  return client.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [owner, spender] })
}

function toPos([lower, upper, center, liquidity]: readonly [number, number, number, bigint]): Pos {
  return { lower, upper, center, liquidity }
}
