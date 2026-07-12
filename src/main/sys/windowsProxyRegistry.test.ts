import { describe, expect, it } from 'vitest'
import {
  isWindowsProxyRegistrySnapshot,
  sameWindowsProxyRegistrySnapshot,
  type WindowsProxyRegistrySnapshot
} from './windowsProxyRegistry'

describe('WinINET raw snapshot model', () => {
  const snapshot: WindowsProxyRegistrySnapshot = {
    version: 1,
    values: {
      'internet/ProxyServer': { exists: true, kind: 'String', data: 'http=127.0.0.1:1' },
      'internet/AutoConfigURL': { exists: false }
    }
  }

  it('validates and compares exact raw registry state', () => {
    expect(isWindowsProxyRegistrySnapshot(snapshot)).toBe(true)
    expect(sameWindowsProxyRegistrySnapshot(snapshot, structuredClone(snapshot))).toBe(true)
    const changed = structuredClone(snapshot)
    changed.values['internet/ProxyServer'].data = 'socks=127.0.0.1:2'
    expect(sameWindowsProxyRegistrySnapshot(snapshot, changed)).toBe(false)
  })
})
