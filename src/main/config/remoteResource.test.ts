import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  assertHttpUrl,
  assertSafeHttpRedirect,
  assertRemoteText,
  conditionalRequestHeaders,
  readHttpCacheMetadata,
  resolveExistingPathInside,
  writeFileAtomically,
  writeHttpCacheMetadata
} from './remoteResource'

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'aikobox-remote-resource-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

describe('remote resource safety', () => {
  it('accepts only HTTP(S) URLs and detects HTML or binary responses', () => {
    expect(assertHttpUrl('https://example.invalid/sub').protocol).toBe('https:')
    expect(() => assertHttpUrl('file:///etc/passwd')).toThrow(/http or https/)
    expect(() =>
      assertRemoteText('<!doctype html><title>403</title>', 'text/plain', 'sub')
    ).toThrow(/HTML error page/)
    expect(() => assertRemoteText('proxies: []', 'text/html', 'sub')).toThrow(/returned HTML/)
    expect(() => assertRemoteText('binary', 'application/zip', 'sub')).toThrow(/content type/)
  })

  it('blocks HTTPS downgrade and cross-origin redirects carrying secrets', () => {
    expect(() =>
      assertSafeHttpRedirect(
        'https://airport.example/sub',
        { href: 'http://airport.example/sub2' },
        'Subscription'
      )
    ).toThrow(/downgrade/)
    expect(() =>
      assertSafeHttpRedirect(
        'https://airport.example/sub',
        { href: 'https://cdn.example/sub2' },
        'Subscription',
        true
      )
    ).toThrow(/across origins/)
    expect(() =>
      assertSafeHttpRedirect(
        'https://airport.example/sub',
        { href: 'https://cdn.example/sub2' },
        'Subscription'
      )
    ).not.toThrow()
  })

  it('writes atomically and round-trips conditional request metadata', async () => {
    const target = join(root, 'nested', 'profile.yaml')
    await writeFileAtomically(target, 'old')
    await writeFileAtomically(target, 'new')
    expect(readFileSync(target, 'utf8')).toBe('new')

    const metadataPath = `${target}.http.json`
    await writeHttpCacheMetadata(metadataPath, {
      url: 'https://example.invalid/sub',
      etag: '"abc"',
      lastModified: 'Wed, 01 Jan 2025 00:00:00 GMT',
      fetchedAt: 1
    })
    const metadata = await readHttpCacheMetadata(metadataPath, 'https://example.invalid/sub')
    expect(conditionalRequestHeaders(metadata)).toEqual({
      'If-None-Match': '"abc"',
      'If-Modified-Since': 'Wed, 01 Jan 2025 00:00:00 GMT'
    })
    expect(
      await readHttpCacheMetadata(metadataPath, 'https://example.invalid/other')
    ).toBeUndefined()
  })

  it('blocks traversal, absolute paths, and symlink escapes', async () => {
    const base = join(root, 'base')
    const outside = join(root, 'outside')
    mkdirSync(base)
    mkdirSync(outside)
    writeFileSync(join(base, 'inside.yaml'), 'payload: []')
    writeFileSync(join(outside, 'secret.yaml'), 'secret')
    expect(await resolveExistingPathInside(base, 'inside.yaml', 'provider')).toBe(
      realpathSync.native(join(base, 'inside.yaml'))
    )
    await expect(
      resolveExistingPathInside(base, '..\\outside\\secret.yaml', 'provider')
    ).rejects.toThrow(/escapes/)
    await expect(
      resolveExistingPathInside(base, join(outside, 'secret.yaml'), 'provider')
    ).rejects.toThrow(/must be relative/)

    const link = join(base, 'escape.yaml')
    symlinkSync(join(outside, 'secret.yaml'), link, 'file')
    await expect(resolveExistingPathInside(base, 'escape.yaml', 'provider')).rejects.toThrow(
      /escapes/
    )
  })
})
