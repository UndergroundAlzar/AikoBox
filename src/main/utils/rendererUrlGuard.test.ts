import { describe, expect, it } from 'vitest'
import {
  DEFAULT_LATENCY_TARGETS,
  IP_INFO_ENDPOINTS,
  assertAllowedUrl,
  assertPublicHttpUrl
} from './rendererUrlGuard'

describe('renderer url guard', () => {
  it('accepts the endpoints the renderer actually sends', () => {
    for (const url of [...IP_INFO_ENDPOINTS, ...DEFAULT_LATENCY_TARGETS]) {
      expect(assertAllowedUrl(url, [...IP_INFO_ENDPOINTS, ...DEFAULT_LATENCY_TARGETS])).toBe(url)
    }
  })

  it('rejects a url that is not in the allowlist', () => {
    expect(() => assertAllowedUrl('https://evil.example/', IP_INFO_ENDPOINTS)).toThrow(
      /not allowed/
    )
  })

  it('rejects the local core api even when the renderer added it as a latency target', () => {
    for (const url of [
      'http://127.0.0.1:9090/configs',
      'http://localhost:9090/',
      'http://[::1]:9090/',
      'http://169.254.169.254/latest/meta-data/',
      'http://192.168.1.1/',
      'http://10.0.0.1/'
    ]) {
      expect(() => assertAllowedUrl(url, [url])).toThrow(/non-public host/)
    }
  })

  it('rejects non-http schemes and credentials', () => {
    expect(() => assertPublicHttpUrl('file:///C:/Windows/win.ini')).toThrow(/http\(s\)/)
    expect(() => assertPublicHttpUrl('https://user:pw@example.com/')).toThrow(/credentials/)
  })

  it('rejects non-string and unparseable input', () => {
    expect(() => assertPublicHttpUrl(undefined)).toThrow(/Invalid request URL/)
    expect(() => assertPublicHttpUrl('')).toThrow(/Invalid request URL/)
    expect(() => assertPublicHttpUrl('://nope')).toThrow(/Invalid request URL/)
  })

  it('accepts a public subscription icon url', () => {
    expect(assertPublicHttpUrl('https://example.com/icon.png')).toBe('https://example.com/icon.png')
  })
})
