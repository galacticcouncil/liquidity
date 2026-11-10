// One keeper round: for each pool, ask the hook, skip when nothing changed since this keeper last recentered it,
// otherwise send. One log line per pool, and one pool failing never stops the others.
import { BaseError, type Hex, type PublicClient } from 'viem'
import type { PoolRef } from './config.js'
import { readPrices, refusal, sendRecenter, type Prices, type Signer } from './hook.js'

export type Keeper = {
  client: PublicClient
  signer: Signer
  pools: PoolRef[]
  lastSent: Map<Hex, Prices> // per pool id, the prices at this keeper's last successful recenter
}

export type Outcome =
  | { result: 'sent'; tx: Hex; ok: boolean; gasUsed: bigint }
  | { result: 'not-due'; reason: string }
  | { result: 'unchanged' }
  | { result: 'error'; message: string }

/** With an empty core the hook accepts a recenter on every call; this stops resending the same placement. */
export function samePrices(last: Prices | undefined, now: Prices): boolean {
  return last !== undefined && last.oraclePriceX18 === now.oraclePriceX18 && last.sqrtPriceX96 === now.sqrtPriceX96
}

export async function checkPool(k: Keeper, pool: PoolRef): Promise<Outcome> {
  try {
    const reason = await refusal(k.client, k.signer, pool)
    if (reason !== undefined) return { result: 'not-due', reason }
    const prices = await readPrices(k.client, pool)
    if (samePrices(k.lastSent.get(pool.poolId), prices)) return { result: 'unchanged' }
    const sent = await sendRecenter(k.client, k.signer, pool)
    if (sent.ok) k.lastSent.set(pool.poolId, prices)
    return { result: 'sent', tx: sent.hash, ok: sent.ok, gasUsed: sent.gasUsed }
  } catch (err) {
    return { result: 'error', message: shortMessage(err) }
  }
}

/** Pools one at a time, so two sends never race for the same nonce. */
export async function runRound(k: Keeper, log: (line: string) => void = console.log): Promise<void> {
  for (const pool of k.pools) {
    const outcome = await checkPool(k, pool)
    log(formatLine(new Date(), pool, outcome))
  }
}

export function formatLine(at: Date, pool: PoolRef, o: Outcome): string {
  const head = `${at.toISOString()} pool=${pool.poolId} result=${o.result}`
  switch (o.result) {
    case 'sent':
      return `${head} tx=${o.tx} status=${o.ok ? 'success' : 'reverted'} gas=${o.gasUsed}`
    case 'not-due':
      return `${head} reason=${o.reason}`
    case 'unchanged':
      return head
    case 'error':
      return `${head} message="${o.message}"`
  }
}

function shortMessage(err: unknown): string {
  const text = err instanceof BaseError ? err.shortMessage : err instanceof Error ? err.message : String(err)
  return text.replace(/\s+/g, ' ').replace(/"/g, "'")
}
