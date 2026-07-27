import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { convertClashToSingbox } from './convert'
import { resolveProxyProviders } from './providerResolver'

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'aikobox-provider-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

describe('proxy provider resolver', () => {
  it('expands inline providers into proxies and group members', async () => {
    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          airport: {
            type: 'inline',
            payload: [
              {
                name: 'HK-01',
                type: 'ss',
                server: '192.0.2.1',
                port: 443,
                cipher: 'aes-128-gcm',
                password: 'x'
              }
            ]
          }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )

    expect(result.errors).toEqual([])
    expect((result.config.proxies as Record<string, unknown>[])[0].name).toBe('HK-01')
    expect((result.config['proxy-groups'] as Record<string, unknown>[])[0].proxies).toEqual([
      'HK-01'
    ])
    expect(result.config['proxy-providers']).toBeUndefined()
  })

  it('includes inline proxies and every provider node for mihomo include-all groups', async () => {
    const result = await resolveProxyProviders(
      {
        proxies: [
          {
            name: 'Inline',
            type: 'ss',
            server: '192.0.2.1',
            port: 443,
            cipher: 'aes-128-gcm',
            password: 'inline'
          }
        ],
        'proxy-providers': {
          first: {
            type: 'inline',
            payload: [
              {
                name: 'Provider A',
                type: 'ss',
                server: '192.0.2.2',
                port: 443,
                cipher: 'aes-128-gcm',
                password: 'first'
              }
            ]
          },
          second: {
            type: 'inline',
            payload: [
              {
                name: 'Provider B',
                type: 'ss',
                server: '192.0.2.3',
                port: 443,
                cipher: 'aes-128-gcm',
                password: 'second'
              }
            ]
          }
        },
        'proxy-groups': [{ name: 'All', type: 'select', 'include-all': true }]
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )

    expect(result.errors).toEqual([])
    expect((result.config.proxies as Record<string, unknown>[]).map((proxy) => proxy.name)).toEqual(
      ['Inline', 'Provider A', 'Provider B']
    )
    expect(result.config['proxy-providers']).toBeUndefined()

    const converted = convertClashToSingbox(result.config)
    const group = (converted.config.outbounds as Record<string, unknown>[]).find(
      (outbound) => outbound.tag === 'All'
    )
    expect(converted.errors).toEqual([])
    expect(group?.outbounds).toEqual(['Inline', 'Provider A', 'Provider B'])
  })

  it('inherits supported provider overrides and preserves the converted tag and detour', async () => {
    const result = await resolveProxyProviders(
      {
        proxies: [
          {
            name: 'Upstream',
            type: 'ss',
            server: '192.0.2.1',
            port: 443,
            cipher: 'aes-128-gcm',
            password: 'upstream'
          }
        ],
        'proxy-providers': {
          airport: {
            type: 'inline',
            override: {
              'additional-prefix': 'Provider | ',
              'dialer-proxy': 'Upstream',
              'interface-name': 'Ethernet 2',
              tfo: true,
              mptcp: false,
              udp: true,
              'udp-over-tcp': true,
              down: '50 Mbps',
              up: '10 Mbps',
              'skip-cert-verify': true,
              'routing-mark': 233,
              'ip-version': 'ipv4-prefer',
              unsupported: 'must-not-leak'
            },
            payload: [
              {
                name: 'HK-01',
                type: 'ss',
                server: '192.0.2.2',
                port: 443,
                cipher: 'aes-128-gcm',
                password: 'provider',
                tfo: false,
                'interface-name': 'Wi-Fi'
              }
            ]
          }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )

    expect(result.errors).toEqual([])
    const providerProxy = (result.config.proxies as Record<string, unknown>[])[1]
    expect(providerProxy).toMatchObject({
      name: 'Provider | HK-01',
      'dialer-proxy': 'Upstream',
      'interface-name': 'Ethernet 2',
      tfo: true,
      mptcp: false,
      udp: true,
      'udp-over-tcp': true,
      down: '50 Mbps',
      up: '10 Mbps',
      'skip-cert-verify': true,
      'routing-mark': 233,
      'ip-version': 'ipv4-prefer'
    })
    expect(providerProxy).not.toHaveProperty('unsupported')

    const converted = convertClashToSingbox(result.config)
    expect(converted.errors).toEqual([])
    const outbound = (converted.config.outbounds as Record<string, unknown>[]).find(
      (candidate) => candidate.tag === 'Provider | HK-01'
    )
    expect(outbound).toMatchObject({
      tag: 'Provider | HK-01',
      detour: 'Upstream',
      bind_interface: 'Ethernet 2',
      tcp_fast_open: true,
      tcp_multi_path: false,
      udp_over_tcp: true,
      domain_strategy: 'prefer_ipv4'
    })
  })

  it('caches HTTP payloads and falls back to stale cache', async () => {
    const fetchText = vi
      .fn()
      .mockResolvedValueOnce(
        'proxies:\n  - { name: HK-01, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'
      )
      .mockRejectedValueOnce(new Error('offline'))
    const config = {
      'proxy-providers': {
        airport: { type: 'http', url: 'https://example.invalid/provider', interval: 0.001 }
      },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
    }
    const options = { baseDir: root, cacheDir: join(root, 'cache'), fetchText }

    const first = await resolveProxyProviders(config, options)
    expect(first.errors).toEqual([])
    await new Promise((resolve) => setTimeout(resolve, 5))
    const second = await resolveProxyProviders(config, options)

    expect(second.errors).toEqual([])
    expect(second.warnings.join('\n')).toMatch(/stale cached payload/)
    expect(fetchText).toHaveBeenCalledTimes(2)
  })

  it('fails closed when a referenced provider cannot be loaded', async () => {
    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          missing: { type: 'http', url: 'https://example.invalid/provider' }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['missing'] }]
      },
      {
        baseDir: root,
        cacheDir: join(root, 'cache'),
        fetchText: async () => {
          throw new Error('offline')
        }
      }
    )

    expect(result.errors.join('\n')).toMatch(/could not be loaded/)
  })

  it('uses ETag validators and keeps the cached payload on HTTP 304', async () => {
    const fetchText = vi
      .fn()
      .mockResolvedValueOnce({
        status: 200,
        data: 'proxies:\n  - { name: HK-01, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n',
        headers: { etag: '"provider-v1"', 'last-modified': 'Wed, 01 Jan 2025 00:00:00 GMT' }
      })
      .mockResolvedValueOnce({ status: 304, data: '', headers: {} })
    const config = {
      'proxy-providers': {
        airport: { type: 'http', url: 'https://example.invalid/provider', interval: 0.001 }
      },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
    }
    const options = { baseDir: root, cacheDir: join(root, 'cache'), fetchText }

    expect((await resolveProxyProviders(config, options)).errors).toEqual([])
    await new Promise((resolve) => setTimeout(resolve, 5))
    const second = await resolveProxyProviders(config, options)

    expect(second.errors).toEqual([])
    expect(fetchText.mock.calls[1][1]).toMatchObject({
      'If-None-Match': '"provider-v1"',
      'If-Modified-Since': 'Wed, 01 Jan 2025 00:00:00 GMT'
    })
    expect((second.config.proxies as Record<string, unknown>[])[0].name).toBe('HK-01')
  })

  it('coalesces concurrent cache misses into one provider request', async () => {
    let release!: (content: string) => void
    const pending = new Promise<string>((resolve) => {
      release = resolve
    })
    const fetchText = vi.fn(() => pending)
    const config = {
      'proxy-providers': {
        airport: { type: 'http', url: 'https://example.invalid/provider' }
      },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
    }
    const options = { baseDir: root, cacheDir: join(root, 'cache'), fetchText }
    const first = resolveProxyProviders(config, options)
    const second = resolveProxyProviders(config, options)
    await vi.waitFor(() => expect(fetchText).toHaveBeenCalledTimes(1))
    release(
      'proxies:\n  - { name: HK-01, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'
    )

    const results = await Promise.all([first, second])
    expect(results.every((result) => result.errors.length === 0)).toBe(true)
    expect(fetchText).toHaveBeenCalledTimes(1)
  })

  it('does not poison a good cache with an HTML response', async () => {
    const fetchText = vi
      .fn()
      .mockResolvedValueOnce(
        'proxies:\n  - { name: Good, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'
      )
      .mockResolvedValueOnce({
        status: 200,
        data: '<html>login required</html>',
        headers: { 'content-type': 'text/html' }
      })
    const config = {
      'proxy-providers': {
        airport: { type: 'http', url: 'https://example.invalid/provider', interval: 0.001 }
      },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
    }
    const options = { baseDir: root, cacheDir: join(root, 'cache'), fetchText }
    await resolveProxyProviders(config, options)
    await new Promise((resolve) => setTimeout(resolve, 5))
    const result = await resolveProxyProviders(config, options)

    expect(result.errors).toEqual([])
    expect(result.warnings.join('\n')).toMatch(/stale cached payload/)
    expect((result.config.proxies as Record<string, unknown>[])[0].name).toBe('Good')
  })

  it('isolates cache and validators by headers and profile request scope without leaking secrets', async () => {
    const fetchText = vi
      .fn()
      .mockResolvedValueOnce(
        'proxies:\n  - { name: First, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'
      )
      .mockResolvedValueOnce(
        'proxies:\n  - { name: Second, type: ss, server: 192.0.2.2, port: 443, cipher: aes-128-gcm, password: x }\n'
      )
    const makeConfig = (token: string) => ({
      'proxy-providers': {
        airport: {
          type: 'http',
          url: 'https://example.invalid/provider?secret=url-secret',
          headers: { Authorization: token }
        }
      },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
    })
    const cacheDir = join(root, 'cache')

    const first = await resolveProxyProviders(makeConfig('Bearer token-a'), {
      baseDir: root,
      cacheDir,
      fetchText,
      requestScope: 'profile-a'
    })
    const second = await resolveProxyProviders(makeConfig('Bearer token-b'), {
      baseDir: root,
      cacheDir,
      fetchText,
      requestScope: 'profile-b'
    })

    expect(fetchText).toHaveBeenCalledTimes(2)
    expect((first.config.proxies as Record<string, unknown>[])[0].name).toBe('First')
    expect((second.config.proxies as Record<string, unknown>[])[0].name).toBe('Second')
    const names = readdirSync(cacheDir)
    expect(names.filter((name) => name.endsWith('.yaml'))).toHaveLength(2)
    const metadata = names
      .filter((name) => name.endsWith('.http.json'))
      .map((name) => readFileSync(join(cacheDir, name), 'utf8'))
      .join('\n')
    expect(metadata).not.toContain('url-secret')
    expect(metadata).not.toContain('token-a')
    expect(metadata).not.toContain('token-b')
  })

  it('allows a validated provider cache to bootstrap proxy-only mode before the core is ready', async () => {
    const fetchText = vi
      .fn()
      .mockResolvedValue(
        'proxies:\n  - { name: Cached, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'
      )
    const config = {
      'proxy-providers': {
        airport: {
          type: 'http',
          url: 'https://example.invalid/provider',
          interval: 0.001
        }
      },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
    }
    const cacheDir = join(root, 'cache')
    await resolveProxyProviders(config, {
      baseDir: root,
      cacheDir,
      proxyPort: 17890,
      forceProxy: true,
      requestScope: 'profile-a',
      fetchText
    })
    await new Promise((resolve) => setTimeout(resolve, 5))

    const coldStart = await resolveProxyProviders(config, {
      baseDir: root,
      cacheDir,
      forceProxy: true,
      requestScope: 'profile-a',
      fetchText: vi.fn(() => {
        throw new Error('network must not be attempted without a healthy endpoint')
      })
    })

    expect(coldStart.errors).toEqual([])
    expect(coldStart.warnings.join('\n')).toMatch(/stale cached payload/)
    expect((coldStart.config.proxies as Record<string, unknown>[])[0].name).toBe('Cached')
  })

  it('rejects non-HTTP URLs and file paths that escape the profile directory', async () => {
    const baseDir = join(root, 'profile')
    mkdirSync(baseDir)
    writeFileSync(join(root, 'outside.yaml'), 'proxies: []')
    const makeConfig = (provider: Record<string, unknown>) => ({
      'proxy-providers': { unsafe: provider },
      'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['unsafe'] }]
    })

    const traversal = await resolveProxyProviders(
      makeConfig({ type: 'file', path: '..\\outside.yaml' }),
      { baseDir, cacheDir: join(root, 'cache'), allowFileProviders: true }
    )
    const scheme = await resolveProxyProviders(
      makeConfig({ type: 'http', url: 'file:///etc/passwd' }),
      { baseDir, cacheDir: join(root, 'cache') }
    )
    expect(traversal.errors.join('\n')).toMatch(/escapes/)
    expect(scheme.errors.join('\n')).toMatch(/http or https/)
  })

  it('rejects provider filters with catastrophic nested quantifiers', async () => {
    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          unsafe: {
            type: 'inline',
            filter: '^(a+)+$',
            payload: [
              {
                name: `${'a'.repeat(500)}!`,
                type: 'ss',
                server: '192.0.2.1',
                port: 443
              }
            ]
          }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['unsafe'] }]
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )
    expect(result.errors.join('\n')).toMatch(/unsafe or invalid filter.*nested/)
  })
})
