import { randomUUID } from 'crypto'
import { mkdir, open, readFile, realpath, rename, rm } from 'fs/promises'
import path from 'path'

export interface HttpCacheMetadata {
  url: string
  etag?: string
  lastModified?: string
  fetchedAt: number
}

const HTML_PREFIX = /^\s*(?:<!doctype\s+html\b|<html\b|<head\b|<body\b)/i

export function assertHttpUrl(value: string, label = 'URL'): URL {
  let parsed: URL
  try {
    parsed = new URL(value)
  } catch {
    throw new Error(`${label} is not a valid URL`)
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error(`${label} must use http or https`)
  }
  return parsed
}

export function assertSafeHttpRedirect(
  initialUrlValue: string,
  redirectOptions: {
    href?: string
    protocol?: string
    hostname?: string
    host?: string
    port?: string | number
    path?: string
  },
  label: string,
  hasSensitiveHeaders = false
): void {
  const initial = assertHttpUrl(initialUrlValue, label)
  const href =
    redirectOptions.href ||
    `${redirectOptions.protocol || ''}//${redirectOptions.hostname || redirectOptions.host || ''}${
      redirectOptions.port ? `:${redirectOptions.port}` : ''
    }${redirectOptions.path || '/'}`
  let next: URL
  try {
    next = new URL(href)
  } catch {
    throw new Error(`${label} redirect is not a valid URL`)
  }
  if (next.protocol !== 'http:' && next.protocol !== 'https:') {
    throw new Error(`${label} redirect uses unsupported protocol "${next.protocol}"`)
  }
  if (initial.protocol === 'https:' && next.protocol !== 'https:') {
    throw new Error(`${label} redirect may not downgrade HTTPS to HTTP`)
  }
  if (hasSensitiveHeaders && next.origin !== initial.origin) {
    throw new Error(`${label} with sensitive headers may not redirect across origins`)
  }
}

export function assertRemoteText(
  content: string,
  contentType: string | undefined,
  label: string,
  maxBytes = 32 * 1024 * 1024
): void {
  const byteLength = Buffer.byteLength(content, 'utf8')
  if (byteLength === 0) throw new Error(`${label} is empty`)
  if (byteLength > maxBytes) throw new Error(`${label} exceeds the ${maxBytes}-byte limit`)
  if (content.includes('\0')) throw new Error(`${label} contains binary data`)

  const mediaType = String(contentType || '')
    .split(';', 1)[0]
    .trim()
    .toLowerCase()
  if (mediaType === 'text/html' || mediaType === 'application/xhtml+xml') {
    throw new Error(`${label} returned HTML instead of a subscription payload`)
  }
  if (
    mediaType.startsWith('image/') ||
    mediaType.startsWith('audio/') ||
    mediaType.startsWith('video/') ||
    mediaType === 'application/pdf' ||
    mediaType === 'application/zip'
  ) {
    throw new Error(`${label} returned unsupported content type "${mediaType}"`)
  }
  if (HTML_PREFIX.test(content.slice(0, 2048))) {
    throw new Error(`${label} returned an HTML error page`)
  }
}

export async function writeFileAtomically(target: string, content: string): Promise<void> {
  await mkdir(path.dirname(target), { recursive: true })
  const temporary = path.join(
    path.dirname(target),
    `.${path.basename(target)}.${process.pid}.${randomUUID()}.tmp`
  )
  const handle = await open(temporary, 'w', 0o600)
  try {
    await handle.writeFile(content, { encoding: 'utf8' })
    await handle.sync()
  } finally {
    await handle.close()
  }
  try {
    await rename(temporary, target)
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  }
}

export async function readHttpCacheMetadata(
  metadataPath: string,
  expectedUrl: string
): Promise<HttpCacheMetadata | undefined> {
  try {
    const parsed = JSON.parse(await readFile(metadataPath, 'utf8')) as Partial<HttpCacheMetadata>
    if (
      parsed.url !== expectedUrl ||
      typeof parsed.fetchedAt !== 'number' ||
      !Number.isFinite(parsed.fetchedAt)
    ) {
      return undefined
    }
    return {
      url: parsed.url,
      fetchedAt: parsed.fetchedAt,
      etag: typeof parsed.etag === 'string' ? parsed.etag : undefined,
      lastModified: typeof parsed.lastModified === 'string' ? parsed.lastModified : undefined
    }
  } catch {
    return undefined
  }
}

export async function writeHttpCacheMetadata(
  metadataPath: string,
  metadata: HttpCacheMetadata
): Promise<void> {
  await writeFileAtomically(metadataPath, `${JSON.stringify(metadata)}\n`)
}

export function conditionalRequestHeaders(
  metadata: HttpCacheMetadata | undefined
): Record<string, string> {
  const headers: Record<string, string> = {}
  if (metadata?.etag) headers['If-None-Match'] = metadata.etag
  if (metadata?.lastModified) headers['If-Modified-Since'] = metadata.lastModified
  return headers
}

export async function resolveExistingPathInside(
  baseDir: string,
  configuredPath: string,
  label: string
): Promise<string> {
  if (!configuredPath.trim()) throw new Error(`${label} has no path`)
  if (path.isAbsolute(configuredPath)) throw new Error(`${label} path must be relative`)

  const base = await realpath(baseDir)
  const candidate = await realpath(path.resolve(base, configuredPath))
  const relative = path.relative(base, candidate)
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${label} path escapes its profile directory`)
  }
  return candidate
}
