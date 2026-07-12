import { describe, expect, it } from 'vitest'
import { parse, stringify } from '../utils/yaml'
import { convertClashToSingbox } from '../core/singbox/convert'
import { normalizeSubscriptionPayload } from './subscriptionPayload'

function base64(value: string): string {
  return Buffer.from(value).toString('base64').replace(/=+$/, '')
}

describe('subscription payload normalization', () => {
  it('keeps valid Clash YAML unchanged', () => {
    const yaml =
      'proxies:\n  - { name: One, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'
    const normalized = normalizeSubscriptionPayload(yaml)
    const config = parse<Record<string, unknown>>(normalized.content)
    expect(normalized.format).toBe('clash-yaml')
    expect(config.rules).toEqual(['MATCH,Proxy'])
    expect((config['proxy-groups'] as Record<string, unknown>[])[0]).toMatchObject({
      name: 'Proxy',
      proxies: ['One']
    })
    expect((convertClashToSingbox(config).config.route as Record<string, unknown>).final).toBe(
      'Proxy'
    )
  })

  it('fails closed when every advertised Clash proxy is unsupported', () => {
    const normalized = normalizeSubscriptionPayload(
      'proxies:\n  - { name: Legacy, type: ssr, server: 192.0.2.1, port: 443 }\n'
    )
    const result = convertClashToSingbox(parse<Record<string, unknown>>(normalized.content))
    expect(result.errors.join('\n')).toMatch(/none are supported|not found/)
  })

  it('converts a Base64 URI list to Clash YAML with a usable group', () => {
    const vmess = `vmess://${base64(
      JSON.stringify({
        v: '2',
        ps: 'VMess HK',
        add: 'vmess.example',
        port: '443',
        id: '11111111-1111-1111-1111-111111111111',
        aid: '0',
        net: 'ws',
        host: 'cdn.example',
        path: '/ws',
        tls: 'tls',
        sni: 'vmess.example'
      })
    )}`
    const ss = `ss://${base64('aes-128-gcm:secret')}@ss.example:8388#SS%20HK`
    const vless =
      'vless://22222222-2222-2222-2222-222222222222@vless.example:443?security=reality&sni=www.example.com&fp=chrome&pbk=public&sid=abcd&type=grpc&serviceName=svc#VLESS%20HK'
    const result = normalizeSubscriptionPayload(base64([vmess, ss, vless].join('\n')))
    const config = parse<Record<string, unknown>>(result.content)
    const proxies = config.proxies as Record<string, unknown>[]

    expect(result.format).toBe('base64-uri-list')
    expect(result.proxyCount).toBe(3)
    expect(proxies.map((proxy) => proxy.type)).toEqual(['vmess', 'ss', 'vless'])
    expect((proxies[0]['ws-opts'] as Record<string, unknown>).path).toBe('/ws')
    expect(proxies[2]['reality-opts']).toEqual({ 'public-key': 'public', 'short-id': 'abcd' })
    expect((config['proxy-groups'] as Record<string, unknown>[])[0].proxies).toEqual([
      'VMess HK',
      'SS HK',
      'VLESS HK'
    ])
    expect(convertClashToSingbox(config).errors).toEqual([])
  })

  it('rejects HTML, arbitrary Base64, unsupported schemes and empty Clash configs', () => {
    expect(() => normalizeSubscriptionPayload('<html>login</html>')).toThrow(/neither Clash/)
    expect(() => normalizeSubscriptionPayload(base64('hello world'))).toThrow(/neither Clash/)
    expect(() => normalizeSubscriptionPayload(base64('ssr://abc'))).toThrow(/not supported/)
    expect(() => normalizeSubscriptionPayload('proxies: []\n')).toThrow(/no proxy nodes/)
    expect(() => normalizeSubscriptionPayload('proxies: invalid\n')).toThrow(/must be a list/)
  })

  it('rejects malformed URI fields with the original source line number', () => {
    expect(() =>
      normalizeSubscriptionPayload(
        '# generated subscription\n\n' +
          'vless://22222222-2222-2222-2222-222222222222@example.com:443?allowInsecure=maybe#Bad'
      )
    ).toThrow(/URI line 3: invalid boolean value/)
    const malformedDisplayName = normalizeSubscriptionPayload(
      'trojan://secret@example.com:443#broken%name'
    )
    expect(
      (
        parse<Record<string, unknown>>(malformedDisplayName.content).proxies as Record<
          string,
          unknown
        >[]
      )[0].name
    ).toBe('broken%name')
    expect(() =>
      normalizeSubscriptionPayload('tuic://bad%name:password@example.com:443#TUIC')
    ).toThrow(/URI line 1: invalid percent-encoding/)
  })

  it('validates every declared Clash root field before accepting another usable field', () => {
    expect(() =>
      normalizeSubscriptionPayload(
        'proxies: invalid\nproxy-providers:\n  remote:\n    type: http\n    url: https://example.invalid/sub\n'
      )
    ).toThrow(/"proxies" must be a list/)
    expect(() =>
      normalizeSubscriptionPayload('proxies:\n  - { name: One, type: ss }\nproxy-providers: []\n')
    ).toThrow(/"proxy-providers" must be a map/)
  })

  it('does not expose decoded VMess payload fragments in parse errors', () => {
    const secret = 'private-subscription-token'
    let failure: unknown
    try {
      normalizeSubscriptionPayload(`vmess://${base64(`${secret}-not-json`)}`)
    } catch (error) {
      failure = error
    }
    expect(failure).toBeInstanceOf(Error)
    expect((failure as Error).message).toContain('VMess URI contains invalid JSON')
    expect((failure as Error).message).not.toContain(secret.slice(0, 10))
  })

  it('accepts VMess fragments, boolean TLS flags and VLESS packet-encoding aliases', () => {
    const vmess = `vmess://${base64(
      JSON.stringify({
        add: 'vmess.example',
        port: 443,
        id: '11111111-1111-1111-1111-111111111111',
        net: 'ws',
        path: '/ws',
        tls: true,
        allowInsecure: true
      })
    )}#VMess%20Fragment`
    const vless =
      'vless://22222222-2222-2222-2222-222222222222@vless.example:443?packet-encoding=xudp#VLESS'
    const result = normalizeSubscriptionPayload(`${vmess}\n${vless}`)
    const proxies = parse<Record<string, unknown>>(result.content).proxies as Record<
      string,
      unknown
    >[]

    expect(proxies[0]).toMatchObject({
      name: 'VMess Fragment',
      tls: true,
      'skip-cert-verify': true
    })
    expect(proxies[1]['packet-encoding']).toBe('xudp')
    expect(convertClashToSingbox({ proxies }).errors).toEqual([])
  })

  it('rejects non-canonical Base64 instead of relying on permissive decoding', () => {
    expect(() => normalizeSubscriptionPayload('ZE==')).toThrow(/neither Clash/)
  })

  it('bounds remote node, provider, group, rule, and URI expansion', () => {
    const tooManyProviders = Object.fromEntries(
      Array.from({ length: 65 }, (_, index) => [`p${index}`, { type: 'inline', payload: [] }])
    )
    expect(() =>
      normalizeSubscriptionPayload(
        stringify({
          proxies: [{ name: 'One', type: 'ss' }],
          'proxy-providers': tooManyProviders
        })
      )
    ).toThrow(/64 proxy providers/)
    expect(() =>
      normalizeSubscriptionPayload(
        `ss://${Buffer.from('aes-128-gcm:secret').toString('base64url')}@example.com:443#${'x'.repeat(16_385)}`
      )
    ).toThrow(/16384 characters/)
  })

  it('recognizes additional common sing-box-compatible URI schemes', () => {
    const result = normalizeSubscriptionPayload(
      [
        'trojan://secret@trojan.example:443?sni=trojan.example#Trojan',
        'hy2://secret@hy2.example:443?sni=hy2.example#Hy2',
        'hysteria://hy.example:443?auth=secret&upmbps=10&downmbps=50&peer=hy.example#Hy1',
        'tuic://11111111-1111-1111-1111-111111111111:secret@tuic.example:443?sni=tuic.example#TUIC',
        'anytls://secret@anytls.example:443?sni=anytls.example#AnyTLS',
        'shadowtls://secret@shadowtls.example:443?version=3&sni=shadowtls.example#ShadowTLS',
        'http://user:pass@http.example:8080#HTTP',
        'socks5://user:pass@socks.example:1080#SOCKS'
      ].join('\n')
    )
    const config = parse<Record<string, unknown>>(result.content)
    expect((config.proxies as Record<string, unknown>[]).map((proxy) => proxy.type)).toEqual([
      'trojan',
      'hysteria2',
      'hysteria',
      'tuic',
      'anytls',
      'shadowtls',
      'http',
      'socks5'
    ])
    expect(convertClashToSingbox(config).errors).toEqual([])
  })
})
