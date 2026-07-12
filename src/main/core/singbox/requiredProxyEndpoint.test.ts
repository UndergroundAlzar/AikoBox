import { describe, expect, it } from 'vitest'
import {
  assertPinnedRequiredProxyEndpoint,
  assertRequiredProxyEndpoint,
  pinRequiredProxyEndpoint
} from './requiredProxyEndpoint'

describe('required system-proxy endpoint recovery', () => {
  it('pins an existing mixed inbound to the exact stale loopback endpoint', () => {
    const original = {
      inbounds: [
        { type: 'tun', tag: 'tun-in' },
        { type: 'mixed', tag: 'mixed-in', listen: '127.0.0.1', listen_port: 7890 }
      ],
      route: { final: 'proxy' }
    }

    const pinned = pinRequiredProxyEndpoint(original, { host: '127.0.0.1', port: 17890 })
    expect(pinned).not.toBe(original)
    expect((pinned.inbounds as Record<string, unknown>[])[1]).toMatchObject({
      type: 'mixed',
      tag: 'mixed-in',
      listen: '127.0.0.1',
      listen_port: 17890
    })
    expect((original.inbounds as Record<string, unknown>[])[1].listen_port).toBe(7890)
  })

  it('never invents a proxy inbound or accepts a non-loopback journal endpoint', () => {
    expect(() =>
      pinRequiredProxyEndpoint({ inbounds: [{ type: 'tun' }] }, { host: '127.0.0.1', port: 7890 })
    ).toThrow(/no existing HTTP-compatible/i)
    expect(() => assertRequiredProxyEndpoint({ host: '192.0.2.10', port: 7890 })).toThrow(
      /loopback/i
    )
  })

  it('rejects a SOCKS-only recovery config because manual WinINET needs HTTP semantics', () => {
    expect(() =>
      pinRequiredProxyEndpoint(
        { inbounds: [{ type: 'socks', listen: '127.0.0.1', listen_port: 7890 }] },
        { host: '127.0.0.1', port: 17890 }
      )
    ).toThrow(/HTTP-compatible/i)
  })

  it('rejects an endpoint that collides with another listener', () => {
    expect(() =>
      pinRequiredProxyEndpoint(
        {
          inbounds: [
            { type: 'mixed', listen: '127.0.0.1', listen_port: 7890 },
            { type: 'http', listen: '0.0.0.0', listen_port: 17890 }
          ]
        },
        { host: '127.0.0.1', port: 17890 }
      )
    ).toThrow(/conflicts/i)
  })

  it('requires the pinned HTTP listener to use the exact loopback host and port', () => {
    expect(() =>
      assertPinnedRequiredProxyEndpoint(
        { inbounds: [{ type: 'mixed', listen: '127.0.0.1', listen_port: 17890 }] },
        { host: '127.0.0.1', port: 17890 }
      )
    ).not.toThrow()
    expect(() =>
      assertPinnedRequiredProxyEndpoint(
        { inbounds: [{ type: 'mixed', listen: '0.0.0.0', listen_port: 17890 }] },
        { host: '127.0.0.1', port: 17890 }
      )
    ).toThrow(/loopback HTTP endpoint/i)
  })
})
