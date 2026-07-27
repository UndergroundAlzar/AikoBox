import { execFileSync } from 'child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { parse } from '../../utils/yaml'
import { convertClashToSingbox } from './convert'

const projectRoot = process.cwd()
const corePath = join(projectRoot, 'extra', 'sidecar', 'sing-box.exe')
const fixtureDir = join(projectRoot, 'src', 'main', 'core', 'singbox', 'fixtures')
const hasSidecar = existsSync(corePath)
let workDir = ''

beforeAll(() => {
  workDir = mkdtempSync(join(tmpdir(), 'aikobox-singbox-check-'))
})

afterAll(() => {
  rmSync(workDir, { recursive: true, force: true })
})

describe.skipIf(!hasSidecar)('real sing-box configuration gate', () => {
  it('keeps the pinned Windows sidecar available for schema verification', () => {
    expect(existsSync(corePath)).toBe(true)
  })

  it('converts realistic YAML and passes sing-box check', () => {
    const source = readFileSync(join(fixtureDir, 'airport-inline-mainstream.yaml'), 'utf8')
    const clash = parse<Record<string, unknown>>(source)
    const result = convertClashToSingbox(clash, {
      platform: 'win32',
      controllerSecret: 'fixture-controller-secret'
    })
    expect(result.errors).toEqual([])

    const configPath = join(workDir, 'sing-box.json')
    writeFileSync(configPath, JSON.stringify(result.config, null, 2))
    expect(() =>
      execFileSync(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15000
      })
    ).not.toThrow()
  })

  it('emits valid source ACL rules for LAN proxy access', () => {
    const result = convertClashToSingbox(
      {
        'mixed-port': 17890,
        'allow-lan': true,
        authentication: ['user:password'],
        'lan-allowed-ips': ['192.168.50.0/24'],
        'lan-disallowed-ips': ['192.168.50.100/32'],
        proxies: [{ name: 'local', type: 'socks5', server: '127.0.0.1', port: 1080 }],
        'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['local'] }],
        rules: ['MATCH,PROXY']
      },
      { platform: 'win32', controllerSecret: 'fixture-controller-secret' }
    )
    expect(result.errors).toEqual([])

    const configPath = join(workDir, 'sing-box-lan-acl.json')
    writeFileSync(configPath, JSON.stringify(result.config, null, 2))
    expect(() =>
      execFileSync(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15000
      })
    ).not.toThrow()
  })

  it('emits a valid rule set for a fake-ip profile full of destination-ip rules', () => {
    // the mainstream fixture only has MATCH, so nothing else in this file
    // exercises ip_cidr / geoip rule sets, no-resolve options or fake-ip DNS.
    const result = convertClashToSingbox(
      {
        'mixed-port': 17890,
        dns: {
          enable: true,
          'enhanced-mode': 'fake-ip',
          'fake-ip-range': '198.18.0.1/16',
          nameserver: ['https://doh.pub/dns-query']
        },
        proxies: [
          {
            name: 'node',
            type: 'ss',
            server: '192.0.2.20',
            port: 443,
            cipher: 'aes-128-gcm',
            password: 'x'
          }
        ],
        'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['node'] }],
        rules: [
          'IP-CIDR,1.2.3.4/32,DIRECT,no-resolve',
          'IP-CIDR6,2620:0:2d0::/48,DIRECT',
          'GEOIP,LAN,DIRECT',
          'GEOIP,CN,DIRECT',
          'GEOSITE,cn,DIRECT',
          'AND,((GEOIP,CN),(NETWORK,udp)),DIRECT',
          'MATCH,PROXY'
        ]
      },
      { platform: 'win32', controllerSecret: 'fixture-controller-secret' }
    )
    expect(result.errors).toEqual([])
    // Destination-IP rules need an explicit lookup when the destination is a domain.
    expect(
      ((result.config.route as Record<string, unknown>).rules as Record<string, unknown>[]).some(
        (rule) => rule.action === 'resolve'
      )
    ).toBe(true)

    const configPath = join(workDir, 'sing-box-ip-rules.json')
    writeFileSync(configPath, JSON.stringify(result.config, null, 2))
    expect(() =>
      execFileSync(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15000
      })
    ).not.toThrow()
  })

  it('emits a valid ShadowTLS v3 outbound', () => {
    const result = convertClashToSingbox({
      'mixed-port': 17890,
      proxies: [
        {
          name: 'ShadowTLS',
          type: 'shadowtls',
          server: '192.0.2.10',
          port: 443,
          version: 3,
          password: 'secret',
          servername: 'www.example.com',
          tls: true
        }
      ],
      'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['ShadowTLS'] }],
      rules: ['MATCH,PROXY']
    })
    expect(result.errors).toEqual([])
    const configPath = join(workDir, 'sing-box-shadowtls.json')
    writeFileSync(configPath, JSON.stringify(result.config, null, 2))
    expect(() =>
      execFileSync(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15000
      })
    ).not.toThrow()
  })

  it('accepts fake-ip DNS detours and port-based DNS hijacking without sniffing', () => {
    const result = convertClashToSingbox(
      {
        'mixed-port': 17890,
        sniffer: { enable: false },
        tun: { enable: true },
        dns: {
          enable: true,
          ipv6: false,
          'enhanced-mode': 'fake-ip',
          nameserver: ['https://1.1.1.1/dns-query#PROXY&h3=true'],
          'nameserver-policy': {
            'example.com': 'https://8.8.8.8/dns-query#PROXY'
          }
        },
        proxies: [
          {
            name: 'ProxyNode',
            type: 'socks5',
            server: '127.0.0.1',
            port: 1080
          }
        ],
        'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['ProxyNode'] }],
        rules: ['PROCESS-NAME-REGEX,^chrome,PROXY', 'IP-CIDR,192.0.2.0/24,DIRECT', 'MATCH,PROXY']
      },
      { platform: 'win32', controllerSecret: 'fixture-controller-secret' }
    )
    expect(result.errors).toEqual([])
    const configPath = join(workDir, 'sing-box-dns-detour.json')
    writeFileSync(configPath, JSON.stringify(result.config, null, 2))
    expect(() =>
      execFileSync(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15000
      })
    ).not.toThrow()
  })

  it('accepts a converted WireGuard endpoint with multiple peers', () => {
    const result = convertClashToSingbox({
      'mixed-port': 17890,
      proxies: [
        {
          name: 'WireGuard',
          type: 'wireguard',
          ip: '172.16.0.2/32',
          ipv6: 'fd00::2/128',
          'private-key': 'YWlrb2JveC13aXJlZ3VhcmQtcHJpdmF0ZS1rZXktMDE=',
          peers: [
            {
              server: '192.0.2.1',
              port: 51820,
              'public-key': 'YWlrb2JveC13aXJlZ3VhcmQtcHVibGljLWtleS0tMDE=',
              'allowed-ips': ['0.0.0.0/1']
            },
            {
              server: '192.0.2.2',
              port: 51820,
              'public-key': 'YWlrb2JveC13aXJlZ3VhcmQtcHVibGljLWtleS0tMDI=',
              'allowed-ips': ['128.0.0.0/1', '::/0'],
              reserved: [1, 2, 3]
            }
          ]
        }
      ],
      'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['WireGuard'] }],
      rules: ['MATCH,PROXY']
    })
    expect(result.errors).toEqual([])
    const configPath = join(workDir, 'sing-box-wireguard-peers.json')
    writeFileSync(configPath, JSON.stringify(result.config, null, 2))
    expect(() =>
      execFileSync(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15000
      })
    ).not.toThrow()
  })
})
