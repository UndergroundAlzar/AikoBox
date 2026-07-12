import { describe, expect, it } from 'vitest'
import {
  chooseSafeTunAddresses,
  extractExplicitTunAddresses,
  networkRangesOverlap,
  parseNetworkRange
} from './tunPreflight'

describe('Windows TUN route preflight', () => {
  it('parses and compares IPv4 and IPv6 networks', () => {
    expect(parseNetworkRange('198.19.0.1/30')).toMatchObject({ version: 4, prefixLength: 30 })
    expect(parseNetworkRange('fdfe:dcba:9876::1/126')).toMatchObject({
      version: 6,
      prefixLength: 126
    })
    expect(networkRangesOverlap('198.19.0.1/30', '198.19.0.2/32')).toBe(true)
    expect(networkRangesOverlap('198.19.0.1/30', '198.19.0.4/30')).toBe(false)
    expect(networkRangesOverlap('fdfe:dcba:9876::1/126', 'fdfe:dcba:9876::2/128')).toBe(true)
  })

  it('moves a generated default away from an occupied route', () => {
    const decision = chooseSafeTunAddresses(['198.19.0.1/30'], ['0.0.0.0/0', '198.19.0.0/30'])
    expect(decision.addresses[0]).not.toBe('198.19.0.1/30')
    expect(networkRangesOverlap(decision.addresses[0], '198.19.0.0/30')).toBe(false)
    expect(decision.changes).toHaveLength(1)
  })

  it('allows the address already owned by the running AikoBox core', () => {
    expect(
      chooseSafeTunAddresses(['198.19.0.1/30'], ['198.19.0.0/30'], [], ['198.19.0.1/30'])
    ).toEqual({ addresses: ['198.19.0.1/30'], changes: [] })
  })

  it('fails closed when an explicitly configured address conflicts', () => {
    expect(() =>
      chooseSafeTunAddresses(['10.10.10.1/30'], ['10.10.10.0/24'], ['10.10.10.1/30'])
    ).toThrow(/overlaps an existing Windows route/)
  })

  it('extracts modern and legacy explicit addresses', () => {
    expect(
      extractExplicitTunAddresses({
        address: [' 10.0.0.1/30 ', 'fd00::1/126'],
        'inet4-address': '192.0.2.1/30'
      })
    ).toEqual(['10.0.0.1/30', 'fd00::1/126', '192.0.2.1/30'])
  })
})
