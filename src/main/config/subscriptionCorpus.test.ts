import { readFileSync } from 'fs'
import { describe, expect, it } from 'vitest'
import { parse, stringify } from '../utils/yaml'
import { convertClashToSingbox } from '../core/singbox/convert'
import { resolveProxyProviders } from '../core/singbox/providerResolver'
import corpus from './fixtures/subscription-uri-corpus.json'
import { normalizeSubscriptionPayload } from './subscriptionPayload'

type Dict = Record<string, unknown>

function parseNormalized(payload: string): Dict {
  return parse<Dict>(normalizeSubscriptionPayload(payload).content)
}

describe('offline subscription compatibility corpus', () => {
  it('normalizes and converts representative URI protocols without dropping a node', () => {
    const payload = [
      '# offline compatibility corpus',
      '',
      ...corpus.valid.map((item) => item.uri)
    ].join('\n')
    const first = normalizeSubscriptionPayload(payload)
    const clash = parse<Dict>(first.content)
    const proxies = clash.proxies as Dict[]
    const converted = convertClashToSingbox(clash)

    expect(first.format).toBe('uri-list')
    expect(first.proxyCount).toBe(corpus.valid.length)
    expect(proxies.map((proxy) => proxy.type)).toEqual(corpus.valid.map((item) => item.type))
    expect(new Set(proxies.map((proxy) => proxy.name)).size).toBe(proxies.length)
    expect(proxies.map((proxy) => proxy.name).filter((name) => name === 'Shared')).toHaveLength(1)
    expect(proxies.map((proxy) => proxy.name)).toEqual(
      expect.arrayContaining(['Shared', 'Shared 2', 'Shared 3'])
    )
    expect(proxies[1]).toMatchObject({
      cipher: '2022-blake3-aes-128-gcm',
      password: 'MTIzNDU2Nzg5MDEyMzQ1Ng=='
    })
    expect(proxies[2]).toMatchObject({
      network: 'ws',
      'ws-opts': { path: '/socket', headers: { Host: 'cdn.example' } },
      tls: true
    })
    expect(proxies[3]).toMatchObject({ network: 'ws', tls: true })
    expect(proxies[4]).toMatchObject({
      network: 'grpc',
      'reality-opts': { 'public-key': 'public-key', 'short-id': 'abcd' }
    })
    expect(proxies[5]).toMatchObject({ obfs: 'salamander', 'obfs-password': 'cover' })
    expect(proxies[6]).toMatchObject({
      uuid: '33333333-3333-3333-3333-333333333333',
      password: 'secret'
    })
    expect(proxies[7]).toMatchObject({ version: 3, password: 'secret' })
    expect(converted.errors).toEqual([])
    expect(converted.warnings).toEqual([])
    const convertedTags = [
      ...((converted.config.outbounds as Dict[]) || []),
      ...((converted.config.endpoints as Dict[]) || [])
    ].map((entry) => entry.tag)
    for (const proxy of proxies) expect(convertedTags).toContain(proxy.name)
    const convertedByTag = new Map(
      ((converted.config.outbounds as Dict[]) || []).map((entry) => [entry.tag, entry])
    )
    expect(proxies.map((proxy) => convertedByTag.get(proxy.name)?.type)).toEqual([
      'shadowsocks',
      'shadowsocks',
      'trojan',
      'vmess',
      'vless',
      'hysteria2',
      'tuic',
      'shadowtls',
      'shadowsocks',
      'http',
      'http'
    ])
    expect(convertedByTag.get(proxies[3].name)).toMatchObject({
      type: 'vmess',
      tls: { enabled: true, server_name: 'vmess.example' },
      transport: {
        type: 'ws',
        path: '/ws',
        headers: { Host: 'cdn.example' }
      }
    })
    expect(convertedByTag.get(proxies[4].name)).toMatchObject({
      type: 'vless',
      tls: {
        enabled: true,
        server_name: 'www.example.com',
        utls: { enabled: true, fingerprint: 'chrome' },
        reality: { enabled: true, public_key: 'public-key', short_id: 'abcd' }
      },
      transport: { type: 'grpc', service_name: 'edge' }
    })
    expect(convertedByTag.get(proxies[5].name)).toMatchObject({
      type: 'hysteria2',
      password: 'secret',
      obfs: { type: 'salamander', password: 'cover' },
      tls: { enabled: true, server_name: 'hy2.example', alpn: ['h3'] }
    })
    expect(convertedByTag.get(proxies[6].name)).toMatchObject({
      type: 'tuic',
      uuid: '33333333-3333-3333-3333-333333333333',
      password: 'secret',
      congestion_control: 'bbr',
      udp_relay_mode: 'native',
      tls: { enabled: true, server_name: 'tuic.example', alpn: ['h3'] }
    })
    expect(convertedByTag.get(proxies[7].name)).toMatchObject({
      type: 'shadowtls',
      version: 3,
      password: 'secret',
      tls: { enabled: true, server_name: 'www.example.com' }
    })

    const second = normalizeSubscriptionPayload(first.content)
    expect(second.format).toBe('clash-yaml')
    expect(parse<Dict>(second.content)).toEqual(clash)
  })

  it('accepts standard and URL-safe Base64 wrappers with comments in the decoded list', () => {
    const decoded = ['# provider comment', corpus.valid[0].uri, '', corpus.valid[4].uri].join('\n')
    const standard = Buffer.from(decoded).toString('base64')
    const urlSafe = Buffer.from(decoded).toString('base64url')

    for (const encoded of [standard, urlSafe]) {
      const normalized = normalizeSubscriptionPayload(encoded)
      expect(normalized.format).toBe('base64-uri-list')
      expect(normalized.proxyCount).toBe(2)
      const converted = convertClashToSingbox(parse<Dict>(normalized.content))
      expect(converted.errors).toEqual([])
      expect(converted.warnings).toEqual([])
    }
  })

  it.each(corpus.invalid)('rejects malformed corpus case $id at the parser boundary', (item) => {
    expect(() => normalizeSubscriptionPayload(item.payload)).toThrow(item.error)
  })

  it('resolves inline Clash providers and converts groups, WireGuard, SS2022 and ShadowTLS', async () => {
    const payload = readFileSync(
      new URL('./fixtures/subscription-clash-provider.yaml', import.meta.url),
      'utf8'
    )
    const normalized = normalizeSubscriptionPayload(payload)
    const resolved = await resolveProxyProviders(parse<Dict>(normalized.content), {
      baseDir: '.',
      cacheDir: '.'
    })
    const converted = convertClashToSingbox(resolved.config)
    const proxies = resolved.config.proxies as Dict[]
    const outbounds = converted.config.outbounds as Dict[]
    const endpoints = converted.config.endpoints as Dict[]

    expect(normalized.format).toBe('clash-yaml')
    expect(resolved.errors).toEqual([])
    expect(resolved.warnings).toEqual([])
    expect(proxies.map((proxy) => proxy.name)).toEqual([
      'Shared',
      'Direct SS2022',
      'Provider HK',
      'Provider SG'
    ])
    expect(endpoints).toEqual(
      expect.arrayContaining([expect.objectContaining({ tag: 'Shared', type: 'wireguard' })])
    )
    expect(outbounds).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          tag: 'Direct SS2022',
          type: 'shadowsocks',
          method: '2022-blake3-aes-128-gcm'
        }),
        expect.objectContaining({ tag: 'Provider SG', type: 'shadowtls', version: 3 }),
        expect.objectContaining({
          tag: 'Auto',
          type: 'urltest',
          outbounds: ['Shared', 'Provider HK', 'Provider SG']
        })
      ])
    )
    expect(converted.errors).toEqual([])
    expect(converted.warnings).toEqual([])
    expect(outbounds.find((outbound) => outbound.tag === 'Provider SG')).toMatchObject({
      type: 'shadowtls',
      version: 3,
      password: 'secret',
      tls: { enabled: true, server_name: 'www.example.com' }
    })
  })

  it('enforces node, group, rule and port boundaries deterministically', () => {
    const validPorts = parseNormalized(
      ['trojan://secret@one.example:1#Min', 'trojan://secret@two.example:65535#Max'].join('\n')
    ).proxies as Dict[]
    expect(validPorts.map((proxy) => proxy.port)).toEqual([1, 65535])

    const uri = corpus.valid[0].uri
    expect(() => normalizeSubscriptionPayload(Array(10_001).fill(uri).join('\n'))).toThrow(
      /10000 proxy nodes/
    )
    expect(() =>
      normalizeSubscriptionPayload(
        stringify({
          proxies: [{ name: 'One', type: 'ss' }],
          'proxy-groups': Array.from({ length: 513 }, (_, index) => ({
            name: `G${index}`,
            type: 'select',
            proxies: ['One']
          }))
        })
      )
    ).toThrow(/512 proxy groups/)
    expect(() =>
      normalizeSubscriptionPayload(
        stringify({
          proxies: [{ name: 'One', type: 'ss' }],
          rules: Array(50_001).fill('MATCH,One')
        })
      )
    ).toThrow(/50000 rules/)
  })
})
