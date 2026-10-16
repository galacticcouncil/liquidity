// Typed amounts become raw units, and anything that is not a positive number becomes zero, so the
// page never builds a transaction from a minus sign or a typo.
import { describe, expect, it } from 'vitest'
import { parseAmount } from './format'

describe('parseAmount', () => {
  it('a typed amount in raw units', () => {
    expect(parseAmount(' 1.5 ', 18)).toBe(1_500_000_000_000_000_000n)
  })

  it('a negative, empty or malformed amount reads as zero', () => {
    expect(parseAmount('-1', 18)).toBe(0n)
    expect(parseAmount('', 18)).toBe(0n)
    expect(parseAmount('1.2.3', 18)).toBe(0n)
  })
})
