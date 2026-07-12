import { describe, expect, it } from 'vitest'
import { compileSafeClashRegex } from './safeRegex'

describe('safe Clash filter regex', () => {
  it('supports common case-insensitive region filters', () => {
    const regex = compileSafeClashRegex('(?i)香港|hong kong|hk')
    expect(regex.test('Premium HK 01')).toBe(true)
  })

  it('rejects nested quantifiers, backreferences, lookarounds, and oversized patterns', () => {
    expect(() => compileSafeClashRegex('^(a+)+$')).toThrow(/nested/)
    expect(() => compileSafeClashRegex('(a.*)*')).toThrow(/nested/)
    expect(() => compileSafeClashRegex('(a)\\1')).toThrow(/backreferences/)
    expect(() => compileSafeClashRegex('a(?=b)')).toThrow(/lookarounds/)
    expect(() => compileSafeClashRegex('a'.repeat(257))).toThrow(/1-256/)
  })
})
