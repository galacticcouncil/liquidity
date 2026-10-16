// Price, tick and amount arithmetic, done the way the contracts do it. Exact bigint maths wherever a
// transaction depends on the number (the anchor's target, the token1 deposit); floats only for display.
import type { HookConfig } from '../config'

/** sqrt rounded down, the same loop as PoolScript._sqrt. */
export function sqrtBig(x: bigint): bigint {
  if (x === 0n) return 0n
  let z = x
  let y = (x + 1n) / 2n
  while (y < z) {
    z = y
    y = (x / y + y) / 2n
  }
  return z
}

/** The pool price for an oracle price (raw token1 per raw token0, 1e18): PoolScript._sqrtPriceX96. */
export function sqrtPriceX96FromPriceX18(priceX18: bigint): bigint {
  const inner = (priceX18 * (1n << 128n)) / 10n ** 18n
  return sqrtBig(inner) << 32n
}

/** The tick of an oracle price, rounded down as the hook rounds it. Float maths: within a tick. */
export function tickFromPriceX18(priceX18: bigint): number {
  return Math.floor(Math.log(Number(priceX18) / 1e18) / Math.log(1.0001))
}

/** token1 of equal value to `amount0` at the oracle price, as WalletFund works it out. */
export function amount1For(amount0: bigint, priceX18: bigint): bigint {
  return (amount0 * priceX18) / 10n ** 18n
}

/** How many token1 one token0 is worth at a tick, in whole tokens. */
export function priceAtTick(tick: number, decimals0: number, decimals1: number): number {
  return 1.0001 ** tick * 10 ** (decimals0 - decimals1)
}

/** The fee a swap pays now, in ppm, as beforeSwap works it out: floor plus slope, at most the cap. */
export function feePpm(cfg: HookConfig, poolTick: number, oracleTick: number, fresh: boolean): number {
  if (!fresh) return cfg.feeCap
  const fee = cfg.feeFloor + Math.floor((Math.abs(poolTick - oracleTick) * cfg.feeSlopePpm) / 10_000)
  return Math.min(fee, cfg.feeCap)
}

export type Pos = { lower: number; upper: number; center: number; liquidity: bigint }

/** What a position holds at the pool price, in raw units. Float maths: for display only. */
export function positionAmounts(p: Pos, sqrtPriceX96: bigint): { amount0: number; amount1: number } {
  if (p.liquidity === 0n) return { amount0: 0, amount1: 0 }
  const liquidity = Number(p.liquidity)
  const lower = 1.0001 ** (p.lower / 2)
  const upper = 1.0001 ** (p.upper / 2)
  const price = Math.min(Math.max(Number(sqrtPriceX96) / 2 ** 96, lower), upper)
  return { amount0: liquidity * (1 / price - 1 / upper), amount1: liquidity * (price - lower) }
}
