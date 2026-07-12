import { describe, expect, it } from 'vitest'
import { convertClashToSingbox, deriveController } from './convert'

type Dict = Record<string, unknown>

function outbound(config: Dict, tag: string): Dict {
  const list = (config.outbounds as Dict[]) || []
  const found = list.find((o) => o.tag === tag)
  expect(found, `outbound "${tag}" should exist`).toBeDefined()
  return found as Dict
}

function endpoint(config: Dict, tag: string): Dict {
  const list = (config.endpoints as Dict[]) || []
  const found = list.find((o) => o.tag === tag)
  expect(found, `endpoint "${tag}" should exist`).toBeDefined()
  return found as Dict
}

function routeRules(config: Dict): Dict[] {
  return ((config.route as Dict).rules as Dict[]) || []
}

function base(extra: Dict = {}): Dict {
  return {
    'mixed-port': 7890,
    'log-level': 'info',
    mode: 'rule',
    ipv6: true,
    'external-controller': '127.0.0.1:9097',
    secret: 'test-secret',
    proxies: [],
    'proxy-groups': [],
    rules: [],
    ...extra
  }
}

describe('empty profile', () => {
  it('produces a valid startable config', () => {
    const { config, warnings, errors } = convertClashToSingbox({})
    expect(Array.isArray(config.outbounds)).toBe(true)
    // direct + GLOBAL always exist
    expect(outbound(config, 'direct').type).toBe('direct')
    expect(outbound(config, 'GLOBAL').type).toBe('selector')
    expect((outbound(config, 'GLOBAL').outbounds as string[]).length).toBeGreaterThan(0)
    // dns always has a local server so proxies-by-domain can resolve
    const dns = config.dns as Dict
    expect((dns.servers as Dict[]).some((s) => s.type === 'local')).toBe(true)
    // route final falls back to direct
    expect((config.route as Dict).final).toBe('direct')
    // controller defaults applied
    const clashApi = ((config.experimental as Dict).clash_api as Dict) || {}
    expect(clashApi.external_controller).toBe('127.0.0.1:9090')
    expect(warnings).toBeInstanceOf(Array)
    expect(errors).toEqual([])
  })
})

describe('clash_api / cache_file', () => {
  it('maps external-controller, secret, default mode and store_fakeip', () => {
    const { config, controller } = convertClashToSingbox(
      base({ mode: 'global', profile: { 'store-fake-ip': true } })
    )
    const experimental = config.experimental as Dict
    const clashApi = experimental.clash_api as Dict
    expect(clashApi.external_controller).toBe('127.0.0.1:9097')
    expect(clashApi.secret).toBe('test-secret')
    expect(clashApi.default_mode).toBe('Global')
    const cache = experimental.cache_file as Dict
    expect(cache.enabled).toBe(true)
    expect(cache.store_fakeip).toBe(true)
    expect(controller.port).toBe(9097)
    expect(controller.host).toBe('127.0.0.1')
    expect(controller.secret).toBe('test-secret')
  })

  it('uses a generated controller secret when the profile has none', () => {
    const { config, controller } = convertClashToSingbox(base({ secret: '' }), {
      controllerSecret: 'generated-secret'
    })
    const clashApi = (config.experimental as Dict).clash_api as Dict
    expect(controller.secret).toBe('generated-secret')
    expect(clashApi.secret).toBe('generated-secret')
  })

  it('restricts wildcard controller addresses to loopback', () => {
    const controller = deriveController({ 'external-controller': '0.0.0.0:9091', secret: 's' })
    expect(controller.listen).toBe('127.0.0.1:9091')
    expect(controller.host).toBe('127.0.0.1')
  })

  it('warns when a public controller address is restricted', () => {
    const result = convertClashToSingbox(base({ 'external-controller': '0.0.0.0:9091' }))
    expect(result.warnings).toContain(
      'external-controller was restricted to 127.0.0.1 for desktop security'
    )
  })

  it('defaults when empty', () => {
    const controller = deriveController({})
    expect(controller.listen).toBe('127.0.0.1:9090')
    expect(controller.port).toBe(9090)
  })
})

describe('log level', () => {
  it('maps warning -> warn and silent -> fatal', () => {
    expect((convertClashToSingbox(base({ 'log-level': 'warning' })).config.log as Dict).level).toBe(
      'warn'
    )
    expect((convertClashToSingbox(base({ 'log-level': 'silent' })).config.log as Dict).level).toBe(
      'fatal'
    )
    expect((convertClashToSingbox(base({ 'log-level': 'debug' })).config.log as Dict).level).toBe(
      'debug'
    )
  })
})

describe('inbounds', () => {
  it('creates mixed/socks/http inbounds from ports', () => {
    const { config } = convertClashToSingbox(
      base({ 'mixed-port': 7890, 'socks-port': 7891, port: 7892 })
    )
    const inbounds = config.inbounds as Dict[]
    const mixed = inbounds.find((i) => i.type === 'mixed') as Dict
    expect(mixed.listen_port).toBe(7890)
    expect(mixed.listen).toBe('127.0.0.1')
    expect(inbounds.find((i) => i.type === 'socks')).toBeDefined()
    expect(inbounds.find((i) => i.type === 'http')).toBeDefined()
  })

  it('skips zero ports and honors allow-lan', () => {
    const { config } = convertClashToSingbox(
      base({ 'mixed-port': 7890, 'socks-port': 0, 'allow-lan': true, ipv6: false })
    )
    const inbounds = config.inbounds as Dict[]
    expect(inbounds.find((i) => i.type === 'socks')).toBeUndefined()
    expect((inbounds.find((i) => i.type === 'mixed') as Dict).listen).toBe('0.0.0.0')
  })

  it('maps authentication users onto listeners', () => {
    const { config } = convertClashToSingbox(base({ authentication: ['user:pass'] }))
    const mixed = (config.inbounds as Dict[]).find((i) => i.type === 'mixed') as Dict
    expect(mixed.users).toEqual([{ username: 'user', password: 'pass' }])
  })

  it('creates a tun inbound with mapped settings', () => {
    const { config } = convertClashToSingbox(
      base({
        tun: {
          enable: true,
          stack: 'mixed',
          device: 'AikoBox',
          mtu: 9000,
          'auto-route': true,
          'strict-route': true,
          'route-exclude-address': ['192.168.0.0/16']
        }
      })
    )
    const tun = (config.inbounds as Dict[]).find((i) => i.type === 'tun') as Dict
    expect(tun).toBeDefined()
    expect(tun.interface_name).toBe('AikoBox')
    expect(tun.stack).toBe('mixed')
    expect(tun.mtu).toBe(9000)
    expect(tun.auto_route).toBe(true)
    expect(tun.strict_route).toBe(true)
    expect(tun.route_exclude_address).toEqual(['192.168.0.0/16'])
    expect(tun.address).toEqual(['198.19.0.1/30', 'fdfe:dcba:9876::1/126'])
    expect(tun.address).not.toContain('172.19.0.1/30')
  })

  it('honors modern and legacy TUN addresses without duplicates', () => {
    const { config } = convertClashToSingbox(
      base({
        tun: {
          enable: true,
          address: ['10.77.0.1/30', 'fd00:77::1/126'],
          'inet4-address': ['10.78.0.1/30', '10.77.0.1/30'],
          'inet6-address': 'fd00:78::1/126'
        }
      })
    )
    const tun = (config.inbounds as Dict[]).find((i) => i.type === 'tun') as Dict

    expect(tun.address).toEqual([
      '10.77.0.1/30',
      'fd00:77::1/126',
      '10.78.0.1/30',
      'fd00:78::1/126'
    ])
  })

  it('uses legacy family overrides and drops configured TUN IPv6 when top-level IPv6 is disabled', () => {
    const { config, warnings } = convertClashToSingbox(
      base({
        ipv6: false,
        tun: {
          enable: true,
          'inet4-address': '10.88.0.1/30',
          'inet6-address': 'fd00:88::1/126'
        }
      })
    )
    const tun = (config.inbounds as Dict[]).find((i) => i.type === 'tun') as Dict

    expect(tun.address).toEqual(['10.88.0.1/30'])
    expect(warnings.join('\n')).toMatch(/TUN IPv6 address ignored/i)
  })

  it('maps tun.auto-detect-interface to sing-box route settings', () => {
    const disabled = convertClashToSingbox(
      base({ tun: { enable: true, 'auto-detect-interface': false } })
    ).config
    const enabled = convertClashToSingbox(
      base({ tun: { enable: true, 'auto-detect-interface': true } })
    ).config
    const legacyTopLevel = convertClashToSingbox(
      base({ 'auto-detect-interface': false, tun: { enable: true } })
    ).config

    expect((disabled.route as Dict).auto_detect_interface).toBe(false)
    expect((enabled.route as Dict).auto_detect_interface).toBe(true)
    expect((legacyTopLevel.route as Dict).auto_detect_interface).toBe(false)
  })

  it('drops redir/tproxy ports on unsupported platforms with a warning', () => {
    const { config, warnings } = convertClashToSingbox(
      base({ 'redir-port': 1234, 'tproxy-port': 1235 }),
      { platform: 'win32' }
    )
    const inbounds = config.inbounds as Dict[]
    expect(inbounds.find((i) => i.type === 'redirect')).toBeUndefined()
    expect(inbounds.find((i) => i.type === 'tproxy')).toBeUndefined()
    expect(warnings.join('\n')).toMatch(/redir-port/)
  })
})

describe('dns', () => {
  it('fake-ip mode creates a fakeip server, filter rules and query_type rule', () => {
    const { config } = convertClashToSingbox(
      base({
        dns: {
          enable: true,
          ipv6: false,
          'enhanced-mode': 'fake-ip',
          'fake-ip-range': '198.18.0.1/16',
          'fake-ip-filter': ['+.lan', 'time.windows.com'],
          nameserver: ['https://doh.pub/dns-query', 'tls://223.5.5.5']
        }
      })
    )
    const dns = config.dns as Dict
    const servers = dns.servers as Dict[]
    const fakeip = servers.find((s) => s.type === 'fakeip') as Dict
    expect(fakeip.inet4_range).toBe('198.18.0.1/16')
    expect(servers.find((s) => s.type === 'https')).toMatchObject({ server: 'doh.pub' })
    expect(servers.find((s) => s.type === 'tls')).toMatchObject({ server: '223.5.5.5' })
    const rules = dns.rules as Dict[]
    // filter rule resolves real IPs before the fakeip catch-all
    const filterRule = rules.find((r) => (r.domain_suffix as string[])?.includes('.lan')) as Dict
    expect(filterRule.server).not.toBe('dns-fakeip')
    const last = rules[rules.length - 1]
    expect(last.server).toBe('dns-fakeip')
    expect(last.query_type).toEqual(['A'])
    expect(fakeip.inet6_range).toBeUndefined()
    expect(dns.strategy).toBe('ipv4_only')
    expect(dns.independent_cache).toBe(true)
  })

  it('redir-host mode has no fakeip server', () => {
    const { config } = convertClashToSingbox(
      base({
        dns: { enable: true, 'enhanced-mode': 'redir-host', nameserver: ['223.5.5.5'] }
      })
    )
    const servers = (config.dns as Dict).servers as Dict[]
    expect(servers.find((s) => s.type === 'fakeip')).toBeUndefined()
    expect(servers.find((s) => s.type === 'udp')).toMatchObject({ server: '223.5.5.5' })
  })

  it('respects the ipv6 flag with ipv4_only strategy', () => {
    const { config } = convertClashToSingbox(base({ ipv6: false }))
    expect((config.dns as Dict).strategy).toBe('ipv4_only')
    const { config: v6 } = convertClashToSingbox(base({ ipv6: true }))
    expect((v6.dns as Dict).strategy).toBeUndefined()
  })

  it('lets dns.ipv6 disable AAAA even when top-level IPv6 remains enabled', () => {
    const { config } = convertClashToSingbox(
      base({
        ipv6: true,
        dns: { enable: true, ipv6: false, 'enhanced-mode': 'fake-ip' }
      })
    )
    const dns = config.dns as Dict
    const fakeip = (dns.servers as Dict[]).find((server) => server.type === 'fakeip') as Dict
    const fakeipRule = (dns.rules as Dict[]).find((rule) => rule.server === 'dns-fakeip') as Dict

    expect(dns.strategy).toBe('ipv4_only')
    expect(fakeip.inet6_range).toBeUndefined()
    expect(fakeipRule.query_type).toEqual(['A'])
  })

  it('maps hosts and bootstrap/proxy/direct DNS resolvers', () => {
    const { config, warnings } = convertClashToSingbox(
      base({
        hosts: { 'router.lan': '192.168.1.1', 'nas.lan': ['192.168.1.2', 'fd00::2'] },
        dns: {
          enable: true,
          nameserver: ['https://dns.example.com/dns-query'],
          'default-nameserver': ['1.1.1.1'],
          'proxy-server-nameserver': ['9.9.9.9'],
          'direct-nameserver': ['223.5.5.5']
        }
      })
    )
    const dns = config.dns as Dict
    const servers = dns.servers as Dict[]
    const hosts = servers.find((server) => server.type === 'hosts') as Dict
    expect(hosts.predefined).toMatchObject({ 'router.lan': '192.168.1.1' })
    expect((dns.rules as Dict[])[0]).toMatchObject({ ip_accept_any: true, server: 'dns-hosts' })
    expect((config.route as Dict).default_domain_resolver).toEqual({ server: 'dns-proxy-server-0' })
    expect(servers.find((server) => server.tag === 'dns-0')?.domain_resolver).toBe(
      'dns-bootstrap-0'
    )
    expect(warnings.join('\n')).not.toMatch(/hosts mapping/)
  })
})

describe('proxies', () => {
  it('maps shadowsocks with obfs plugin', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'ss1',
            type: 'ss',
            server: '1.2.3.4',
            port: 8388,
            cipher: 'aes-256-gcm',
            password: 'pw',
            plugin: 'obfs',
            'plugin-opts': { mode: 'http', host: 'bing.com' }
          }
        ]
      })
    )
    const ss = outbound(config, 'ss1')
    expect(ss).toMatchObject({
      type: 'shadowsocks',
      server: '1.2.3.4',
      server_port: 8388,
      method: 'aes-256-gcm',
      password: 'pw',
      plugin: 'obfs-local',
      plugin_opts: 'obfs=http;obfs-host=bing.com'
    })
  })

  it('maps shadowsocks with v2ray-plugin', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'ss2',
            type: 'ss',
            server: 'a.com',
            port: 443,
            cipher: 'chacha20-ietf-poly1305',
            password: 'pw',
            plugin: 'v2ray-plugin',
            'plugin-opts': { mode: 'websocket', tls: true, host: 'a.com', path: '/ws' }
          }
        ]
      })
    )
    const ss = outbound(config, 'ss2')
    expect(ss.plugin).toBe('v2ray-plugin')
    expect(ss.plugin_opts).toContain('mode=websocket')
    expect(ss.plugin_opts).toContain('tls')
    expect(ss.plugin_opts).toContain('host=a.com')
  })

  it('maps vmess with ws transport', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'vm1',
            type: 'vmess',
            server: 'vm.com',
            port: 443,
            uuid: 'uuid-1',
            alterId: 0,
            cipher: 'auto',
            tls: true,
            servername: 'sni.com',
            network: 'ws',
            'packet-encoding': 'packetaddr',
            'interface-name': 'Ethernet',
            tfo: true,
            'ip-version': 'ipv4-prefer',
            'ws-opts': { path: '/path', headers: { Host: 'ws.com' } }
          }
        ]
      })
    )
    const vm = outbound(config, 'vm1')
    expect(vm).toMatchObject({ type: 'vmess', uuid: 'uuid-1', security: 'auto', alter_id: 0 })
    expect(vm.transport).toMatchObject({ type: 'ws', path: '/path', headers: { Host: 'ws.com' } })
    expect(vm.tls).toMatchObject({ enabled: true, server_name: 'sni.com' })
    expect(vm).toMatchObject({
      packet_encoding: 'packetaddr',
      bind_interface: 'Ethernet',
      tcp_fast_open: true,
      domain_strategy: 'prefer_ipv4'
    })
  })

  it('preserves Clash HTTP transport hosts', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'vm-http',
            type: 'vmess',
            server: 'vm.example',
            port: 443,
            uuid: 'uuid-http',
            cipher: 'auto',
            network: 'http',
            'http-opts': {
              host: ['front-one.example', 'front-two.example'],
              path: ['/tunnel']
            }
          }
        ]
      })
    )

    expect(outbound(config, 'vm-http').transport).toMatchObject({
      type: 'http',
      host: ['front-one.example', 'front-two.example'],
      path: '/tunnel'
    })
  })

  it('maps vless with reality, vision flow, uTLS and grpc transport', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'vl1',
            type: 'vless',
            server: 'vl.com',
            port: 443,
            uuid: 'uuid-2',
            flow: 'xtls-rprx-vision',
            tls: true,
            servername: 'real.com',
            'client-fingerprint': 'chrome',
            'reality-opts': { 'public-key': 'pbk', 'short-id': 'sid' },
            network: 'grpc',
            'grpc-opts': { 'grpc-service-name': 'svc' }
          }
        ]
      })
    )
    const vl = outbound(config, 'vl1')
    expect(vl.flow).toBe('xtls-rprx-vision')
    const tls = vl.tls as Dict
    expect(tls.reality).toMatchObject({ enabled: true, public_key: 'pbk', short_id: 'sid' })
    expect(tls.utls).toMatchObject({ enabled: true, fingerprint: 'chrome' })
    expect(vl.transport).toMatchObject({ type: 'grpc', service_name: 'svc' })
  })

  it('maps trojan with implicit tls', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'tj1',
            type: 'trojan',
            server: 'tj.com',
            port: 443,
            password: 'pw',
            sni: 'sni.tj.com',
            'skip-cert-verify': true
          }
        ]
      })
    )
    const tj = outbound(config, 'tj1')
    expect(tj.type).toBe('trojan')
    expect(tj.tls).toMatchObject({ enabled: true, server_name: 'sni.tj.com', insecure: true })
  })

  it('maps hysteria2 with salamander obfs and bandwidth', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'hy2',
            type: 'hysteria2',
            server: 'hy.com',
            port: 443,
            password: 'pw',
            up: '30 Mbps',
            down: 200,
            obfs: 'salamander',
            'obfs-password': 'ob',
            sni: 'hy.com'
          }
        ]
      })
    )
    const hy = outbound(config, 'hy2')
    expect(hy).toMatchObject({ type: 'hysteria2', password: 'pw', up_mbps: 30, down_mbps: 200 })
    expect(hy.obfs).toMatchObject({ type: 'salamander', password: 'ob' })
  })

  it('maps hysteria v1, SSH and Hysteria2 port hopping/bandwidth units', () => {
    const { config, errors } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'hy1',
            type: 'hysteria',
            server: 'hy.example.com',
            ports: '20000-30000',
            'hop-interval': 20,
            up: '1 Gbps',
            down: '100 Mbps',
            'auth-str': 'secret',
            sni: 'hy.example.com'
          },
          {
            name: 'hy2-hop',
            type: 'hysteria2',
            server: 'hy2.example.com',
            ports: ['40000-40100'],
            'hop-interval': 15,
            up: '1 Gbps',
            down: '2 GBps',
            password: 'secret',
            sni: 'hy2.example.com'
          },
          {
            name: 'ssh1',
            type: 'ssh',
            server: 'ssh.example.com',
            port: 22,
            username: 'alice',
            password: 'secret',
            'host-key': ['ssh-ed25519 AAAAfixture']
          }
        ]
      })
    )

    expect(outbound(config, 'hy1')).toMatchObject({
      type: 'hysteria',
      server_ports: ['20000:30000'],
      hop_interval: '20s',
      up: '1 Gbps',
      auth_str: 'secret'
    })
    expect(outbound(config, 'hy2-hop')).toMatchObject({
      type: 'hysteria2',
      server_ports: ['40000:40100'],
      hop_interval: '15s',
      up_mbps: 1000,
      down_mbps: 16000
    })
    expect(outbound(config, 'ssh1')).toMatchObject({
      type: 'ssh',
      user: 'alice',
      password: 'secret'
    })
    expect(errors).toEqual([])
  })

  it('maps tuic v5', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'tu1',
            type: 'tuic',
            server: 'tu.com',
            port: 443,
            uuid: 'uuid-3',
            password: 'pw',
            'congestion-controller': 'bbr',
            'udp-relay-mode': 'native',
            'reduce-rtt': true
          }
        ]
      })
    )
    const tu = outbound(config, 'tu1')
    expect(tu).toMatchObject({
      type: 'tuic',
      uuid: 'uuid-3',
      password: 'pw',
      congestion_control: 'bbr',
      udp_relay_mode: 'native',
      zero_rtt_handshake: true
    })
    expect((tu.tls as Dict).alpn).toEqual(['h3'])
  })

  it('maps wireguard to an endpoint', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'wg1',
            type: 'wireguard',
            server: 'wg.com',
            port: 51820,
            ip: '172.16.0.2',
            'private-key': 'priv',
            'public-key': 'pub',
            reserved: [1, 2, 3]
          }
        ]
      })
    )
    const wg = endpoint(config, 'wg1')
    expect(wg.type).toBe('wireguard')
    expect(wg.address).toEqual(['172.16.0.2/32'])
    expect(wg.private_key).toBe('priv')
    const peer = (wg.peers as Dict[])[0]
    expect(peer).toMatchObject({ address: 'wg.com', port: 51820, public_key: 'pub' })
    expect(peer.reserved).toEqual([1, 2, 3])
    // endpoints are selectable in GLOBAL
    expect(outbound(config, 'GLOBAL').outbounds as string[]).toContain('wg1')
  })

  it('maps http and socks5', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          { name: 'h1', type: 'http', server: 'h.com', port: 8080, username: 'u', password: 'p' },
          { name: 's1', type: 'socks5', server: 's.com', port: 1080 }
        ]
      })
    )
    expect(outbound(config, 'h1')).toMatchObject({
      type: 'http',
      server: 'h.com',
      server_port: 8080
    })
    expect(outbound(config, 's1')).toMatchObject({ type: 'socks', version: '5', server: 's.com' })
  })

  it('maps anytls', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          {
            name: 'at1',
            type: 'anytls',
            server: 'at.com',
            port: 443,
            password: 'pw',
            sni: 'at.com',
            'idle-session-check-interval': '20s',
            'idle-session-timeout': '40s',
            'min-idle-session': 2
          }
        ]
      })
    )
    const at = outbound(config, 'at1')
    expect(at.type).toBe('anytls')
    expect(at.tls).toMatchObject({ enabled: true, server_name: 'at.com' })
    expect(at).toMatchObject({
      idle_session_check_interval: '20s',
      idle_session_timeout: '40s',
      min_idle_session: 2
    })
  })

  it('skips unsupported proxy types with a warning, never crashes', () => {
    const { config, warnings } = convertClashToSingbox(
      base({
        proxies: [
          { name: 'ssr1', type: 'ssr', server: 'x', port: 1 },
          { name: 'ok', type: 'ss', server: 'y', port: 2, cipher: 'aes-128-gcm', password: 'p' }
        ]
      })
    )
    expect((config.outbounds as Dict[]).find((o) => o.tag === 'ssr1')).toBeUndefined()
    expect(outbound(config, 'ok')).toBeDefined()
    expect(warnings.join('\n')).toMatch(/ssr1/)
  })
})

describe('proxy groups', () => {
  const proxies = [
    { name: 'p1', type: 'ss', server: 'a', port: 1, cipher: 'aes-128-gcm', password: 'x' },
    { name: 'p2', type: 'ss', server: 'b', port: 2, cipher: 'aes-128-gcm', password: 'x' },
    { name: 'HK-1', type: 'ss', server: 'c', port: 3, cipher: 'aes-128-gcm', password: 'x' }
  ]

  it('maps select -> selector and url-test -> urltest with interval/tolerance', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies,
        'proxy-groups': [
          { name: 'Choose', type: 'select', proxies: ['Auto', 'p1', 'p2', 'DIRECT'] },
          {
            name: 'Auto',
            type: 'url-test',
            proxies: ['p1', 'p2'],
            url: 'http://test/204',
            interval: 300,
            tolerance: 50
          }
        ]
      })
    )
    const select = outbound(config, 'Choose')
    expect(select.type).toBe('selector')
    expect(select.outbounds).toEqual(['Auto', 'p1', 'p2', 'direct'])
    const auto = outbound(config, 'Auto')
    expect(auto).toMatchObject({
      type: 'urltest',
      url: 'http://test/204',
      interval: '300s',
      tolerance: 50
    })
  })

  it('approximates fallback and load-balance with urltest and warns', () => {
    const { config, warnings } = convertClashToSingbox(
      base({
        proxies,
        'proxy-groups': [
          { name: 'FB', type: 'fallback', proxies: ['p1', 'p2'], interval: 60 },
          { name: 'LB', type: 'load-balance', proxies: ['p1', 'p2'] }
        ]
      })
    )
    expect(outbound(config, 'FB').type).toBe('urltest')
    expect(outbound(config, 'LB').type).toBe('urltest')
    expect(warnings.join('\n')).toMatch(/fallback approximated/)
    expect(warnings.join('\n')).toMatch(/load-balance approximated/)
  })

  it('skips relay groups with warning and removes dangling references', () => {
    const { config, warnings } = convertClashToSingbox(
      base({
        proxies,
        'proxy-groups': [
          { name: 'Chain', type: 'relay', proxies: ['p1', 'p2'] },
          { name: 'Pick', type: 'select', proxies: ['Chain', 'p1'] }
        ]
      })
    )
    expect((config.outbounds as Dict[]).find((o) => o.tag === 'Chain')).toBeUndefined()
    expect(outbound(config, 'Pick').outbounds).toEqual(['p1'])
    expect(warnings.join('\n')).toMatch(/relay/)
  })

  it('resolves include-all and filter regex statically', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies,
        'proxy-groups': [{ name: 'HK', type: 'select', 'include-all': true, filter: '^HK' }]
      })
    )
    expect(outbound(config, 'HK').outbounds).toEqual(['HK-1'])
  })

  it('supports the common RE2-style leading (?i) filter flag', () => {
    const { config, errors } = convertClashToSingbox(
      base({
        proxies,
        'proxy-groups': [
          { name: 'Hong Kong', type: 'select', 'include-all': true, filter: '(?i)hk|香港' }
        ]
      })
    )
    expect(outbound(config, 'Hong Kong').outbounds).toEqual(['HK-1'])
    expect(errors).toEqual([])
  })

  it('reports empty groups as fatal instead of silently falling back to direct', () => {
    const { config, errors } = convertClashToSingbox(
      base({
        proxies,
        'proxy-groups': [{ name: 'Empty', type: 'select', proxies: ['does-not-exist'] }]
      })
    )
    expect(outbound(config, 'Empty').outbounds).toEqual(['direct'])
    expect(errors.join('\n')).toMatch(/Empty.*refusing unsafe fallback/)
  })

  it('rejects provider-only profiles instead of producing a direct-only config', () => {
    const { errors } = convertClashToSingbox(
      base({
        'proxy-providers': {
          airport: { type: 'http', url: 'https://example.invalid/provider.yaml' }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      })
    )
    expect(errors.join('\n')).toMatch(/proxy-providers.*no inline proxies/)
    expect(errors.join('\n')).toMatch(/cannot be converted safely/)
  })
})

describe('rules', () => {
  const proxies = [
    { name: 'p1', type: 'ss', server: 'a', port: 1, cipher: 'aes-128-gcm', password: 'x' }
  ]

  it('maps basic rule types', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies,
        rules: [
          'DOMAIN,example.com,p1',
          'DOMAIN-SUFFIX,google.com,p1',
          'DOMAIN-KEYWORD,ads,REJECT',
          'IP-CIDR,10.0.0.0/8,DIRECT',
          'IP-CIDR6,2620:0:2d0::/48,DIRECT',
          'SRC-IP-CIDR,192.168.1.0/24,DIRECT',
          'DST-PORT,443,p1',
          'SRC-PORT,7777,DIRECT',
          'PROCESS-NAME,chrome.exe,p1',
          'MATCH,p1'
        ]
      })
    )
    const rules = routeRules(config)
    expect(rules.find((r) => (r.domain as string[])?.includes('example.com'))).toMatchObject({
      outbound: 'p1'
    })
    expect(rules.find((r) => (r.domain_suffix as string[])?.includes('google.com'))).toMatchObject({
      outbound: 'p1'
    })
    expect(rules.find((r) => (r.domain_keyword as string[])?.includes('ads'))).toMatchObject({
      action: 'reject'
    })
    expect(rules.find((r) => (r.ip_cidr as string[])?.includes('10.0.0.0/8'))).toMatchObject({
      outbound: 'direct'
    })
    expect(rules.find((r) => (r.ip_cidr as string[])?.includes('2620:0:2d0::/48'))).toBeDefined()
    expect(
      rules.find((r) => (r.source_ip_cidr as string[])?.includes('192.168.1.0/24'))
    ).toBeDefined()
    expect(rules.find((r) => (r.port as number[])?.includes(443))).toMatchObject({ outbound: 'p1' })
    expect(rules.find((r) => (r.source_port as number[])?.includes(7777))).toBeDefined()
    expect(rules.find((r) => (r.process_name as string[])?.includes('chrome.exe'))).toBeDefined()
    expect((config.route as Dict).final).toBe('p1')
  })

  it('maps Windows wildcard/regex process rules and source GeoIP', () => {
    const { config, errors } = convertClashToSingbox(
      base({
        proxies,
        rules: [
          'DOMAIN-WILDCARD,*.example.com,p1',
          'PROCESS-NAME-WILDCARD,chrome*.exe,p1',
          'PROCESS-PATH-REGEX,^C:\\\\Apps\\\\.+\\\\client\\.exe$,p1',
          'SRC-GEOIP,private,DIRECT',
          'MATCH,p1'
        ]
      })
    )
    const rules = routeRules(config)
    expect(rules.some((rule) => (rule.domain_regex as string[])?.[0]?.includes('example'))).toBe(
      true
    )
    expect(rules.some((rule) => Array.isArray(rule.process_path_regex))).toBe(true)
    expect(rules.some((rule) => rule.source_ip_is_private === true)).toBe(true)
    expect(errors).toEqual([])
  })

  it('converts GEOSITE / GEOIP into remote srs rule-sets with direct download detour', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies,
        rules: [
          'GEOSITE,category-ads-all,REJECT',
          'GEOIP,CN,DIRECT',
          'GEOIP,LAN,DIRECT',
          'MATCH,p1'
        ]
      })
    )
    const ruleSetList = (config.route as Dict).rule_set as Dict[]
    const geosite = ruleSetList.find((r) => r.tag === 'geosite-category-ads-all') as Dict
    expect(geosite).toMatchObject({
      type: 'remote',
      format: 'binary',
      download_detour: 'direct',
      url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs'
    })
    const geoip = ruleSetList.find((r) => r.tag === 'geoip-cn') as Dict
    expect(geoip.url).toBe(
      'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs'
    )
    const rules = routeRules(config)
    expect(
      rules.find((r) => (r.rule_set as string[])?.includes('geosite-category-ads-all'))
    ).toMatchObject({ action: 'reject' })
    // GEOIP,LAN becomes ip_is_private, not a rule set
    expect(rules.find((r) => r.ip_is_private === true)).toMatchObject({ outbound: 'direct' })
  })

  it('maps logical AND/OR/NOT rules', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies,
        rules: [
          'AND,((DOMAIN-SUFFIX,youtube.com),(NETWORK,UDP)),REJECT',
          'OR,((DOMAIN,a.com),(DOMAIN,b.com)),p1',
          'NOT,((DOMAIN-SUFFIX,cn)),p1'
        ]
      })
    )
    const rules = routeRules(config)
    const andRule = rules.find((r) => r.type === 'logical' && r.mode === 'and') as Dict
    expect(andRule.action).toBe('reject')
    expect((andRule.rules as Dict[])[0].domain_suffix).toEqual(['youtube.com'])
    expect((andRule.rules as Dict[])[1].network).toEqual(['udp'])
    const orRule = rules.find((r) => r.type === 'logical' && r.mode === 'or') as Dict
    expect(orRule.outbound).toBe('p1')
    const notRule = rules.find((r) => r.invert === true) as Dict
    expect(notRule.domain_suffix).toEqual(['cn'])
  })

  it('rejects rule-providers and unknown targets instead of falling back', () => {
    const { config, errors } = convertClashToSingbox(
      base({
        proxies,
        rules: ['RULE-SET,my-provider,p1', 'DOMAIN,x.com,GhostGroup', 'MATCH,DIRECT']
      })
    )
    const rules = routeRules(config)
    expect(rules.find((r) => (r.domain as string[])?.includes('x.com'))).toBeUndefined()
    expect(errors.join('\n')).toMatch(/rule-providers/)
    expect(errors.join('\n')).toMatch(/GhostGroup/)
    expect((config.route as Dict).final).toBe('direct')
  })
})

describe('clash mode routing', () => {
  it('adds clash_mode rules and a GLOBAL selector containing everything', () => {
    const { config } = convertClashToSingbox(
      base({
        proxies: [
          { name: 'p1', type: 'ss', server: 'a', port: 1, cipher: 'aes-128-gcm', password: 'x' }
        ],
        'proxy-groups': [{ name: 'G', type: 'select', proxies: ['p1'] }]
      })
    )
    const rules = routeRules(config)
    expect(rules.find((r) => r.clash_mode === 'Direct')).toMatchObject({ outbound: 'direct' })
    expect(rules.find((r) => r.clash_mode === 'Global')).toMatchObject({ outbound: 'GLOBAL' })
    // "Rule" must appear in a rule so sing-box keeps it in the switchable mode list
    expect(rules.find((r) => r.clash_mode === 'Rule')).toBeDefined()
    const global = outbound(config, 'GLOBAL')
    expect(global.outbounds).toEqual(['G', 'p1', 'direct'])
    // clash_mode rules must precede converted profile rules
    const globalIdx = rules.findIndex((r) => r.clash_mode === 'Global')
    expect(globalIdx).toBeGreaterThanOrEqual(0)
  })

  it('emits sniff and hijack-dns action rules when enabled', () => {
    const { config } = convertClashToSingbox(
      base({
        sniffer: { enable: true },
        dns: { enable: true, nameserver: ['223.5.5.5'] }
      })
    )
    const rules = routeRules(config)
    expect(rules[0]).toEqual({ action: 'sniff' })
    expect(rules[1]).toEqual({ protocol: 'dns', action: 'hijack-dns' })
  })
})
