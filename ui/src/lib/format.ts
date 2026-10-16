// Turning raw chain numbers into what a person reads, and typed amounts back into raw units.
// Display only: nothing here decides what a transaction sends, except parseAmount.
import { formatUnits, parseUnits, type Address } from 'viem'

/** A raw amount in whole tokens, at most `digits` decimals, with thousands separators. */
export function formatAmount(raw: bigint | number, decimals: number, digits = 4): string {
  const whole = typeof raw === 'bigint' ? Number(formatUnits(raw, decimals)) : raw / 10 ** decimals
  return whole.toLocaleString('en-US', { maximumFractionDigits: digits })
}

/** A typed amount in raw units; 0 when the text is empty, negative or not a number. */
export function parseAmount(text: string, decimals: number): bigint {
  try {
    const raw = text.trim() === '' ? 0n : parseUnits(text.trim(), decimals)
    return raw > 0n ? raw : 0n
  } catch {
    return 0n
  }
}

export function formatPrice(price: number): string {
  return price.toLocaleString('en-US', { maximumSignificantDigits: 6 })
}

/** Parts per million as a percentage: 800 -> 0.08%. */
export function formatPpm(ppm: number): string {
  return `${(ppm / 10_000).toLocaleString('en-US', { maximumFractionDigits: 4 })}%`
}

export function shortAddress(address: Address | string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Seconds as the largest whole unit: 90 -> "1 min", 7300 -> "2 h". */
export function formatAge(seconds: number): string {
  if (seconds < 60) return `${seconds} s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min`
  if (seconds < 172_800) return `${Math.floor(seconds / 3600)} h`
  return `${Math.floor(seconds / 86_400)} days`
}
