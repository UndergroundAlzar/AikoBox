import { describe, expect, it } from 'vitest'
import { deriveProxyPortFromSingboxConfig } from './configIntrospection'

describe('deriveProxyPortFromSingboxConfig', () => {
  it('prefers the mixed inbound and validates its port', () => {
    expect(
      deriveProxyPortFromSingboxConfig({
        inbounds: [
          { type: 'socks', listen_port: 1080 },
          { type: 'mixed', listen_port: 17890 }
        ]
      })
    ).toBe(17890)
    expect(
      deriveProxyPortFromSingboxConfig({ inbounds: [{ type: 'mixed', listen_port: 0 }] })
    ).toBeUndefined()
  })

  it('falls back to an HTTP or SOCKS inbound', () => {
    expect(
      deriveProxyPortFromSingboxConfig({ inbounds: [{ type: 'http', listen_port: 8080 }] })
    ).toBe(8080)
  })
})
