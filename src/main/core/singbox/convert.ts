/**
 * Pure converter: merged Clash (mihomo) config object -> sing-box (1.12+ schema) config object.
 *
 * - No electron / fs imports, fully testable.
 * - Unknown or unconvertible options are skipped and reported through `warnings`,
 *   never thrown.
 * - An empty profile still yields a valid, startable sing-box config.
 */

type Dict = Record<string, unknown>

export interface ISingboxController {
  /** value for experimental.clash_api.external_controller */
  listen: string
  /** host the app itself should connect to */
  host: string
  port: number
  secret: string
}

export interface ISingboxConvertOptions {
  /** process.platform of the target machine; affects platform-only inbounds */
  platform?: string
}

export interface ISingboxConvertResult {
  config: Dict
  warnings: string[]
  controller: ISingboxController
}

const DEFAULT_CONTROLLER_PORT = 9090
const RULE_SET_URL_BASE = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo'

/* ------------------------------- helpers ---------------------------------- */

function asDict(v: unknown): Dict {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Dict) : {}
}

function asArray(v: unknown): unknown[] {
  return Array.isArray(v) ? v : []
}

function toStr(v: unknown): string | undefined {
  if (typeof v === 'string') return v
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  return undefined
}

function toNum(v: unknown): number | undefined {
  if (typeof v === 'number' && Number.isFinite(v)) return v
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v.trim().replace(/[^\d.-].*$/, ''))
    if (Number.isFinite(n)) return n
  }
  return undefined
}

function toBool(v: unknown): boolean | undefined {
  if (typeof v === 'boolean') return v
  if (v === 'true') return true
  if (v === 'false') return false
  return undefined
}

function toStrArray(v: unknown): string[] {
  if (typeof v === 'string') return v === '' ? [] : [v]
  return asArray(v)
    .map((item) => toStr(item))
    .filter((item): item is string => item !== undefined)
}

function compact(obj: Dict): Dict {
  const out: Dict = {}
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue
    if (Array.isArray(v) && v.length === 0) continue
    out[k] = v
  }
  return out
}

function isIpLiteral(host: string): boolean {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return true
  return host.includes(':') && /^[0-9a-fA-F:.]+$/.test(host)
}

/** parse "host:port", "[v6]:port", ":port", "host" */
function parseHostPort(value: string): { host: string; port?: number } {
  const trimmed = value.trim()
  const bracket = trimmed.match(/^\[([^\]]+)\](?::(\d+))?$/)
  if (bracket) {
    return { host: bracket[1], port: bracket[2] ? parseInt(bracket[2]) : undefined }
  }
  // bare IPv6 literal (multiple colons, no brackets)
  if ((trimmed.match(/:/g) || []).length > 1) {
    return { host: trimmed }
  }
  const idx = trimmed.lastIndexOf(':')
  if (idx === -1) return { host: trimmed }
  const host = trimmed.slice(0, idx)
  const port = parseInt(trimmed.slice(idx + 1))
  return { host, port: Number.isFinite(port) ? port : undefined }
}

/* ----------------------------- controller --------------------------------- */

export function deriveController(clash: Dict): ISingboxController {
  const raw = toStr(clash['external-controller'])?.trim() || ''
  const secret = toStr(clash['secret']) || ''

  let host = '127.0.0.1'
  let port = DEFAULT_CONTROLLER_PORT
  if (raw) {
    const parsed = parseHostPort(raw)
    if (parsed.port && parsed.port > 0 && parsed.port <= 65535) port = parsed.port
    if (parsed.host) host = parsed.host
  }

  const listenHost = host === '' ? '127.0.0.1' : host
  const clientHost =
    listenHost === '0.0.0.0' || listenHost === '::' || listenHost === '*' ? '127.0.0.1' : listenHost

  const listen = listenHost === '*' ? `0.0.0.0:${port}` : `${listenHost}:${port}`
  return { listen, host: clientHost, port, secret }
}

/* -------------------------------- log ------------------------------------- */

function mapLogLevel(level: unknown): string {
  switch (toStr(level)) {
    case 'debug':
      return 'debug'
    case 'warning':
      return 'warn'
    case 'error':
      return 'error'
    case 'silent':
      return 'fatal'
    case 'info':
    default:
      return 'info'
  }
}

/* -------------------------------- dns ------------------------------------- */

interface DomainPatterns {
  domain: string[]
  domain_suffix: string[]
  domain_keyword: string[]
  domain_regex: string[]
  skipped: string[]
}

function classifyDomainPatterns(patterns: string[]): DomainPatterns {
  const out: DomainPatterns = {
    domain: [],
    domain_suffix: [],
    domain_keyword: [],
    domain_regex: [],
    skipped: []
  }
  for (const raw of patterns) {
    const p = raw.trim()
    if (!p) continue
    if (p === '*' || p.includes('geosite:') || p.includes('rule-set:')) {
      out.skipped.push(p)
      continue
    }
    if (p.startsWith('+.')) {
      out.domain_suffix.push(p.slice(1)) // '+.lan' -> '.lan' (subdomains)
      out.domain.push(p.slice(2)) // and the domain itself
    } else if (p.startsWith('*.')) {
      out.domain_suffix.push(p.slice(1))
    } else if (p.includes('*')) {
      // wildcard inside the domain: approximate with a keyword-free regex
      const regex = `^${p.replace(/\./g, '\\.').replace(/\*/g, '[^.]*')}$`
      out.domain_regex.push(regex)
    } else {
      out.domain.push(p)
    }
  }
  return out
}

function domainPatternFields(p: DomainPatterns): Dict {
  return compact({
    domain: p.domain,
    domain_suffix: p.domain_suffix,
    domain_keyword: p.domain_keyword,
    domain_regex: p.domain_regex
  })
}

interface DnsServerBuild {
  server: Dict | null
  warning?: string
}

/** map a Clash nameserver URL to a sing-box (1.12+) typed DNS server */
function parseNameserver(raw: string, tag: string): DnsServerBuild {
  let value = raw.trim()
  if (!value) return { server: null }

  // mihomo allows `#detour` / `#h3=true` fragments — strip them
  const hashIdx = value.indexOf('#')
  if (hashIdx !== -1) value = value.slice(0, hashIdx)

  if (value === 'system' || value === 'system://') {
    return { server: { type: 'local', tag } }
  }
  if (value.startsWith('rcode://')) {
    return { server: null, warning: `DNS nameserver "${raw}" (rcode) is not supported, skipped` }
  }
  if (value.startsWith('dhcp://')) {
    const iface = value.slice('dhcp://'.length)
    const server: Dict = { type: 'dhcp', tag }
    if (iface && iface !== 'auto' && iface !== 'system') server.interface = iface
    return { server }
  }

  const schemeMatch = value.match(/^([a-z0-9+]+):\/\//i)
  const scheme = schemeMatch ? schemeMatch[1].toLowerCase() : 'udp'
  const rest = schemeMatch ? value.slice(schemeMatch[0].length) : value

  const slashIdx = rest.indexOf('/')
  const hostPort = slashIdx === -1 ? rest : rest.slice(0, slashIdx)
  const path = slashIdx === -1 ? undefined : rest.slice(slashIdx)
  const { host, port } = parseHostPort(hostPort)
  if (!host) {
    return { server: null, warning: `DNS nameserver "${raw}" could not be parsed, skipped` }
  }

  switch (scheme) {
    case 'udp':
      return { server: compact({ type: 'udp', tag, server: host, server_port: port }) }
    case 'tcp':
      return { server: compact({ type: 'tcp', tag, server: host, server_port: port }) }
    case 'tls':
      return { server: compact({ type: 'tls', tag, server: host, server_port: port }) }
    case 'quic':
      return { server: compact({ type: 'quic', tag, server: host, server_port: port }) }
    case 'https':
      return {
        server: compact({
          type: 'https',
          tag,
          server: host,
          server_port: port,
          path: path && path !== '/dns-query' ? path : undefined
        })
      }
    case 'h3':
      return {
        server: compact({
          type: 'h3',
          tag,
          server: host,
          server_port: port,
          path: path && path !== '/dns-query' ? path : undefined
        })
      }
    default:
      return { server: null, warning: `DNS nameserver "${raw}" has unsupported scheme, skipped` }
  }
}

interface DnsBuild {
  dns: Dict
  warnings: string[]
}

function buildDns(clash: Dict, ipv6Enabled: boolean): DnsBuild {
  const warnings: string[] = []
  const dnsConfig = asDict(clash.dns)
  const dnsEnabled = toBool(dnsConfig.enable) ?? false

  const servers: Dict[] = []
  const rules: Dict[] = []
  const seen = new Map<string, string>() // normalized definition -> tag

  const addServer = (server: Dict): string => {
    // DNS 服务器初始化早于路由默认解析器：域名地址的 DNS 服务器
    // 必须自带 domain_resolver（用系统解析器引导）
    const host = toStr(server.server)
    if (host && !isIpLiteral(host) && !server.domain_resolver) {
      server.domain_resolver = 'dns-local'
    }
    const { tag: _tag, ...rest } = server
    const key = JSON.stringify(rest)
    const existing = seen.get(key)
    if (existing) return existing
    servers.push(server)
    seen.set(key, server.tag as string)
    return server.tag as string
  }

  addServer({ type: 'local', tag: 'dns-local' })

  let defaultTag = 'dns-local'
  if (dnsEnabled) {
    const nameservers = toStrArray(dnsConfig.nameserver)
    let index = 0
    for (const ns of nameservers) {
      const { server, warning } = parseNameserver(ns, `dns-${index}`)
      if (warning) warnings.push(warning)
      if (server) {
        const tag = addServer(server)
        if (defaultTag === 'dns-local' && tag !== 'dns-local') defaultTag = tag
        index++
      }
    }
    if (defaultTag === 'dns-local' && nameservers.length > 0) {
      warnings.push('No usable DNS nameserver could be converted, falling back to system DNS')
    }

    // nameserver-policy -> dns rules
    const policy = asDict(dnsConfig['nameserver-policy'])
    for (const [pattern, target] of Object.entries(policy)) {
      const targets = toStrArray(target)
      if (targets.length === 0) continue
      const { server, warning } = parseNameserver(targets[0], `dns-policy-${servers.length}`)
      if (warning) warnings.push(warning)
      if (!server) continue
      const tag = addServer(server)
      const classified = classifyDomainPatterns([pattern])
      if (classified.skipped.length > 0) {
        warnings.push(`nameserver-policy pattern "${pattern}" is not supported, skipped`)
        continue
      }
      const fields = domainPatternFields(classified)
      if (Object.keys(fields).length === 0) continue
      rules.push({ ...fields, server: tag })
    }

    // fake-ip
    const enhancedMode = toStr(dnsConfig['enhanced-mode']) || 'redir-host'
    if (enhancedMode === 'fake-ip') {
      const fakeip: Dict = {
        type: 'fakeip',
        tag: 'dns-fakeip',
        inet4_range: toStr(dnsConfig['fake-ip-range']) || '198.18.0.1/16'
      }
      if (ipv6Enabled) fakeip.inet6_range = 'fc00::/18'
      servers.push(fakeip)

      const filterPatterns = toStrArray(dnsConfig['fake-ip-filter'])
      const classified = classifyDomainPatterns(filterPatterns)
      const filterFields = domainPatternFields(classified)
      const filterMode = toStr(dnsConfig['fake-ip-filter-mode']) || 'blacklist'

      if (filterMode === 'whitelist') {
        if (Object.keys(filterFields).length > 0) {
          rules.push({ ...filterFields, query_type: ['A', 'AAAA'], server: 'dns-fakeip' })
        } else {
          warnings.push('fake-ip-filter-mode whitelist with empty filter disables fake-ip')
        }
      } else {
        if (Object.keys(filterFields).length > 0) {
          rules.push({ ...filterFields, server: defaultTag })
        }
        rules.push({ query_type: ['A', 'AAAA'], server: 'dns-fakeip' })
      }
      if (classified.skipped.length > 0) {
        warnings.push(
          `fake-ip-filter entries not convertible were skipped: ${classified.skipped.join(', ')}`
        )
      }
    }

    if (dnsConfig.fallback !== undefined && toStrArray(dnsConfig.fallback).length > 0) {
      warnings.push('dns.fallback / fallback-filter have no sing-box equivalent, skipped')
    }
  }

  if (clash.hosts && Object.keys(asDict(clash.hosts)).length > 0) {
    warnings.push('hosts mapping is not converted to sing-box yet, skipped')
  }

  const dns = compact({
    servers,
    rules,
    final: defaultTag,
    strategy: ipv6Enabled ? undefined : 'ipv4_only',
    independent_cache: servers.some((s) => s.type === 'fakeip') ? true : undefined
  })

  return { dns, warnings }
}

/* ------------------------------ outbounds --------------------------------- */

interface OutboundBuild {
  outbound?: Dict
  endpoint?: Dict
  warning?: string
}

function buildTls(p: Dict): Dict | undefined {
  const realityOpts = asDict(p['reality-opts'])
  const hasReality = Object.keys(realityOpts).length > 0
  const enabled = toBool(p.tls) === true || hasReality
  if (!enabled) return undefined

  const tls: Dict = compact({
    enabled: true,
    server_name: toStr(p.servername) || toStr(p.sni),
    insecure: toBool(p['skip-cert-verify']),
    alpn: toStrArray(p.alpn)
  })

  const fingerprint = toStr(p['client-fingerprint'])
  if (fingerprint && fingerprint !== 'none') {
    tls.utls = { enabled: true, fingerprint }
  }
  if (hasReality) {
    tls.reality = compact({
      enabled: true,
      public_key: toStr(realityOpts['public-key']),
      short_id: toStr(realityOpts['short-id'])
    })
  }
  return tls
}

/** always-on TLS (trojan / hysteria2 / tuic / anytls) */
function buildForcedTls(p: Dict, defaultAlpn?: string[]): Dict {
  const tls: Dict = compact({
    enabled: true,
    server_name: toStr(p.sni) || toStr(p.servername),
    insecure: toBool(p['skip-cert-verify']),
    alpn: toStrArray(p.alpn).length > 0 ? toStrArray(p.alpn) : defaultAlpn
  })
  const fingerprint = toStr(p['client-fingerprint'])
  if (fingerprint && fingerprint !== 'none') {
    tls.utls = { enabled: true, fingerprint }
  }
  if (toStr(p['disable-sni']) === 'true' || toBool(p['disable-sni']) === true) {
    tls.disable_sni = true
  }
  return tls
}

function buildTransport(p: Dict): { transport?: Dict; warning?: string } {
  const network = toStr(p.network)
  if (!network || network === 'tcp') return {}

  switch (network) {
    case 'ws': {
      const opts = asDict(p['ws-opts'])
      const headers = asDict(opts.headers)
      return {
        transport: compact({
          type: 'ws',
          path: toStr(opts.path),
          headers: Object.keys(headers).length > 0 ? headers : undefined,
          max_early_data: toNum(opts['max-early-data']),
          early_data_header_name: toStr(opts['early-data-header-name'])
        })
      }
    }
    case 'grpc': {
      const opts = asDict(p['grpc-opts'])
      return {
        transport: compact({
          type: 'grpc',
          service_name: toStr(opts['grpc-service-name'])
        })
      }
    }
    case 'h2': {
      const opts = asDict(p['h2-opts'])
      return {
        transport: compact({
          type: 'http',
          host: toStrArray(opts.host),
          path: toStr(opts.path)
        })
      }
    }
    case 'http': {
      const opts = asDict(p['http-opts'])
      const paths = toStrArray(opts.path)
      const headers = asDict(opts.headers)
      return {
        transport: compact({
          type: 'http',
          method: toStr(opts.method),
          path: paths.length > 0 ? paths[0] : undefined,
          headers: Object.keys(headers).length > 0 ? headers : undefined
        })
      }
    }
    default:
      return { warning: `transport network "${network}" is not supported` }
  }
}

function convertShadowsocks(p: Dict, tag: string): OutboundBuild {
  const outbound: Dict = compact({
    type: 'shadowsocks',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    method: toStr(p.cipher),
    password: toStr(p.password),
    udp_over_tcp: toBool(p['udp-over-tcp']) === true ? true : undefined
  })

  const plugin = toStr(p.plugin)
  if (plugin) {
    const opts = asDict(p['plugin-opts'])
    if (plugin === 'obfs') {
      const parts = [`obfs=${toStr(opts.mode) || 'http'}`]
      const host = toStr(opts.host)
      if (host) parts.push(`obfs-host=${host}`)
      outbound.plugin = 'obfs-local'
      outbound.plugin_opts = parts.join(';')
    } else if (plugin === 'v2ray-plugin') {
      const parts = [`mode=${toStr(opts.mode) || 'websocket'}`]
      if (toBool(opts.tls) === true) parts.push('tls')
      const host = toStr(opts.host)
      const path = toStr(opts.path)
      if (host) parts.push(`host=${host}`)
      if (path) parts.push(`path=${path}`)
      if (toBool(opts['skip-cert-verify']) === true) parts.push('skipVerify=true')
      outbound.plugin = 'v2ray-plugin'
      outbound.plugin_opts = parts.join(';')
      if (toBool(opts.mux) === true) {
        outbound.plugin_opts = `${outbound.plugin_opts};mux=1`
      }
    } else {
      return {
        warning: `proxy "${tag}": shadowsocks plugin "${plugin}" is not supported, proxy skipped`
      }
    }
  }
  return { outbound }
}

function convertVmess(p: Dict, tag: string): OutboundBuild {
  const { transport, warning } = buildTransport(p)
  if (warning) return { warning: `proxy "${tag}": ${warning}, proxy skipped` }
  const network = toStr(p.network)
  const tls = buildTls(p)
  // h2 transport in Clash implies TLS
  const forcedTls =
    network === 'h2' && !tls
      ? { enabled: true, server_name: toStr(p.servername) || toStr(p.sni) }
      : undefined
  const outbound = compact({
    type: 'vmess',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    uuid: toStr(p.uuid),
    security: toStr(p.cipher) || 'auto',
    alter_id: toNum(p.alterId) ?? toNum(p['alter-id']) ?? 0,
    tls: tls || (forcedTls ? compact(forcedTls) : undefined),
    transport
  })
  return { outbound }
}

function convertVless(p: Dict, tag: string): OutboundBuild {
  const { transport, warning } = buildTransport(p)
  if (warning) return { warning: `proxy "${tag}": ${warning}, proxy skipped` }
  const flow = toStr(p.flow)
  const outbound = compact({
    type: 'vless',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    uuid: toStr(p.uuid),
    flow: flow && flow.startsWith('xtls-rprx-vision') ? 'xtls-rprx-vision' : undefined,
    tls: buildTls(p),
    transport,
    packet_encoding: toStr(p['packet-encoding'])
  })
  if (flow && !flow.startsWith('xtls-rprx-vision')) {
    return {
      outbound,
      warning: `proxy "${tag}": vless flow "${flow}" is not supported and was dropped`
    }
  }
  return { outbound }
}

function convertTrojan(p: Dict, tag: string): OutboundBuild {
  const { transport, warning } = buildTransport(p)
  if (warning) return { warning: `proxy "${tag}": ${warning}, proxy skipped` }
  const outbound = compact({
    type: 'trojan',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    password: toStr(p.password),
    tls: buildForcedTls(p),
    transport
  })
  return { outbound }
}

function convertHysteria2(p: Dict, tag: string): OutboundBuild {
  const outbound: Dict = compact({
    type: 'hysteria2',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    password: toStr(p.password) || toStr(p.auth),
    up_mbps: toNum(p.up),
    down_mbps: toNum(p.down),
    tls: buildForcedTls(p, ['h3'])
  })
  const obfs = toStr(p.obfs)
  if (obfs === 'salamander') {
    outbound.obfs = compact({ type: 'salamander', password: toStr(p['obfs-password']) })
  } else if (obfs) {
    return { warning: `proxy "${tag}": hysteria2 obfs "${obfs}" is not supported, proxy skipped` }
  }
  return { outbound }
}

function convertTuic(p: Dict, tag: string): OutboundBuild {
  const token = toStr(p.token)
  if (token && !toStr(p.uuid)) {
    return { warning: `proxy "${tag}": TUIC v4 (token) is not supported, proxy skipped` }
  }
  const outbound = compact({
    type: 'tuic',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    uuid: toStr(p.uuid),
    password: toStr(p.password),
    congestion_control: toStr(p['congestion-controller']) || toStr(p['congestion-control']),
    udp_relay_mode: toStr(p['udp-relay-mode']),
    udp_over_stream: toBool(p['udp-over-stream']),
    zero_rtt_handshake: toBool(p['reduce-rtt']),
    heartbeat:
      toNum(p['heartbeat-interval']) !== undefined
        ? `${toNum(p['heartbeat-interval'])}ms`
        : undefined,
    tls: buildForcedTls(p, ['h3'])
  })
  return { outbound }
}

function convertWireguard(p: Dict, tag: string): OutboundBuild {
  const localAddresses: string[] = []
  const ip4 = toStr(p.ip)
  const ip6 = toStr(p.ipv6)
  if (ip4) localAddresses.push(ip4.includes('/') ? ip4 : `${ip4}/32`)
  if (ip6) localAddresses.push(ip6.includes('/') ? ip6 : `${ip6}/128`)
  if (localAddresses.length === 0) {
    return { warning: `proxy "${tag}": wireguard is missing local ip, proxy skipped` }
  }

  let reserved: number[] | string | undefined
  if (Array.isArray(p.reserved)) {
    const nums = asArray(p.reserved)
      .map((n) => toNum(n))
      .filter((n): n is number => n !== undefined)
    if (nums.length === 3) reserved = nums
  } else if (typeof p.reserved === 'string') {
    reserved = p.reserved
  }

  const endpoint = compact({
    type: 'wireguard',
    tag,
    address: localAddresses,
    private_key: toStr(p['private-key']),
    mtu: toNum(p.mtu),
    peers: [
      compact({
        address: toStr(p.server),
        port: toNum(p.port),
        public_key: toStr(p['public-key']),
        pre_shared_key: toStr(p['pre-shared-key']) || toStr(p['preshared-key']),
        allowed_ips: ['0.0.0.0/0', '::/0'],
        reserved
      })
    ]
  })
  return { endpoint }
}

function convertHttp(p: Dict, tag: string): OutboundBuild {
  const outbound = compact({
    type: 'http',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    username: toStr(p.username),
    password: toStr(p.password),
    tls: buildTls(p)
  })
  return { outbound }
}

function convertSocks5(p: Dict, tag: string): OutboundBuild {
  if (toBool(p.tls) === true) {
    return { warning: `proxy "${tag}": socks5 over TLS is not supported, proxy skipped` }
  }
  const outbound = compact({
    type: 'socks',
    tag,
    version: '5',
    server: toStr(p.server),
    server_port: toNum(p.port),
    username: toStr(p.username),
    password: toStr(p.password)
  })
  return { outbound }
}

function convertAnytls(p: Dict, tag: string): OutboundBuild {
  const outbound = compact({
    type: 'anytls',
    tag,
    server: toStr(p.server),
    server_port: toNum(p.port),
    password: toStr(p.password),
    tls: buildForcedTls(p)
  })
  return { outbound }
}

function convertProxy(p: Dict): OutboundBuild {
  const tag = toStr(p.name)
  if (!tag) return { warning: 'proxy without a name was skipped' }
  const type = toStr(p.type)
  switch (type) {
    case 'ss':
      return convertShadowsocks(p, tag)
    case 'vmess':
      return convertVmess(p, tag)
    case 'vless':
      return convertVless(p, tag)
    case 'trojan':
      return convertTrojan(p, tag)
    case 'hysteria2':
      return convertHysteria2(p, tag)
    case 'tuic':
      return convertTuic(p, tag)
    case 'wireguard':
      return convertWireguard(p, tag)
    case 'http':
      return convertHttp(p, tag)
    case 'socks5':
      return convertSocks5(p, tag)
    case 'anytls':
      return convertAnytls(p, tag)
    case 'direct':
      return { outbound: { type: 'direct', tag } }
    default:
      return {
        warning: `proxy "${tag}": type "${type || 'unknown'}" is not supported by sing-box, skipped`
      }
  }
}

/* ---------------------------- proxy groups -------------------------------- */

interface GroupBuild {
  outbounds: Dict[]
  groupTags: string[]
  warnings: string[]
}

function resolveGroupMembers(
  group: Dict,
  groupName: string,
  allProxyNames: string[],
  knownTags: Set<string>,
  groupNames: Set<string>,
  warnings: string[]
): string[] {
  let members = toStrArray(group.proxies)
  if (toBool(group['include-all']) === true || toBool(group['include-all-proxies']) === true) {
    members = [...members, ...allProxyNames]
  }
  if (toStrArray(group.use).length > 0) {
    warnings.push(`group "${groupName}": proxy-providers (use) are not supported, entries skipped`)
  }

  const filter = toStr(group.filter)
  const excludeFilter = toStr(group['exclude-filter'])
  const applyRegex = (list: string[], pattern: string, keep: boolean): string[] => {
    try {
      const re = new RegExp(pattern)
      return list.filter((name) => (keep ? re.test(name) : !re.test(name)))
    } catch {
      warnings.push(`group "${groupName}": invalid filter regex "${pattern}", ignored`)
      return list
    }
  }

  const resolved: string[] = []
  const seen = new Set<string>()
  for (const raw of members) {
    let name = raw
    if (name === 'DIRECT') name = 'direct'
    else if (
      name === 'REJECT' ||
      name === 'REJECT-DROP' ||
      name === 'PASS' ||
      name === 'COMPATIBLE'
    ) {
      warnings.push(
        `group "${groupName}": built-in policy "${name}" cannot be a sing-box group member, dropped`
      )
      continue
    }
    if (seen.has(name)) continue
    if (name !== 'direct' && !knownTags.has(name) && !groupNames.has(name)) {
      warnings.push(`group "${groupName}": member "${raw}" not found or unsupported, dropped`)
      continue
    }
    seen.add(name)
    resolved.push(name)
  }

  let filtered = resolved
  if (filter) {
    // never filter out sub-groups / direct — Clash filter applies to provider nodes,
    // but static lists are filtered too; apply to proxy names only
    filtered = filtered.filter(
      (name) =>
        name === 'direct' || groupNames.has(name) || applyRegex([name], filter, true).length > 0
    )
  }
  if (excludeFilter) {
    filtered = filtered.filter(
      (name) =>
        name === 'direct' ||
        groupNames.has(name) ||
        applyRegex([name], excludeFilter, true).length === 0
    )
  }

  if (filtered.length === 0) {
    warnings.push(`group "${groupName}": no usable members remain, padded with "direct"`)
    filtered = ['direct']
  }
  return filtered
}

const SUPPORTED_GROUP_TYPES = ['select', 'url-test', 'fallback', 'load-balance', 'smart']

function convertGroups(
  groups: Dict[],
  allProxyNames: string[],
  proxyTags: Set<string>
): GroupBuild {
  const warnings: string[] = []
  const outbounds: Dict[] = []
  const groupTags: string[] = []
  // precompute which groups will actually be emitted so member resolution
  // never references a group that ends up skipped (e.g. relay)
  const groupNames = new Set<string>()
  for (const group of groups) {
    const name = toStr(group.name)
    const type = toStr(group.type)
    if (name && type && SUPPORTED_GROUP_TYPES.includes(type) && !groupNames.has(name)) {
      groupNames.add(name)
    }
  }

  const emitted = new Set<string>()
  for (const group of groups) {
    const name = toStr(group.name)
    if (!name) {
      warnings.push('proxy-group without a name was skipped')
      continue
    }
    if (emitted.has(name)) {
      warnings.push(`group "${name}": duplicate name, skipped`)
      continue
    }
    const type = toStr(group.type)
    if (!type || !SUPPORTED_GROUP_TYPES.includes(type)) {
      if (type === 'relay') {
        warnings.push(`group "${name}": relay groups are not supported by sing-box, skipped`)
      } else {
        warnings.push(`group "${name}": type "${type || 'unknown'}" is not supported, skipped`)
      }
      continue
    }

    const memberNames = new Set([...groupNames].filter((n) => n !== name))
    const members = resolveGroupMembers(
      group,
      name,
      allProxyNames,
      proxyTags,
      memberNames,
      warnings
    )

    if (type === 'select') {
      outbounds.push(compact({ type: 'selector', tag: name, outbounds: members }))
      groupTags.push(name)
      emitted.add(name)
    } else {
      if (type === 'fallback') {
        warnings.push(`group "${name}": fallback approximated with url-test`)
      } else if (type === 'load-balance') {
        warnings.push(`group "${name}": load-balance approximated with url-test`)
      } else if (type === 'smart') {
        warnings.push(`group "${name}": smart groups are not supported, approximated with url-test`)
      }
      const interval = toNum(group.interval)
      outbounds.push(
        compact({
          type: 'urltest',
          tag: name,
          outbounds: members,
          url: toStr(group.url),
          interval: interval && interval > 0 ? `${interval}s` : undefined,
          tolerance: toNum(group.tolerance)
        })
      )
      groupTags.push(name)
      emitted.add(name)
    }
  }

  return { outbounds, groupTags, warnings }
}

/* -------------------------------- rules ----------------------------------- */

interface RuleSetRegistry {
  map: Map<string, Dict>
  get(kind: 'geosite' | 'geoip', name: string): string
}

function createRuleSetRegistry(): RuleSetRegistry {
  const map = new Map<string, Dict>()
  return {
    map,
    get(kind, name) {
      const normalized = name.toLowerCase()
      const tag = `${kind}-${normalized}`
      if (!map.has(tag)) {
        map.set(tag, {
          type: 'remote',
          tag,
          format: 'binary',
          url: `${RULE_SET_URL_BASE}/${kind}/${normalized}.srs`,
          download_detour: 'direct'
        })
      }
      return tag
    }
  }
}

/** split a logical payload "((A),(B),(C))" into top-level "(X)" chunks */
function splitLogicalPayload(payload: string): string[] | null {
  const trimmed = payload.trim()
  if (!trimmed.startsWith('(') || !trimmed.endsWith(')')) return null
  const inner = trimmed.slice(1, -1)
  const parts: string[] = []
  let depth = 0
  let current = ''
  for (const ch of inner) {
    if (ch === '(') depth++
    if (ch === ')') depth--
    if (depth < 0) return null
    if (ch === ',' && depth === 0) {
      parts.push(current)
      current = ''
      continue
    }
    current += ch
  }
  parts.push(current)
  return parts
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => (part.startsWith('(') && part.endsWith(')') ? part.slice(1, -1).trim() : part))
}

interface ConditionBuild {
  fields?: Dict
  warning?: string
}

function buildRuleCondition(
  type: string,
  payload: string,
  ruleSets: RuleSetRegistry
): ConditionBuild {
  const upper = type.toUpperCase()
  switch (upper) {
    case 'DOMAIN':
      return { fields: { domain: [payload] } }
    case 'DOMAIN-SUFFIX':
      return { fields: { domain_suffix: [payload] } }
    case 'DOMAIN-KEYWORD':
      return { fields: { domain_keyword: [payload] } }
    case 'DOMAIN-REGEX':
      return { fields: { domain_regex: [payload] } }
    case 'IP-CIDR':
    case 'IP-CIDR6':
      return { fields: { ip_cidr: [payload] } }
    case 'SRC-IP-CIDR':
      return { fields: { source_ip_cidr: [payload] } }
    case 'DST-PORT': {
      if (payload.includes('-')) {
        return { fields: { port_range: [payload.replace('-', ':')] } }
      }
      const port = toNum(payload)
      if (port === undefined) return { warning: `invalid DST-PORT payload "${payload}"` }
      return { fields: { port: [port] } }
    }
    case 'SRC-PORT': {
      if (payload.includes('-')) {
        return { fields: { source_port_range: [payload.replace('-', ':')] } }
      }
      const port = toNum(payload)
      if (port === undefined) return { warning: `invalid SRC-PORT payload "${payload}"` }
      return { fields: { source_port: [port] } }
    }
    case 'PROCESS-NAME':
      return { fields: { process_name: [payload] } }
    case 'PROCESS-PATH':
      return { fields: { process_path: [payload] } }
    case 'NETWORK':
      return { fields: { network: [payload.toLowerCase()] } }
    case 'GEOSITE':
      return { fields: { rule_set: [ruleSets.get('geosite', payload)] } }
    case 'GEOIP': {
      const code = payload.toLowerCase()
      if (code === 'lan' || code === 'private') {
        return { fields: { ip_is_private: true } }
      }
      return { fields: { rule_set: [ruleSets.get('geoip', payload)] } }
    }
    case 'AND':
    case 'OR':
    case 'NOT': {
      const sub = buildLogicalRule(upper, payload, ruleSets)
      if (sub.warning) return { warning: sub.warning }
      return { fields: sub.fields }
    }
    default:
      return { warning: `rule type "${type}" is not supported` }
  }
}

function buildLogicalRule(
  mode: 'AND' | 'OR' | 'NOT',
  payload: string,
  ruleSets: RuleSetRegistry
): ConditionBuild {
  const parts = splitLogicalPayload(payload)
  if (!parts || parts.length === 0) {
    return { warning: `invalid logical rule payload "${payload}"` }
  }
  const subRules: Dict[] = []
  for (const part of parts) {
    const idx = part.indexOf(',')
    if (idx === -1) return { warning: `invalid logical sub-rule "${part}"` }
    const subType = part.slice(0, idx).trim()
    const subPayloadFull = part.slice(idx + 1).trim()
    // strip trailing options like no-resolve on sub-rules
    const subPayload = ['AND', 'OR', 'NOT'].includes(subType.toUpperCase())
      ? subPayloadFull
      : subPayloadFull.split(',')[0].trim()
    const condition = buildRuleCondition(subType, subPayload, ruleSets)
    if (condition.warning || !condition.fields) {
      return { warning: condition.warning || `invalid logical sub-rule "${part}"` }
    }
    subRules.push(condition.fields)
  }

  if (mode === 'NOT') {
    if (subRules.length !== 1) {
      return { warning: `NOT rule must contain exactly one sub-rule: "${payload}"` }
    }
    return { fields: { ...subRules[0], invert: true } }
  }

  return {
    fields: {
      type: 'logical',
      mode: mode.toLowerCase(),
      rules: subRules
    }
  }
}

interface RulesBuild {
  routeRules: Dict[]
  ruleSets: Dict[]
  final: string
  warnings: string[]
}

function convertRules(rules: string[], knownOutbounds: Set<string>): RulesBuild {
  const warnings: string[] = []
  const routeRules: Dict[] = []
  const ruleSets = createRuleSetRegistry()
  let final = 'direct'

  const mapTarget = (target: string, ruleStr: string): Dict | null => {
    if (target === 'DIRECT') return { outbound: 'direct' }
    if (target === 'REJECT') return { action: 'reject' }
    if (target === 'REJECT-DROP') return { action: 'reject', method: 'drop' }
    if (target === 'PASS') {
      warnings.push(`rule "${ruleStr}": PASS has no sing-box equivalent, skipped`)
      return null
    }
    if (knownOutbounds.has(target)) return { outbound: target }
    warnings.push(`rule "${ruleStr}": target "${target}" not found or unsupported, rule skipped`)
    return null
  }

  for (const raw of rules) {
    const ruleStr = typeof raw === 'string' ? raw.trim() : String(raw)
    if (!ruleStr) continue

    const firstComma = ruleStr.indexOf(',')
    if (firstComma === -1) {
      warnings.push(`rule "${ruleStr}" could not be parsed, skipped`)
      continue
    }
    const type = ruleStr.slice(0, firstComma).trim()
    const upper = type.toUpperCase()

    if (upper === 'MATCH') {
      const target = ruleStr.slice(firstComma + 1).trim()
      if (target === 'DIRECT') final = 'direct'
      else if (target === 'REJECT' || target === 'REJECT-DROP') {
        // an always-reject final: model as catch-all reject rule
        routeRules.push({ action: 'reject' })
      } else if (knownOutbounds.has(target)) final = target
      else warnings.push(`MATCH target "${target}" not found, falling back to direct`)
      continue
    }

    if (upper === 'RULE-SET') {
      warnings.push(`rule "${ruleStr}": Clash rule-providers are not supported yet, skipped`)
      continue
    }
    if (upper === 'SUB-RULE') {
      warnings.push(`rule "${ruleStr}": SUB-RULE is not supported, skipped`)
      continue
    }

    let payload: string
    let target: string
    if (upper === 'AND' || upper === 'OR' || upper === 'NOT') {
      const rest = ruleStr.slice(firstComma + 1).trim()
      const lastComma = rest.lastIndexOf(',')
      if (!rest.startsWith('(') || lastComma === -1) {
        warnings.push(`rule "${ruleStr}" could not be parsed, skipped`)
        continue
      }
      payload = rest.slice(0, lastComma).trim()
      target = rest.slice(lastComma + 1).trim()
    } else {
      const parts = ruleStr.split(',')
      if (parts.length < 3) {
        warnings.push(`rule "${ruleStr}" is incomplete, skipped`)
        continue
      }
      payload = parts[1].trim()
      target = parts[2].trim()
    }

    const condition = buildRuleCondition(type, payload, ruleSets)
    if (condition.warning || !condition.fields) {
      warnings.push(`rule "${ruleStr}": ${condition.warning || 'not convertible'}, skipped`)
      continue
    }
    const targetFields = mapTarget(target, ruleStr)
    if (!targetFields) continue

    routeRules.push({ ...condition.fields, ...targetFields })
  }

  return { routeRules, ruleSets: [...ruleSets.map.values()], final, warnings }
}

/* ------------------------------- inbounds --------------------------------- */

function buildInbounds(
  clash: Dict,
  ipv6Enabled: boolean,
  platform?: string
): { inbounds: Dict[]; warnings: string[] } {
  const warnings: string[] = []
  const inbounds: Dict[] = []
  const allowLan = toBool(clash['allow-lan']) === true
  const listen = allowLan ? (ipv6Enabled ? '::' : '0.0.0.0') : '127.0.0.1'

  const users = toStrArray(clash.authentication)
    .map((entry) => {
      const idx = entry.indexOf(':')
      if (idx === -1) return null
      return { username: entry.slice(0, idx), password: entry.slice(idx + 1) }
    })
    .filter((u): u is { username: string; password: string } => u !== null)

  const addListener = (type: string, tag: string, port: number | undefined): void => {
    if (!port || port <= 0) return
    inbounds.push(
      compact({
        type,
        tag,
        listen,
        listen_port: port,
        users: ['mixed', 'socks', 'http'].includes(type) && users.length > 0 ? users : undefined
      })
    )
  }

  addListener('mixed', 'mixed-in', toNum(clash['mixed-port']))
  addListener('socks', 'socks-in', toNum(clash['socks-port']))
  addListener('http', 'http-in', toNum(clash.port))

  const redirPort = toNum(clash['redir-port'])
  if (redirPort && redirPort > 0) {
    if (platform === 'win32') {
      warnings.push('redir-port is not supported on Windows, skipped')
    } else {
      addListener('redirect', 'redir-in', redirPort)
    }
  }
  const tproxyPort = toNum(clash['tproxy-port'])
  if (tproxyPort && tproxyPort > 0) {
    if (platform && platform !== 'linux') {
      warnings.push('tproxy-port is only supported on Linux, skipped')
    } else {
      addListener('tproxy', 'tproxy-in', tproxyPort)
    }
  }

  const tun = asDict(clash.tun)
  if (toBool(tun.enable) === true) {
    const address = ['172.19.0.1/30']
    if (ipv6Enabled) address.push('fdfe:dcba:9876::1/126')
    const stack = toStr(tun.stack)
    const inbound: Dict = compact({
      type: 'tun',
      tag: 'tun-in',
      interface_name: toStr(tun.device),
      address,
      mtu: toNum(tun.mtu) || 1500,
      auto_route: toBool(tun['auto-route']) ?? true,
      strict_route: toBool(tun['strict-route']) === true ? true : undefined,
      stack: stack && ['gvisor', 'system', 'mixed'].includes(stack) ? stack : undefined,
      route_address: toStrArray(tun['route-address']),
      route_exclude_address: toStrArray(tun['route-exclude-address']),
      endpoint_independent_nat: toBool(tun['endpoint-independent-nat']) === true ? true : undefined
    })
    if (platform === 'linux' && toBool(tun['auto-redirect']) === true) {
      inbound.auto_redirect = true
    }
    inbounds.push(inbound)
  }

  return { inbounds, warnings }
}

/* ------------------------------ main entry -------------------------------- */

const IGNORED_TOP_LEVEL_KEYS: Record<string, string> = {
  'unified-delay': 'unified-delay is mihomo-specific, ignored',
  'tcp-concurrent': 'tcp-concurrent is mihomo-specific, ignored',
  'find-process-mode': 'find-process-mode is mihomo-specific, ignored (process rules still work)',
  'geodata-mode': 'geodata-mode is mihomo-specific, ignored (rule-sets are used instead)',
  'geo-auto-update': 'geo-auto-update is mihomo-specific, ignored',
  'geox-url': 'geox-url is mihomo-specific, ignored',
  'keep-alive-interval': 'keep-alive-interval is mihomo-specific, ignored',
  'proxy-providers': 'Clash proxy-providers are not supported yet, ignored',
  'rule-providers': 'Clash rule-providers are not supported yet, ignored',
  listeners: 'Clash listeners are not supported, ignored',
  tunnels: 'Clash tunnels are not supported, ignored'
}

export function convertClashToSingbox(
  clash: Dict,
  options: ISingboxConvertOptions = {}
): ISingboxConvertResult {
  const warnings: string[] = []
  const input = asDict(clash)
  const platform = options.platform

  const ipv6Enabled = toBool(input.ipv6) !== false
  const controller = deriveController(input)

  for (const [key, message] of Object.entries(IGNORED_TOP_LEVEL_KEYS)) {
    const value = input[key]
    if (value === undefined || value === null) continue
    if (
      typeof value === 'object' &&
      Object.keys(asDict(value)).length === 0 &&
      asArray(value).length === 0
    )
      continue
    if (value === false) continue
    warnings.push(message)
  }

  /* ---- outbounds ---- */
  const outbounds: Dict[] = []
  const endpoints: Dict[] = []
  const proxyTags: string[] = []
  const reserved = new Set(['direct', 'GLOBAL'])

  for (const rawProxy of asArray(input.proxies)) {
    const proxy = asDict(rawProxy)
    const name = toStr(proxy.name)
    if (name && (reserved.has(name) || proxyTags.includes(name))) {
      warnings.push(`proxy "${name}": duplicate or reserved name, skipped`)
      continue
    }
    const { outbound, endpoint, warning } = convertProxy(proxy)
    if (warning) warnings.push(warning)
    if (outbound) {
      outbounds.push(outbound)
      proxyTags.push(outbound.tag as string)
    } else if (endpoint) {
      endpoints.push(endpoint)
      proxyTags.push(endpoint.tag as string)
    }
  }

  // dialer-proxy -> detour (second pass, only when the target exists)
  const availableTags = new Set<string>(proxyTags)
  for (const rawProxy of asArray(input.proxies)) {
    const proxy = asDict(rawProxy)
    const dialer = toStr(proxy['dialer-proxy'])
    const name = toStr(proxy.name)
    if (!dialer || !name) continue
    const outbound = outbounds.find((o) => o.tag === name)
    if (outbound && availableTags.has(dialer)) {
      outbound.detour = dialer
    } else if (outbound) {
      warnings.push(`proxy "${name}": dialer-proxy "${dialer}" not found, ignored`)
    }
  }

  /* ---- groups ---- */
  const groups = asArray(input['proxy-groups']).map((g) => asDict(g))
  const groupBuild = convertGroups(groups, proxyTags, availableTags)
  warnings.push(...groupBuild.warnings)

  /* ---- GLOBAL selector (for clash_mode Global) ---- */
  const hasUserGlobal = groupBuild.groupTags.includes('GLOBAL')
  if (!hasUserGlobal) {
    const globalMembers = [...groupBuild.groupTags, ...proxyTags, 'direct']
    groupBuild.outbounds.push({
      type: 'selector',
      tag: 'GLOBAL',
      outbounds: globalMembers.length > 0 ? globalMembers : ['direct']
    })
  }

  /* ---- rules ---- */
  const knownOutbounds = new Set<string>([
    'direct',
    'GLOBAL',
    ...proxyTags,
    ...groupBuild.groupTags
  ])
  const ruleStrings = asArray(input.rules).map((r) => (typeof r === 'string' ? r : String(r)))
  const rulesBuild = convertRules(ruleStrings, knownOutbounds)
  warnings.push(...rulesBuild.warnings)

  /* ---- dns ---- */
  const dnsBuild = buildDns(input, ipv6Enabled)
  warnings.push(...dnsBuild.warnings)
  const dnsEnabled = toBool(asDict(input.dns).enable) === true

  /* ---- inbounds ---- */
  const inboundsBuild = buildInbounds(input, ipv6Enabled, platform)
  warnings.push(...inboundsBuild.warnings)

  /* ---- route rules (actions + clash modes + converted rules) ---- */
  const routeRules: Dict[] = []
  if (toBool(asDict(input.sniffer).enable) === true) {
    routeRules.push({ action: 'sniff' })
  }
  if (dnsEnabled) {
    routeRules.push({ protocol: 'dns', action: 'hijack-dns' })
  }
  routeRules.push({ clash_mode: 'Direct', outbound: 'direct' })
  routeRules.push({ clash_mode: 'Global', outbound: 'GLOBAL' })
  // sing-box 只把出现在规则里的 clash_mode 值加入可切换模式列表；
  // 用一条永不匹配的占位规则确保 "Rule" 模式始终可切换回来
  routeRules.push({
    clash_mode: 'Rule',
    domain: ['mode-placeholder.aikobox.invalid'],
    outbound: 'direct'
  })
  routeRules.push(...rulesBuild.routeRules)

  /* ---- assemble ---- */
  const mode = toStr(input.mode) || 'rule'
  const profile = asDict(input.profile)

  const route: Dict = compact({
    rules: routeRules,
    rule_set: rulesBuild.ruleSets,
    final: rulesBuild.final,
    auto_detect_interface: true,
    default_domain_resolver: { server: 'dns-local' },
    default_interface: toStr(input['interface-name']),
    default_mark: !platform || platform === 'linux' ? toNum(input['routing-mark']) : undefined
  })

  const config: Dict = {
    log: {
      level: mapLogLevel(input['log-level']),
      timestamp: true
    },
    dns: dnsBuild.dns,
    inbounds: inboundsBuild.inbounds,
    outbounds: [...outbounds, ...groupBuild.outbounds, { type: 'direct', tag: 'direct' }],
    route,
    experimental: {
      clash_api: compact({
        external_controller: controller.listen,
        secret: controller.secret || undefined,
        default_mode: mode.charAt(0).toUpperCase() + mode.slice(1).toLowerCase()
      }),
      cache_file: {
        enabled: true,
        store_fakeip: toBool(profile['store-fake-ip']) !== false
      }
    }
  }
  if (endpoints.length > 0) {
    config.endpoints = endpoints
  }

  return { config, warnings: [...new Set(warnings)], controller }
}
