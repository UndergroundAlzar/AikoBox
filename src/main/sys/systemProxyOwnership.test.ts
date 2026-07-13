import { describe, expect, it } from 'vitest'
import {
  createOwnedSystemProxyRecord,
  isOwnedSystemProxyRecord,
  normalizeSystemProxyState,
  sameSystemProxyState,
  type SystemProxyState
} from './systemProxyOwnership'

const original: SystemProxyState = {
  manual: {
    enable: true,
    host: '127.0.0.1',
    port: 7890,
    bypass: 'localhost;<local>'
  },
  auto: { enable: false, url: '' }
}

describe('system proxy ownership state', () => {
  it('compares the complete manual and PAC state', () => {
    expect(sameSystemProxyState(original, structuredClone(original))).toBe(true)
    expect(
      sameSystemProxyState(original, {
        ...structuredClone(original),
        manual: { ...original.manual, port: 17890 }
      })
    ).toBe(false)
    expect(
      sameSystemProxyState(original, {
        ...structuredClone(original),
        auto: { enable: true, url: 'http://127.0.0.1/pac' }
      })
    ).toBe(false)
  })

  it('normalizes malformed optional native values', () => {
    const normalized = normalizeSystemProxyState({
      manual: { enable: false, host: undefined as unknown as string, port: NaN, bypass: '' },
      auto: { enable: false, url: undefined as unknown as string }
    })
    expect(normalized.manual.host).toBe('')
    expect(normalized.manual.port).toBe(0)
    expect(normalized.auto.url).toBe('')
  })

  it('creates and validates a persisted ownership record', () => {
    const applied: SystemProxyState = {
      manual: { enable: true, host: '127.0.0.1', port: 17890, bypass: '<local>' },
      auto: { enable: false, url: '' }
    }
    const record = createOwnedSystemProxyRecord(original, applied, [], 42, undefined, {
      host: '127.0.0.1',
      port: 17890
    })

    expect(record.ownerPid).toBe(42)
    expect(record.coreEndpoint).toEqual({ host: '127.0.0.1', port: 17890 })
    expect(isOwnedSystemProxyRecord(JSON.parse(JSON.stringify(record)))).toBe(true)
    expect(isOwnedSystemProxyRecord({ version: 2 })).toBe(false)
  })

  it('rejects poisoned ownership journals with non-local core endpoints', () => {
    const applied: SystemProxyState = {
      manual: { enable: true, host: '127.0.0.1', port: 17890, bypass: '<local>' },
      auto: { enable: false, url: '' }
    }
    const record = createOwnedSystemProxyRecord(original, applied, [], 42, undefined, {
      host: '127.0.0.1',
      port: 17890
    })
    const base = JSON.parse(JSON.stringify(record)) as Record<string, unknown>

    expect(
      isOwnedSystemProxyRecord({
        ...base,
        coreEndpoint: { host: '8.8.8.8', port: 7890 }
      })
    ).toBe(false)
    expect(
      isOwnedSystemProxyRecord({
        ...base,
        coreEndpoint: { host: '127.0.0.1', port: 0 }
      })
    ).toBe(false)
    expect(
      isOwnedSystemProxyRecord({
        ...base,
        coreEndpoint: { host: '127.0.0.1', port: 65536 }
      })
    ).toBe(false)
    expect(isOwnedSystemProxyRecord({ ...base, phase: 'owned' })).toBe(false)
    expect(isOwnedSystemProxyRecord({ ...base, revision: -1 })).toBe(false)
  })
})
