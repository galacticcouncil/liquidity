// What stands in the way of funding, in plain words, before any transaction is offered. The same
// refusals as WalletFund's check, minus the EIP-7702 ones, which do not apply to plain transactions.
import { isAddressEqual, zeroAddress } from 'viem'
import { GAS_RESERVE, type HookConfig, type Pool } from '../config'
import { anchorDirection, type Caps } from './fundPlan'
import { formatAmount, shortAddress } from './format'
import { amount1For } from './math'
import type { PoolState } from './poolState'

/** The names of the hook settings that differ from the ones agreed in the pool's settings file. */
export function settingsDiffer(pool: Pool, s: PoolState): string[] {
  const keys = Object.keys(pool.expected) as (keyof HookConfig)[]
  // as lowercase text, so the source address matches whatever its letter case
  return keys.filter((k) => String(pool.expected[k]).toLowerCase() !== String(s.cfg[k]).toLowerCase())
}

/** What the wallet must hold for this deposit: the deposit, what the anchor may spend, and gas. */
export function needs(pool: Pool, s: PoolState, amount0: bigint, caps: Caps): { need0: bigint; need1: bigint } {
  const direction = anchorDirection(s)
  const gas = pool.token0.address === zeroAddress ? GAS_RESERVE : 0n
  return {
    need0: amount0 + (direction === 'down' ? caps.max0 : 0n) + gas,
    need1: amount1For(amount0, s.oracle.priceX18) + (direction === 'up' ? caps.max1 : 0n),
  }
}

/** The most token0 the wallet can deposit with what it holds, at the oracle price. */
export function maxAmount0(pool: Pool, s: PoolState, caps: Caps): bigint {
  const w = s.wallet
  if (!w || s.oracle.priceX18 === 0n) return 0n
  const { need0, need1 } = needs(pool, s, 0n, caps) // what is held back whatever the deposit
  const by0 = w.balance0 - need0
  const by1 = ((w.balance1 - need1) * 10n ** 18n) / s.oracle.priceX18
  const most = by0 < by1 ? by0 : by1
  return most > 0n ? most : 0n
}

/** Why funding cannot go ahead now; empty when it can. */
export function fundingProblems(pool: Pool, s: PoolState, amount0: bigint, caps: Caps): string[] {
  const w = s.wallet
  if (!w) return ['Connect the owner wallet.']
  if (!isAddressEqual(w.address, s.owner) && !isAddressEqual(w.address, s.pendingOwner)) {
    return [`This wallet is neither the hook's owner (${shortAddress(s.owner)}) nor the wallet it was offered to.`]
  }
  if (s.cfg.source === zeroAddress) return ['The pool is not set up on this hook yet: the deployer runs 01 first.']
  if (s.sqrtPriceX96 === 0n) return ['The pool is not initialized yet: the deployer runs 01 first.']
  const problems: string[] = []
  // checked while taking the hook over from the deployer; once owned, its settings are the owner's to change
  const differ = isAddressEqual(w.address, s.owner) ? [] : settingsDiffer(pool, s)
  if (differ.length) {
    problems.push(`The hook's settings differ from ${pool.settingsFile}: ${differ.join(', ')}. ` +
      'Ask the deployer before accepting it.')
  }
  if (!s.cfg.enabled) problems.push('The pool is switched off on the hook. Switch it on under Manage first.')
  if (!s.oracle.fresh) problems.push('The price feed is stale, so the hook places nothing. Wait for its next update.')
  const distance = Math.abs(s.poolTick - s.oracle.tick)
  if (!anchorDirection(s) && distance > s.cfg.guardTicks) {
    problems.push(`The pool price is ${distance} ticks from the oracle, more than the guard (${s.cfg.guardTicks}). ` +
      'Wait for arbitrage to bring it closer.')
  }
  if (amount0 > 0n) problems.push(...balanceProblems(pool, s, amount0, caps))
  return problems
}

function balanceProblems(pool: Pool, s: PoolState, amount0: bigint, caps: Caps): string[] {
  const w = s.wallet!
  const { need0, need1 } = needs(pool, s, amount0, caps)
  const most = `${formatAmount(maxAmount0(pool, s, caps), pool.token0.decimals)} ${pool.token0.symbol}`
  const problems: string[] = []
  for (const [token, need, have] of [[pool.token0, need0, w.balance0], [pool.token1, need1, w.balance1]] as const) {
    if (have < need) {
      problems.push(`Not enough ${token.symbol}: this needs ${formatAmount(need, token.decimals)} with gas and the ` +
        `anchor's limit, the wallet holds ${formatAmount(have, token.decimals)}. You can deposit at most ${most}.`)
    }
  }
  return problems
}

/** Whether recenter() would act now, and why not, as the hook decides it. */
export function recenterStatus(s: PoolState): { due: boolean; reason: string } {
  if (!s.cfg.enabled) return { due: false, reason: 'The pool is switched off on the hook.' }
  if (!s.oracle.fresh) return { due: false, reason: 'The price feed is stale: nothing moves until it updates.' }
  if (s.core.liquidity + s.limit.liquidity + s.backstop.liquidity === 0n) {
    return { due: false, reason: 'Nothing is placed yet: fund the pool first.' }
  }
  const drift = Math.abs(s.oracle.tick - s.core.center)
  if (s.core.liquidity > 0n && drift <= s.cfg.triggerTicks) {
    return { due: false, reason: `Not due: the oracle is ${drift} ticks from the band's center; due past ${s.cfg.triggerTicks}.` }
  }
  const distance = Math.abs(s.poolTick - s.oracle.tick)
  if (distance > s.cfg.guardTicks) {
    return { due: false, reason: `Due, but the pool is ${distance} ticks from the oracle (guard ${s.cfg.guardTicks}): ` +
      'arbitrage must bring it closer first.' }
  }
  return { due: true, reason: 'Due: anyone can call recenter now.' }
}
