import { parse, stringify } from '../utils/yaml'

type Dict = Record<string, unknown>

interface ProxyUriLine {
  value: string
  lineNumber: number
}

const MAX_SUBSCRIPTION_PROXIES = 10_000
const MAX_SUBSCRIPTION_PROVIDERS = 64
const MAX_SUBSCRIPTION_GROUPS = 512
const MAX_SUBSCRIPTION_RULES = 50_000
const MAX_SUBSCRIPTION_LINE_LENGTH = 16_384

const SUPPORTED_URI_SCHEMES = new Set([
  'ss',
  'vmess',
  'vless',
  'trojan',
  'hysteria',
  'hy',
  'hysteria2',
  'hy2',
  'tuic',
  'anytls',
  'shadowtls',
  'http',
  'socks',
  'socks5'
])

function asDict(value: unknown): Dict {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Dict) : {}
}

function decodeBase64(value: string): string {
  const compact = value.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/')
  if (
    !compact ||
    compact.length % 4 === 1 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(compact) ||
    compact.slice(0, -2).includes('=')
  ) {
    throw new Error('invalid Base64 data')
  }
  const padded = compact.padEnd(Math.ceil(compact.length / 4) * 4, '=')
  const bytes = Buffer.from(padded, 'base64')
  const canonical = bytes.toString('base64').replace(/=+$/, '')
  if (canonical !== compact.replace(/=+$/, '')) throw new Error('invalid Base64 data')
  const result = bytes.toString('utf8')
  if (!result || result.includes('\uFFFD') || result.includes('\0'))
    throw new Error('invalid UTF-8 Base64 data')
  return result
}

function decoded(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch {
    throw new Error('invalid percent-encoding')
  }
}

function numberPort(value: string | number | null | undefined): number {
  const port = Number(value)
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid server port')
  return port
}

function displayName(fragment: string, fallback: string): string {
  const raw = fragment.replace(/^#/, '')
  let name: string
  try {
    name = decodeURIComponent(raw)
  } catch {
    // A malformed display-only fragment must not discard an otherwise usable
    // node. Credentials and connection fields continue to use strict decoded().
    name = raw
  }
  name = name.trim()
  return name || fallback
}

function queryBool(value: string | null): boolean | undefined {
  if (value === null) return undefined
  const normalized = value.toLowerCase()
  if (['1', 'true', 'yes'].includes(normalized)) return true
  if (['0', 'false', 'no'].includes(normalized)) return false
  throw new Error(`invalid boolean value "${value}"`)
}

function applyTransport(proxy: Dict, query: URLSearchParams): void {
  let network = (query.get('type') || query.get('network') || '').toLowerCase()
  if (network === 'none') network = 'tcp'
  if (!network || network === 'tcp') return
  if (!['ws', 'grpc', 'h2', 'http'].includes(network)) {
    throw new Error(`transport "${network}" is not supported by the sing-box converter`)
  }
  proxy.network = network
  if (network === 'ws') {
    const headers: Dict = {}
    const host = query.get('host')
    if (host) headers.Host = host
    proxy['ws-opts'] = {
      path: query.get('path') || '/',
      ...(Object.keys(headers).length > 0 ? { headers } : {})
    }
  } else if (network === 'grpc') {
    proxy['grpc-opts'] = {
      'grpc-service-name': query.get('serviceName') || query.get('service-name') || ''
    }
  } else if (network === 'h2' || network === 'http') {
    const host = query.get('host')
    proxy[network === 'h2' ? 'h2-opts' : 'http-opts'] = {
      path: network === 'http' ? [query.get('path') || '/'] : query.get('path') || '/',
      ...(host ? { host: [host] } : {})
    }
  }
}

function applyTls(proxy: Dict, query: URLSearchParams, forced = false): void {
  const security = (query.get('security') || '').toLowerCase()
  if (forced || security === 'tls' || security === 'reality') proxy.tls = true
  const sni = query.get('sni') || query.get('peer')
  if (sni) proxy.servername = sni
  const fingerprint = query.get('fp')
  if (fingerprint) proxy['client-fingerprint'] = fingerprint
  const insecure = queryBool(query.get('allowInsecure') || query.get('insecure'))
  if (insecure !== undefined) proxy['skip-cert-verify'] = insecure
  const alpn = query.get('alpn')
  if (alpn) proxy.alpn = alpn.split(',').map(decoded).filter(Boolean)
  if (security === 'reality') {
    proxy['reality-opts'] = {
      'public-key': query.get('pbk') || query.get('public-key') || '',
      'short-id': query.get('sid') || query.get('short-id') || ''
    }
  }
}

function parseStandardUri(uri: string, fallback: string): Dict {
  const parsed = new URL(uri)
  const scheme = parsed.protocol.slice(0, -1).toLowerCase()
  const proxy: Dict = {
    name: displayName(parsed.hash, fallback),
    type:
      scheme === 'hy2'
        ? 'hysteria2'
        : scheme === 'hy'
          ? 'hysteria'
          : scheme === 'socks'
            ? 'socks5'
            : scheme,
    server: parsed.hostname,
    port: numberPort(parsed.port),
    udp: true
  }
  const username = decoded(parsed.username)
  const password = decoded(parsed.password)
  if (!parsed.hostname) throw new Error(`${scheme} URI is missing a server`)

  if (scheme === 'vless') {
    if (!username) throw new Error('VLESS URI is missing a UUID')
    proxy.uuid = username
    const flow = parsed.searchParams.get('flow')
    if (flow) proxy.flow = flow
    const packetEncoding =
      parsed.searchParams.get('packetEncoding') || parsed.searchParams.get('packet-encoding')
    if (packetEncoding) proxy['packet-encoding'] = packetEncoding
    applyTransport(proxy, parsed.searchParams)
    applyTls(proxy, parsed.searchParams)
    if (
      parsed.searchParams.get('security')?.toLowerCase() === 'reality' &&
      !parsed.searchParams.get('pbk') &&
      !parsed.searchParams.get('public-key')
    ) {
      throw new Error('VLESS Reality URI is missing its public key')
    }
  } else if (scheme === 'trojan') {
    proxy.password = username || password
    if (!proxy.password) throw new Error('Trojan URI is missing a password')
    applyTransport(proxy, parsed.searchParams)
    applyTls(proxy, parsed.searchParams, true)
  } else if (scheme === 'hysteria2' || scheme === 'hy2') {
    proxy.password = username || password || parsed.searchParams.get('auth') || undefined
    if (!proxy.password) throw new Error('Hysteria2 URI is missing a password')
    const ports = parsed.searchParams.get('mport') || parsed.searchParams.get('ports')
    if (ports) proxy.ports = ports
    const obfs = parsed.searchParams.get('obfs')
    const obfsPassword = parsed.searchParams.get('obfs-password')
    if (obfs) proxy.obfs = obfs
    if (obfsPassword) proxy['obfs-password'] = obfsPassword
    applyTls(proxy, parsed.searchParams, true)
  } else if (scheme === 'hysteria' || scheme === 'hy') {
    proxy['auth-str'] =
      username || password || parsed.searchParams.get('auth') || parsed.searchParams.get('auth_str')
    const up = parsed.searchParams.get('upmbps') || parsed.searchParams.get('up')
    const down = parsed.searchParams.get('downmbps') || parsed.searchParams.get('down')
    const obfs = parsed.searchParams.get('obfs')
    if (up) proxy.up = up
    if (down) proxy.down = down
    if (obfs) proxy.obfs = obfs
    applyTls(proxy, parsed.searchParams, true)
  } else if (scheme === 'tuic') {
    proxy.uuid = username
    proxy.password = password
    if (!username || !password) throw new Error('TUIC URI is missing a UUID or password')
    const congestion = parsed.searchParams.get('congestion_control')
    if (congestion) proxy['congestion-controller'] = congestion
    const udpRelay = parsed.searchParams.get('udp_relay_mode')
    if (udpRelay) proxy['udp-relay-mode'] = udpRelay
    applyTls(proxy, parsed.searchParams, true)
  } else if (scheme === 'anytls') {
    proxy.password = username || password
    if (!proxy.password) throw new Error('AnyTLS URI is missing a password')
    applyTls(proxy, parsed.searchParams, true)
  } else if (scheme === 'shadowtls') {
    proxy.password = username || password
    const version = Number(parsed.searchParams.get('version') || 3)
    if (![1, 2, 3].includes(version)) throw new Error('ShadowTLS URI has an invalid version')
    if (version > 1 && !proxy.password) throw new Error('ShadowTLS URI is missing a password')
    proxy.version = version
    applyTls(proxy, parsed.searchParams, true)
  } else if (scheme === 'http' || scheme === 'socks' || scheme === 'socks5') {
    if (username) proxy.username = username
    if (password) proxy.password = password
    if (scheme === 'http') applyTls(proxy, parsed.searchParams)
  }
  return proxy
}

function splitEndpoint(value: string): { host: string; port: number } {
  const parsed = new URL(`http://${value}`)
  return { host: parsed.hostname, port: numberPort(parsed.port) }
}

function parseShadowsocks(uri: string, fallback: string): Dict {
  const hashIndex = uri.indexOf('#')
  const fragment = hashIndex >= 0 ? uri.slice(hashIndex) : ''
  const withoutHash = hashIndex >= 0 ? uri.slice(5, hashIndex) : uri.slice(5)
  const queryIndex = withoutHash.indexOf('?')
  const query = new URLSearchParams(queryIndex >= 0 ? withoutHash.slice(queryIndex + 1) : '')
  let authority = queryIndex >= 0 ? withoutHash.slice(0, queryIndex) : withoutHash

  if (!authority.includes('@')) authority = decodeBase64(authority)
  const at = authority.lastIndexOf('@')
  if (at <= 0) throw new Error('invalid Shadowsocks URI')
  let credentials = authority.slice(0, at)
  const endpoint = authority.slice(at + 1)
  if (!credentials.includes(':')) {
    const percentDecoded = decoded(credentials)
    credentials = percentDecoded.includes(':') ? percentDecoded : decodeBase64(credentials)
  }
  const colon = credentials.indexOf(':')
  if (colon <= 0) throw new Error('invalid Shadowsocks credentials')
  const { host, port } = splitEndpoint(endpoint)
  const proxy: Dict = {
    name: displayName(fragment, fallback),
    type: 'ss',
    server: host,
    port,
    cipher: decoded(credentials.slice(0, colon)),
    password: decoded(credentials.slice(colon + 1)),
    udp: true
  }
  if (!proxy.cipher || !proxy.password) throw new Error('invalid Shadowsocks credentials')

  const plugin = query.get('plugin')
  if (plugin) {
    const [pluginName, ...optionParts] = decoded(plugin).split(';')
    proxy.plugin = pluginName === 'obfs-local' ? 'obfs' : pluginName
    const pluginOptions: Dict = {}
    for (const part of optionParts) {
      const [key, ...rest] = part.split('=')
      const value = rest.join('=')
      if (key === 'tls') pluginOptions.tls = true
      else if (key) pluginOptions[key === 'obfs' ? 'mode' : key] = value || true
    }
    proxy['plugin-opts'] = pluginOptions
  }
  return proxy
}

function parseVmess(uri: string, fallback: string): Dict {
  const encodedWithFragment = uri.slice('vmess://'.length)
  const hashIndex = encodedWithFragment.indexOf('#')
  const fragment = hashIndex >= 0 ? encodedWithFragment.slice(hashIndex) : ''
  const encoded = hashIndex >= 0 ? encodedWithFragment.slice(0, hashIndex) : encodedWithFragment
  const decodedPayload = decodeBase64(encoded)
  let parsedPayload: unknown
  try {
    parsedPayload = JSON.parse(decodedPayload)
  } catch {
    throw new Error('VMess URI contains invalid JSON')
  }
  const data = asDict(parsedPayload)
  const server = String(data.add || data.server || '')
  const uuid = String(data.id || data.uuid || '')
  if (!server || !uuid) throw new Error('VMess URI is missing server or UUID')
  const proxy: Dict = {
    name: String(data.ps || data.name || displayName(fragment, fallback)),
    type: 'vmess',
    server,
    port: numberPort(data.port as string | number),
    uuid,
    alterId: Number(data.aid || 0),
    cipher: String(data.scy || 'auto'),
    udp: true
  }
  const query = new URLSearchParams()
  const assign = (key: string, value: unknown): void => {
    if (value !== undefined && value !== null && String(value)) query.set(key, String(value))
  }
  assign('type', data.net)
  assign('host', data.host)
  assign('path', data.path)
  assign('serviceName', data.path)
  assign('security', data.tls === true ? 'tls' : data.tls)
  assign('sni', data.sni)
  assign('alpn', data.alpn)
  assign('fp', data.fp)
  assign('allowInsecure', data.allowInsecure)
  applyTransport(proxy, query)
  applyTls(proxy, query)
  return proxy
}

function parseProxyUri(uri: string, index: number): Dict {
  const schemeMatch = /^([a-z][a-z0-9+.-]*):\/\//i.exec(uri)
  if (!schemeMatch) throw new Error('not a proxy URI')
  const scheme = schemeMatch[1].toLowerCase()
  if (!SUPPORTED_URI_SCHEMES.has(scheme)) {
    throw new Error(`proxy URI scheme "${scheme}" is not supported by the sing-box converter`)
  }
  const fallback = `${scheme.toUpperCase()}-${index + 1}`
  if (scheme === 'ss') return parseShadowsocks(uri, fallback)
  if (scheme === 'vmess') return parseVmess(uri, fallback)
  return parseStandardUri(uri, fallback)
}

function proxyUriLines(content: string): ProxyUriLine[] {
  return content
    .split(/\r?\n/)
    .map((line, index) => ({ value: line.trim(), lineNumber: index + 1 }))
    .filter((line) => line.value && !line.value.startsWith('#'))
}

function hasUsableClashContent(value: unknown): value is Dict {
  const config = asDict(value)
  const proxies = Array.isArray(config.proxies) ? config.proxies : []
  const providers = asDict(config['proxy-providers'])
  return proxies.length > 0 || Object.keys(providers).length > 0
}

function assertDeclaredClashShape(value: unknown): void {
  const config = asDict(value)
  const declaresProxies = Object.hasOwn(config, 'proxies')
  const declaresProviders = Object.hasOwn(config, 'proxy-providers')
  if (!declaresProxies && !declaresProviders) return
  if (declaresProxies && !Array.isArray(config.proxies)) {
    throw new Error('Clash subscription "proxies" must be a list')
  }
  const providers = config['proxy-providers']
  if (
    declaresProviders &&
    (!providers || typeof providers !== 'object' || Array.isArray(providers))
  ) {
    throw new Error('Clash subscription "proxy-providers" must be a map')
  }
  if (!hasUsableClashContent(config)) {
    throw new Error('Subscription contains no proxy nodes or providers')
  }
}

function assertBoundedClashSubscription(config: Dict): void {
  const proxies = Array.isArray(config.proxies) ? config.proxies : []
  const providers = Object.keys(asDict(config['proxy-providers']))
  const groups = Array.isArray(config['proxy-groups']) ? config['proxy-groups'] : []
  const rules = Array.isArray(config.rules) ? config.rules : []
  if (proxies.length > MAX_SUBSCRIPTION_PROXIES)
    throw new Error(`Subscription exceeds ${MAX_SUBSCRIPTION_PROXIES} proxy nodes`)
  if (providers.length > MAX_SUBSCRIPTION_PROVIDERS)
    throw new Error(`Subscription exceeds ${MAX_SUBSCRIPTION_PROVIDERS} proxy providers`)
  if (groups.length > MAX_SUBSCRIPTION_GROUPS)
    throw new Error(`Subscription exceeds ${MAX_SUBSCRIPTION_GROUPS} proxy groups`)
  if (rules.length > MAX_SUBSCRIPTION_RULES)
    throw new Error(`Subscription exceeds ${MAX_SUBSCRIPTION_RULES} rules`)
  for (const rule of rules) {
    if (typeof rule === 'string' && rule.length > MAX_SUBSCRIPTION_LINE_LENGTH) {
      throw new Error(`Subscription rule exceeds ${MAX_SUBSCRIPTION_LINE_LENGTH} characters`)
    }
  }
}

function normalizeClashSubscription(config: Dict, original: string): string {
  const proxies = Array.isArray(config.proxies) ? config.proxies.map(asDict) : []
  const providerNames = Object.keys(asDict(config['proxy-providers']))
  const groups = Array.isArray(config['proxy-groups']) ? config['proxy-groups'].map(asDict) : []
  const rules = Array.isArray(config.rules) ? config.rules : []
  let changed = false

  if (groups.length === 0) {
    const names = proxies.map((proxy) => String(proxy.name || '')).filter(Boolean)
    if (names.length > 0 || providerNames.length > 0) {
      config['proxy-groups'] = [
        {
          name: 'Proxy',
          type: 'select',
          ...(names.length > 0 ? { proxies: names } : {}),
          ...(providerNames.length > 0 ? { use: providerNames } : {})
        }
      ]
      changed = true
    }
  }

  const effectiveGroups = Array.isArray(config['proxy-groups'])
    ? config['proxy-groups'].map(asDict)
    : []
  if (rules.length === 0 && effectiveGroups.length > 0) {
    const target = String(effectiveGroups[0].name || '')
    if (target) {
      config.rules = [`MATCH,${target}`]
      changed = true
    }
  }
  return changed ? stringify(config) : original
}

export interface NormalizedSubscription {
  content: string
  format: 'clash-yaml' | 'base64-uri-list' | 'uri-list'
  proxyCount?: number
}

export function normalizeSubscriptionPayload(content: string): NormalizedSubscription {
  let parsed: unknown
  try {
    parsed = parse<unknown>(content)
  } catch {
    parsed = undefined
  }
  assertDeclaredClashShape(parsed)
  if (hasUsableClashContent(parsed)) {
    assertBoundedClashSubscription(parsed)
    return {
      content: normalizeClashSubscription(structuredClone(parsed), content),
      format: 'clash-yaml'
    }
  }
  const directLines = proxyUriLines(content)
  let lines = directLines
  let format: NormalizedSubscription['format'] = 'uri-list'
  if (!lines.some((line) => /^[a-z][a-z0-9+.-]*:\/\//i.test(line.value))) {
    try {
      lines = proxyUriLines(decodeBase64(content))
      format = 'base64-uri-list'
    } catch {
      throw new Error('Subscription is neither Clash YAML nor a Base64 proxy URI list')
    }
  }
  if (lines.length === 0) throw new Error('Subscription contains no proxy nodes')
  if (lines.length > MAX_SUBSCRIPTION_PROXIES) {
    throw new Error(`Subscription exceeds ${MAX_SUBSCRIPTION_PROXIES} proxy nodes`)
  }
  if (lines.some((line) => line.value.length > MAX_SUBSCRIPTION_LINE_LENGTH)) {
    throw new Error(`Subscription URI exceeds ${MAX_SUBSCRIPTION_LINE_LENGTH} characters`)
  }
  if (!lines.every((line) => /^[a-z][a-z0-9+.-]*:\/\//i.test(line.value))) {
    throw new Error('Subscription is neither Clash YAML nor a Base64 proxy URI list')
  }

  const proxies = lines.map((line, index) => {
    try {
      return parseProxyUri(line.value, index)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`Subscription URI line ${line.lineNumber}: ${message}`)
    }
  })
  const usedNames = new Set<string>()
  for (const proxy of proxies) {
    const original = String(proxy.name || 'Proxy')
    let name = original
    let suffix = 2
    while (usedNames.has(name)) name = `${original} ${suffix++}`
    proxy.name = name
    usedNames.add(name)
  }
  const names = proxies.map((proxy) => String(proxy.name))
  return {
    format,
    proxyCount: proxies.length,
    content: stringify({
      proxies,
      'proxy-groups': [{ name: 'Proxy', type: 'select', proxies: names }],
      rules: ['MATCH,Proxy']
    })
  }
}
