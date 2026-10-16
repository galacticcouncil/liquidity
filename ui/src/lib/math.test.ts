// The arithmetic the console's transactions depend on, against values worked out independently
// (Python's integer sqrt and log) and against the hook's own fee rule.
import { describe, expect, it } from 'vitest'
import { POOLS } from '../config'
import { amount1For, feePpm, positionAmounts, sqrtPriceX96FromPriceX18, tickFromPriceX18 } from './math'

const LIVE_PRICE = 2_464_413_925_440_000_000_000n // ETH/USD source on 2026-10-16: $2,464.41

describe('math', () => {
  it('a price of one is the pool price 2^96', () => {
    expect(sqrtPriceX96FromPriceX18(10n ** 18n)).toBe(2n ** 96n)
  })

  it('the anchor target matches PoolScript._sqrtPriceX96 for a live price', () => {
    expect(sqrtPriceX96FromPriceX18(LIVE_PRICE)).toBe(3933112880161275780299908710400n)
  })

  it('the oracle tick rounds down', () => {
    expect(tickFromPriceX18(LIVE_PRICE)).toBe(78100)
    expect(tickFromPriceX18(10n ** 18n / 2n)).toBe(-6932) // ln(0.5)/ln(1.0001) = -6931.8
  })

  it('token1 of equal value at the oracle price', () => {
    expect(amount1For(10n ** 18n, LIVE_PRICE)).toBe(LIVE_PRICE)
    expect(amount1For(3n * 10n ** 17n, LIVE_PRICE)).toBe(739_324_177_632_000_000_000n)
  })

  it('the fee is floor plus slope, capped, and the cap when the oracle is stale', () => {
    const cfg = POOLS[0].expected // floor 800, cap 10000, slope 1e6
    expect(feePpm(cfg, 100, 100, true)).toBe(800)
    expect(feePpm(cfg, 150, 100, true)).toBe(5800)
    expect(feePpm(cfg, 300, 100, true)).toBe(10_000)
    expect(feePpm(cfg, 100, 100, false)).toBe(10_000)
  })

  it('a position below the price holds only token1, an empty one nothing', () => {
    const below = positionAmounts({ lower: -200, upper: -100, center: -150, liquidity: 10n ** 18n }, 2n ** 96n)
    expect(below.amount0).toBe(0)
    expect(below.amount1).toBeGreaterThan(0)
    expect(positionAmounts({ lower: 0, upper: 0, center: 0, liquidity: 0n }, 2n ** 96n)).toEqual({ amount0: 0, amount1: 0 })
  })
})
