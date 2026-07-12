import { createHash } from 'crypto'
import { existsSync } from 'fs'
import { readFile, stat } from 'fs/promises'
import path from 'path'
import axios, { type AxiosResponse } from 'axios'
import { parse } from '../../utils/yaml'
import {
  assertHttpUrl,
  assertSafeHttpRedirect,
  assertRemoteText,
  conditionalRequestHeaders,
  readHttpCacheMetadata,
  resolveExistingPathInside,
  writeFileAtomically,
  writeHttpCacheMetadata
} from '../../config/remoteResource'
import { compileSafeClashRegex } from './safeRegex'

type Dict = Record<string, unknown>

export interface ProxyProviderResolveOptions {
  baseDir: string
  cacheDir: string
  allowFileProviders?: boolean
  proxyPort?: number
  /** Never contact provider origins directly. A missing proxy fails closed. */
  forceProxy?: boolean
  /** Opaque profile/request scope used to prevent cross-profile cache reuse. */
  requestScope?: string
  /** Default provider User-Agent; an explicit provider header takes precedence. */
  userAgent?: string
  timeoutMs?: number
  fetchText?: (
    url: string,
    headers: Record<string, string>,
    timeoutMs: number
  ) => Promise<string | ProviderFetchResponse>
}

export interface ProxyProviderResolveResult {
  config: Dict
  warnings: string[]
  errors: string[]
}

interface ResolvedProvider {
  proxies: Dict[]
  names: string[]
}

export interface ProviderFetchResponse {
  status: number
  data: string
  headers?: Record<string, string>
}

interface ProviderLoadResult {
  content: string
  stale: boolean
}

const inflightProviderLoads = new Map<string, Promise<ProviderLoadResult>>()
const MAX_PROVIDER_PROXIES = 4096
const MAX_PROVIDER_COUNT = 64
const MAX_TOTAL_PROXIES = 10_000
const MAX_PROXY_NAME_LENGTH = 512

function providerTimeout(value: unknown): number {
  const timeout = Number(value)
  if (!Number.isFinite(timeout) || timeout <= 0) return 15000
  return Math.min(Math.max(Math.round(timeout), 1000), 2 * 60 * 1000)
}

function asDict(value: unknown): Dict {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Dict) : {}
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function stringArray(value: unknown): string[] {
  if (typeof value === 'string') return value ? [value] : []
  return asArray(value).filter((item): item is string => typeof item === 'string')
}

function providerCachePath(cacheDir: string, requestIdentity: string): string {
  return path.join(cacheDir, `${requestIdentity.slice(0, 32)}.yaml`)
}

function validProxyPort(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) > 0 && Number(value) <= 65535
}

function providerRequestIdentity(
  namespace: string,
  name: string,
  url: string,
  headers: Record<string, string>,
  options: ProxyProviderResolveOptions
): string {
  const normalizedHeaders = Object.entries(headers)
    .map(([key, value]) => [key.toLowerCase(), value] as const)
    .sort(([left], [right]) => left.localeCompare(right))
  return createHash('sha256')
    .update(
      JSON.stringify({
        version: 1,
        namespace,
        name,
        url,
        headers: normalizedHeaders,
        policy: options.forceProxy ? 'proxy-only' : 'direct-fallback',
        requestScope: options.requestScope || ''
      })
    )
    .digest('hex')
}

function normalizeHeaders(headers: AxiosResponse['headers']): Record<string, string> {
  const normalized: Record<string, string> = {}
  for (const [key, value] of Object.entries(headers as Record<string, unknown>)) {
    if (value !== undefined)
      normalized[key.toLowerCase()] = Array.isArray(value) ? value.join(', ') : String(value)
  }
  return normalized
}

async function defaultFetchText(
  url: string,
  headers: Record<string, string>,
  timeoutMs: number,
  proxyPort?: number,
  forceProxy = false
): Promise<ProviderFetchResponse> {
  assertHttpUrl(url, 'Provider URL')
  const safeHeaderNames = new Set([
    'accept',
    'accept-encoding',
    'if-modified-since',
    'if-none-match',
    'user-agent'
  ])
  const hasSensitiveHeaders = Object.keys(headers).some(
    (name) => !safeHeaderNames.has(name.toLowerCase())
  )
  const request = (throughProxy: boolean): Promise<AxiosResponse<string>> =>
    axios.get<string>(url, {
      headers,
      timeout: timeoutMs,
      signal: AbortSignal.timeout(timeoutMs),
      responseType: 'text',
      proxy:
        throughProxy && proxyPort
          ? { protocol: 'http', host: '127.0.0.1', port: proxyPort }
          : false,
      maxRedirects: 5,
      maxContentLength: 16 * 1024 * 1024,
      maxBodyLength: 16 * 1024 * 1024,
      beforeRedirect: (redirectOptions) => {
        assertSafeHttpRedirect(url, redirectOptions, 'Provider', hasSensitiveHeaders)
      },
      validateStatus: () => true,
      transformResponse: [(data) => data]
    })
  let response: AxiosResponse<string>
  if (forceProxy) {
    if (!validProxyPort(proxyPort)) {
      throw new Error('Provider proxy-only mode requires a valid local mixed proxy port')
    }
    response = await request(true)
  } else {
    try {
      response = await request(false)
      if (validProxyPort(proxyPort)) {
        const responseHeaders = normalizeHeaders(response.headers)
        let directResponseIsUsable =
          response.status === 304 || (response.status >= 200 && response.status < 300)
        if (directResponseIsUsable && response.status !== 304) {
          try {
            assertRemoteText(
              typeof response.data === 'string' ? response.data : String(response.data ?? ''),
              responseHeaders['content-type'],
              'Provider',
              16 * 1024 * 1024
            )
          } catch {
            directResponseIsUsable = false
          }
        }
        if (!directResponseIsUsable) response = await request(true)
      }
    } catch (directError) {
      if (!validProxyPort(proxyPort)) throw directError
      response = await request(true)
    }
  }
  return {
    status: response.status,
    data: typeof response.data === 'string' ? response.data : String(response.data ?? ''),
    headers: normalizeHeaders(response.headers)
  }
}

function checkedProviderHeaders(provider: Dict, defaultUserAgent?: string): Record<string, string> {
  const headers: Record<string, string> = {}
  for (const [key, value] of Object.entries(asDict(provider.header || provider.headers))) {
    const headerValue =
      typeof value === 'string' ? value : Array.isArray(value) ? value[0] : undefined
    if (typeof headerValue !== 'string') continue
    if (
      !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key) ||
      /[^\x20-\x7E]/.test(headerValue) ||
      headerValue.length > 8192
    ) {
      throw new Error(`provider header "${key}" is invalid`)
    }
    headers[key] = headerValue
  }
  if (
    defaultUserAgent &&
    !Object.keys(headers).some((name) => name.toLowerCase() === 'user-agent')
  ) {
    headers['User-Agent'] = defaultUserAgent
  }
  return headers
}

async function cachedProviderIsFresh(
  cachePath: string,
  fetchedAt: number | undefined,
  maxAgeMs: number
): Promise<boolean> {
  try {
    const timestamp = fetchedAt ?? (await stat(cachePath)).mtimeMs
    return Date.now() - timestamp < maxAgeMs
  } catch {
    return false
  }
}

async function loadHttpProvider(
  cachePath: string,
  requestIdentity: string,
  url: string,
  providerHeaders: Record<string, string>,
  maxAgeMs: number,
  options: ProxyProviderResolveOptions,
  validateSource: (content: string) => void
): Promise<ProviderLoadResult> {
  const metadataPath = `${cachePath}.http.json`
  const metadata = await readHttpCacheMetadata(metadataPath, requestIdentity)
  if (await cachedProviderIsFresh(cachePath, metadata?.fetchedAt, maxAgeMs)) {
    try {
      const content = await readFile(cachePath, 'utf8')
      validateSource(content)
      return { content, stale: false }
    } catch {
      // A fresh timestamp cannot make a corrupt payload trustworthy; refresh it below.
    }
  }

  if (options.forceProxy && !validProxyPort(options.proxyPort)) {
    if (existsSync(cachePath)) {
      const content = await readFile(cachePath, 'utf8')
      validateSource(content)
      return { content, stale: true }
    }
    throw new Error('Provider proxy-only mode requires a valid local mixed proxy port')
  }

  try {
    const headers = { ...providerHeaders, ...conditionalRequestHeaders(metadata) }
    const timeoutMs = providerTimeout(options.timeoutMs)
    const response = options.fetchText
      ? await options.fetchText(url, headers, timeoutMs)
      : await defaultFetchText(url, headers, timeoutMs, options.proxyPort, options.forceProxy)
    const normalized: ProviderFetchResponse =
      typeof response === 'string' ? { status: 200, data: response, headers: {} } : response
    const responseHeaders = Object.fromEntries(
      Object.entries(normalized.headers || {}).map(([key, value]) => [key.toLowerCase(), value])
    )

    if (normalized.status === 304) {
      if (!existsSync(cachePath)) throw new Error('provider returned 304 without a cached payload')
      const content = await readFile(cachePath, 'utf8')
      validateSource(content)
      try {
        await writeHttpCacheMetadata(metadataPath, {
          url: requestIdentity,
          etag: responseHeaders.etag || metadata?.etag,
          lastModified: responseHeaders['last-modified'] || metadata?.lastModified,
          fetchedAt: Date.now()
        })
      } catch {
        // Metadata is an optimization; a valid cached payload remains authoritative.
      }
      return { content, stale: false }
    }
    if (normalized.status < 200 || normalized.status >= 300) {
      throw new Error(`provider request returned HTTP ${normalized.status}`)
    }
    assertRemoteText(normalized.data, responseHeaders['content-type'], 'Provider', 16 * 1024 * 1024)
    validateSource(normalized.data)
    await writeFileAtomically(cachePath, normalized.data)
    try {
      await writeHttpCacheMetadata(metadataPath, {
        url: requestIdentity,
        etag: responseHeaders.etag,
        lastModified: responseHeaders['last-modified'],
        fetchedAt: Date.now()
      })
    } catch {
      // Do not discard a validated payload only because validators could not be persisted.
    }
    return { content: normalized.data, stale: false }
  } catch (error) {
    if (existsSync(cachePath)) {
      const content = await readFile(cachePath, 'utf8')
      try {
        validateSource(content)
        return { content, stale: true }
      } catch {
        // A corrupt stale cache must never hide the actual refresh failure.
      }
    }
    throw error
  }
}

export async function readProviderSource(
  name: string,
  provider: Dict,
  options: ProxyProviderResolveOptions,
  warnings: string[],
  validateSource: (content: string) => void = () => {},
  cacheNamespace = 'provider'
): Promise<string> {
  const type = String(provider.type || 'http').toLowerCase()
  if (type === 'file') {
    if (!options.allowFileProviders) {
      throw new Error(
        `${cacheNamespace}-provider "${name}" uses a local file without explicit local-profile permission`
      )
    }
    const configuredPath = String(provider.path || '').trim()
    const resolvedPath = await resolveExistingPathInside(
      options.baseDir,
      configuredPath,
      `${cacheNamespace}-provider "${name}"`
    )
    const content = await readFile(resolvedPath, 'utf8')
    validateSource(content)
    return content
  }

  if (type !== 'http') throw new Error(`provider type "${type}" is not supported`)
  const url = String(provider.url || '').trim()
  assertHttpUrl(url, `HTTP ${cacheNamespace}-provider "${name}" URL`)

  const providerHeaders = checkedProviderHeaders(provider, options.userAgent)
  const requestIdentity = providerRequestIdentity(
    cacheNamespace,
    name,
    url,
    providerHeaders,
    options
  )
  const cachePath = providerCachePath(options.cacheDir, requestIdentity)
  const intervalSeconds = Number(provider.interval)
  const maxAgeMs =
    Number.isFinite(intervalSeconds) && intervalSeconds > 0 ? intervalSeconds * 1000 : 3600000
  const existing = inflightProviderLoads.get(cachePath)
  const load =
    existing ||
    loadHttpProvider(
      cachePath,
      requestIdentity,
      url,
      providerHeaders,
      maxAgeMs,
      options,
      validateSource
    )
  if (!existing) inflightProviderLoads.set(cachePath, load)
  try {
    const result = await load
    if (result.stale) {
      warnings.push(
        `${cacheNamespace}-provider "${name}": update failed, using stale cached payload`
      )
    }
    return result.content
  } finally {
    if (!existing && inflightProviderLoads.get(cachePath) === load)
      inflightProviderLoads.delete(cachePath)
  }
}

function providerPayload(provider: Dict, source?: string): Dict[] {
  if (String(provider.type || '').toLowerCase() === 'inline') {
    return asArray(provider.payload || provider.proxies).map(asDict)
  }
  const parsed = parse<unknown>(source || '')
  const payload = Array.isArray(parsed)
    ? parsed
    : asArray(asDict(parsed).proxies || asDict(parsed).payload)
  if (payload.length > MAX_PROVIDER_PROXIES) {
    throw new Error(`provider payload exceeds ${MAX_PROVIDER_PROXIES} proxies`)
  }
  return payload.map(asDict)
}

function applyProviderOptions(
  provider: Dict,
  proxies: Dict[],
  errors: string[],
  name: string
): Dict[] {
  const override = asDict(provider.override)
  const prefix = String(override['additional-prefix'] || provider['additional-prefix'] || '')
  const suffix = String(override['additional-suffix'] || provider['additional-suffix'] || '')
  const filter = typeof provider.filter === 'string' ? provider.filter : ''
  const excludeFilter =
    typeof provider['exclude-filter'] === 'string' ? provider['exclude-filter'] : ''
  const excludedTypes = new Set(
    stringArray(provider['exclude-type']).map((type) => type.toLowerCase())
  )
  if (prefix.length > 128 || suffix.length > 128) {
    errors.push(`proxy-provider "${name}": prefix/suffix exceeds 128 characters`)
    return []
  }

  let includeRegex: RegExp | null = null
  let excludeRegex: RegExp | null = null
  try {
    if (filter) includeRegex = compileSafeClashRegex(filter)
    if (excludeFilter) excludeRegex = compileSafeClashRegex(excludeFilter)
  } catch (error) {
    errors.push(`proxy-provider "${name}": unsafe or invalid filter (${String(error)})`)
    return []
  }

  return proxies
    .filter((proxy) => {
      const proxyName = typeof proxy.name === 'string' ? proxy.name : ''
      const type = typeof proxy.type === 'string' ? proxy.type.toLowerCase() : ''
      if (
        !proxyName ||
        proxyName.length > MAX_PROXY_NAME_LENGTH ||
        !type ||
        excludedTypes.has(type)
      )
        return false
      if (includeRegex && !includeRegex.test(proxyName)) return false
      if (excludeRegex && excludeRegex.test(proxyName)) return false
      return true
    })
    .map((proxy) => ({ ...proxy, name: `${prefix}${String(proxy.name)}${suffix}` }))
}

function uniqueProviderProxies(
  providerName: string,
  proxies: Dict[],
  usedNames: Set<string>,
  warnings: string[]
): ResolvedProvider {
  const unique: Dict[] = []
  const names: string[] = []
  for (const proxy of proxies) {
    const original = String(proxy.name || '').trim()
    if (!original) continue
    let candidate = original
    if (usedNames.has(candidate)) {
      candidate = `${original} [${providerName}]`
      let suffix = 2
      while (usedNames.has(candidate)) candidate = `${original} [${providerName} ${suffix++}]`
      warnings.push(
        `proxy-provider "${providerName}": renamed duplicate "${original}" to "${candidate}"`
      )
    }
    usedNames.add(candidate)
    unique.push({ ...proxy, name: candidate })
    names.push(candidate)
  }
  return { proxies: unique, names }
}

export async function resolveProxyProviders(
  input: Dict,
  options: ProxyProviderResolveOptions
): Promise<ProxyProviderResolveResult> {
  const config = structuredClone(input)
  const warnings: string[] = []
  const errors: string[] = []
  const providerDefinitions = asDict(config['proxy-providers'])
  if (Object.keys(providerDefinitions).length === 0) return { config, warnings, errors }
  if (Object.keys(providerDefinitions).length > MAX_PROVIDER_COUNT) {
    errors.push(`profile exceeds ${MAX_PROVIDER_COUNT} proxy-providers`)
    return { config, warnings, errors }
  }

  const groups = asArray(config['proxy-groups']).map(asDict)
  const referenced = new Set<string>()
  for (const group of groups) {
    stringArray(group.use).forEach((name) => referenced.add(name))
    if (group['include-all-providers'] === true) {
      Object.keys(providerDefinitions).forEach((name) => referenced.add(name))
    }
  }

  if (referenced.size === 0 && asArray(config.proxies).length === 0) {
    errors.push('profile defines proxy-providers but no proxy group references them')
    return { config, warnings, errors }
  }

  const usedNames = new Set(
    asArray(config.proxies)
      .map(asDict)
      .map((proxy) => String(proxy.name || ''))
      .filter(Boolean)
  )
  const resolved = new Map<string, ResolvedProvider>()

  for (const name of referenced) {
    const provider = asDict(providerDefinitions[name])
    if (Object.keys(provider).length === 0) {
      errors.push(`proxy-provider "${name}" is referenced but not defined`)
      continue
    }
    try {
      const source =
        String(provider.type || '').toLowerCase() === 'inline'
          ? undefined
          : await readProviderSource(
              name,
              provider,
              options,
              warnings,
              (content) => {
                if (providerPayload(provider, content).length === 0) {
                  throw new Error('provider payload contains no proxies')
                }
              },
              'proxy'
            )
      const payload = applyProviderOptions(
        provider,
        providerPayload(provider, source),
        errors,
        name
      )
      const unique = uniqueProviderProxies(name, payload, usedNames, warnings)
      if (unique.proxies.length === 0) {
        errors.push(`proxy-provider "${name}" produced no usable proxies`)
        continue
      }
      if (usedNames.size > MAX_TOTAL_PROXIES) {
        errors.push(`resolved providers exceed ${MAX_TOTAL_PROXIES} total proxies`)
        break
      }
      resolved.set(name, unique)
    } catch (error) {
      errors.push(`proxy-provider "${name}" could not be loaded: ${String(error)}`)
    }
  }

  const providerProxies = [...resolved.values()].flatMap((provider) => provider.proxies)
  config.proxies = [...asArray(config.proxies), ...providerProxies]
  config['proxy-groups'] = groups.map((group) => {
    const use = stringArray(group.use)
    const providerNames = group['include-all-providers'] === true ? [...resolved.keys()] : use
    const resolvedNames = providerNames.flatMap((name) => resolved.get(name)?.names || [])
    const next: Dict = { ...group, proxies: [...stringArray(group.proxies), ...resolvedNames] }
    delete next.use
    delete next['include-all-providers']
    return next
  })
  delete config['proxy-providers']

  return { config, warnings, errors }
}
