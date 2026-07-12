import { join } from 'path'
import { pathToFileURL } from 'url'
import { describe, expect, it } from 'vitest'
import {
  isTrustedIpcSender,
  isTrustedRendererUrl,
  normalizeExternalHttpUrl
} from './electronSecurity'

const rendererRoot = join('C:\\', 'AikoBox', 'out', 'renderer')

describe('normalizeExternalHttpUrl', () => {
  it('allows normal HTTPS and HTTP browser URLs', () => {
    expect(normalizeExternalHttpUrl('https://example.com/releases?q=1')).toBe(
      'https://example.com/releases?q=1'
    )
    expect(normalizeExternalHttpUrl('http://127.0.0.1:9090/ui')).toBe('http://127.0.0.1:9090/ui')
  })

  it.each([
    'javascript:alert(1)',
    'file:///C:/Windows/System32/calc.exe',
    'data:text/html,hello',
    'mailto:test@example.com',
    'https://user:secret@example.com/',
    ' https://example.com/',
    'not a URL'
  ])('rejects unsafe external URL %s', (url) => {
    expect(normalizeExternalHttpUrl(url)).toBeNull()
  })
})

describe('trusted renderer boundary', () => {
  const mainUrl = pathToFileURL(join(rendererRoot, 'index.html')).toString()
  const floatingUrl = pathToFileURL(join(rendererRoot, 'floating.html')).toString()

  it('allows only the packaged main and floating documents', () => {
    expect(isTrustedRendererUrl(mainUrl, rendererRoot)).toBe(true)
    expect(isTrustedRendererUrl(floatingUrl, rendererRoot)).toBe(true)
    expect(
      isTrustedRendererUrl(
        pathToFileURL(join(rendererRoot, 'nested', 'index.html')).toString(),
        rendererRoot
      )
    ).toBe(false)
    expect(
      isTrustedRendererUrl(
        pathToFileURL(join(rendererRoot, '..', 'index.html')).toString(),
        rendererRoot
      )
    ).toBe(false)
  })

  it('allows the configured development origin but not a lookalike origin', () => {
    expect(
      isTrustedRendererUrl(
        'http://127.0.0.1:5173/settings',
        rendererRoot,
        'http://127.0.0.1:5173',
        true
      )
    ).toBe(true)
    expect(
      isTrustedRendererUrl('http://127.0.0.1:5174/', rendererRoot, 'http://127.0.0.1:5173', true)
    ).toBe(false)
    expect(
      isTrustedRendererUrl(
        'http://127.0.0.1:5173.evil.test/',
        rendererRoot,
        'http://127.0.0.1:5173',
        true
      )
    ).toBe(false)
  })

  it('never trusts an environment-injected development origin in packaged mode', () => {
    expect(
      isTrustedRendererUrl(
        'http://127.0.0.1:5173/settings',
        rendererRoot,
        'http://127.0.0.1:5173',
        false
      )
    ).toBe(false)
  })

  it('rejects subframes even when the main renderer is trusted', () => {
    const mainFrame = { url: mainUrl, processId: 12, routingId: 34 }
    const sender = { mainFrame, getURL: () => mainUrl }
    expect(isTrustedIpcSender({ sender, senderFrame: mainFrame }, rendererRoot)).toBe(true)
    expect(
      isTrustedIpcSender(
        { sender, senderFrame: { url: mainUrl, processId: 12, routingId: 34 } },
        rendererRoot
      )
    ).toBe(true)
    expect(
      isTrustedIpcSender(
        {
          sender,
          senderFrame: {
            url: 'https://untrusted.example/frame',
            processId: 12,
            routingId: 35
          }
        },
        rendererRoot
      )
    ).toBe(false)
  })
})
