/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('axios', () => ({ default: { get: mocks.get } }))
import { resolveProxyProviders } from './providerResolver'

let root = ''
afterEach(() => {
  mocks.get.mockReset()
  if (root) rmSync(root, { recursive: true, force: true })
})

describe('provider network bootstrap', () => {
  it('tries direct first and then the healthy local proxy endpoint', async () => {
    root = mkdtempSync(join(tmpdir(), 'aikobox-provider-network-'))
    mocks.get.mockRejectedValueOnce(new Error('direct blocked')).mockResolvedValueOnce({
      status: 200,
      data: 'proxies:\n  - { name: HK, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n',
      headers: { 'content-type': 'text/yaml' }
    })

    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          airport: { type: 'http', url: 'https://airport.example/provider.yaml' }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      },
      { baseDir: root, cacheDir: join(root, 'cache'), proxyPort: 17890 }
    )

    expect(result.errors).toEqual([])
    expect(mocks.get).toHaveBeenCalledTimes(2)
    expect(mocks.get.mock.calls[0][1].proxy).toBe(false)
    expect(mocks.get.mock.calls[1][1].proxy).toEqual({
      protocol: 'http',
      host: '127.0.0.1',
      port: 17890
    })
  })

  it('retries through the proxy when direct traffic receives a captive HTML response', async () => {
    root = mkdtempSync(join(tmpdir(), 'aikobox-provider-network-'))
    mocks.get
      .mockResolvedValueOnce({
        status: 200,
        data: '<!doctype html><title>Login</title>',
        headers: { 'content-type': 'text/html' }
      })
      .mockResolvedValueOnce({
        status: 200,
        data: 'proxies:\n  - { name: HK, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n',
        headers: { 'content-type': 'text/yaml' }
      })

    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          airport: { type: 'http', url: 'https://airport.example/provider.yaml' }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      },
      { baseDir: root, cacheDir: join(root, 'cache'), proxyPort: 17890 }
    )

    expect(result.errors).toEqual([])
    expect(mocks.get).toHaveBeenCalledTimes(2)
    expect(mocks.get.mock.calls[0][1].proxy).toBe(false)
    expect(mocks.get.mock.calls[1][1].proxy).toMatchObject({ port: 17890 })
  })

  it('uses only the local proxy when the profile requires proxy-only provider fetches', async () => {
    root = mkdtempSync(join(tmpdir(), 'aikobox-provider-network-'))
    mocks.get.mockResolvedValueOnce({
      status: 200,
      data: 'proxies:\n  - { name: HK, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n',
      headers: { 'content-type': 'text/yaml' }
    })

    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          airport: { type: 'http', url: 'https://airport.example/provider.yaml' }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      },
      {
        baseDir: root,
        cacheDir: join(root, 'cache'),
        proxyPort: 17890,
        forceProxy: true,
        requestScope: 'profile-a'
      }
    )

    expect(result.errors).toEqual([])
    expect(mocks.get).toHaveBeenCalledTimes(1)
    expect(mocks.get.mock.calls[0][1].proxy).toEqual({
      protocol: 'http',
      host: '127.0.0.1',
      port: 17890
    })
  })

  it('fails closed before networking when proxy-only provider mode has no valid port', async () => {
    root = mkdtempSync(join(tmpdir(), 'aikobox-provider-network-'))

    const result = await resolveProxyProviders(
      {
        'proxy-providers': {
          airport: { type: 'http', url: 'https://airport.example/provider.yaml' }
        },
        'proxy-groups': [{ name: 'Proxy', type: 'select', use: ['airport'] }]
      },
      {
        baseDir: root,
        cacheDir: join(root, 'cache'),
        proxyPort: 0,
        forceProxy: true
      }
    )

    expect(result.errors.join('\n')).toMatch(
      /proxy-only mode requires a valid local mixed proxy port/
    )
    expect(mocks.get).not.toHaveBeenCalled()
  })
})
