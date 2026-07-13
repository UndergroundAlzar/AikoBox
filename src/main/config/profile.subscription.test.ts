import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parse } from '../utils/yaml'

const mocks = vi.hoisted(() => ({
  root: '',
  mixedPort: 17890,
  axiosGet: vi.fn(),
  hotReload: vi.fn(),
  restart: vi.fn(),
  logger: {
    info: vi.fn(async () => {}),
    warn: vi.fn(async () => {}),
    error: vi.fn(async () => {})
  }
}))

vi.mock('electron', () => ({ app: { getVersion: () => '0.1.0' } }))
vi.mock('axios', () => ({ default: { get: mocks.axiosGet } }))
vi.mock('../utils/dirs', () => ({
  mihomoWorkDir: () => join(mocks.root, 'work'),
  mihomoProfileWorkDir: (id: string) => join(mocks.root, 'work', id),
  profileConfigPath: () => join(mocks.root, 'profile.yaml'),
  profilePath: (id: string) => join(mocks.root, 'profiles', `${id}.yaml`)
}))
vi.mock('../utils/logger', () => ({ createLogger: () => mocks.logger }))
vi.mock('../utils/age', () => ({ decryptAgeContent: async (content: string) => content }))
vi.mock('../utils/template', () => ({ defaultProfile: { proxies: [] } }))
vi.mock('../../shared/appConfig', () => ({
  DEFAULT_MIHOMO_PORTS: { mixed: 7890, socks: 7891, http: 7892 }
}))
vi.mock('../core/mihomoApi', () => ({
  mihomoCloseAllConnections: vi.fn(),
  mihomoHotReloadConfig: mocks.hotReload
}))
vi.mock('../core/manager', () => ({ restartCore: mocks.restart }))
vi.mock('../core/healthyProxyEndpoint', () => ({
  getHealthyProxyEndpoint: () =>
    mocks.mixedPort > 0 ? { host: '127.0.0.1', port: mocks.mixedPort } : null
}))
vi.mock('../core/factory', () => ({ generateProfile: vi.fn() }))
vi.mock('../core/profileUpdater', () => ({
  addProfileUpdater: vi.fn(),
  removeProfileUpdater: vi.fn()
}))
vi.mock('./app', () => ({
  getAppConfig: async () => ({
    userAgent: 'AikoBox/test',
    subscriptionTimeout: 1000,
    diffWorkDir: false
  })
}))
vi.mock('./controledMihomo', () => ({
  getControledMihomoConfig: async () => ({ 'mixed-port': mocks.mixedPort })
}))

function response(status: number, data: string, headers: Record<string, string> = {}) {
  return { status, data, headers }
}

const clashYaml =
  'proxies:\n  - { name: One, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: x }\n'

describe('remote profile subscriptions', () => {
  beforeEach(() => {
    mocks.root = mkdtempSync(join(tmpdir(), 'aikobox-profile-sub-'))
    mkdirSync(join(mocks.root, 'profiles'))
    mkdirSync(join(mocks.root, 'work'))
    writeFileSync(join(mocks.root, 'profile.yaml'), 'current: other\nitems: []\n')
    mocks.mixedPort = 17890
    vi.clearAllMocks()
    mocks.axiosGet.mockReset()
  })

  afterEach(() => {
    rmSync(mocks.root, { recursive: true, force: true })
  })

  it('persists a validated payload and then uses ETag/Last-Modified on a 304 update', async () => {
    mocks.axiosGet
      .mockResolvedValueOnce(
        response(200, clashYaml, {
          'content-type': 'text/yaml',
          etag: '"profile-v1"',
          'last-modified': 'Wed, 01 Jan 2025 00:00:00 GMT'
        })
      )
      .mockResolvedValueOnce(response(304, '', {}))
    const { createProfile } = await import('./profile')
    const item = {
      id: 'remote-1',
      type: 'remote' as const,
      name: 'Demo',
      url: 'https://example.invalid/sub'
    }

    await createProfile(item)
    const savedPath = join(mocks.root, 'profiles', 'remote-1.yaml')
    const firstSaved = readFileSync(savedPath, 'utf8')
    const parsed = parse<Record<string, unknown>>(firstSaved)
    expect((parsed.proxies as Record<string, unknown>[])[0].name).toBe('One')
    expect(parsed['proxy-groups']).toBeDefined()
    expect(parsed.rules).toEqual(['MATCH,Proxy'])
    await createProfile(item)

    expect(mocks.axiosGet.mock.calls[1][1].headers).toMatchObject({
      'If-None-Match': '"profile-v1"',
      'If-Modified-Since': 'Wed, 01 Jan 2025 00:00:00 GMT'
    })
    expect(mocks.axiosGet.mock.calls[1][1]).toMatchObject({
      maxRedirects: 5,
      timeout: 1000,
      maxContentLength: 32 * 1024 * 1024
    })
    expect(() => mocks.axiosGet.mock.calls[1][1].beforeRedirect({ protocol: 'file:' })).toThrow(
      /unsupported protocol/
    )
    expect(readFileSync(savedPath, 'utf8')).toBe(firstSaved)
  })

  it('does not forward URL credentials across redirect origins', async () => {
    mocks.axiosGet.mockResolvedValueOnce(response(200, clashYaml, { 'content-type': 'text/yaml' }))
    const { createProfile } = await import('./profile')

    await createProfile({
      id: 'basic-auth-redirect',
      type: 'remote',
      url: 'https://user:password@example.invalid/sub'
    })

    expect(() =>
      mocks.axiosGet.mock.calls[0][1].beforeRedirect({ href: 'https://cdn.example/sub' })
    ).toThrow(/sensitive headers may not redirect across origins/)
  })

  it('rejects an HTML success response and preserves the previous subscription', async () => {
    mocks.axiosGet
      .mockResolvedValueOnce(response(200, clashYaml, { 'content-type': 'text/plain' }))
      .mockResolvedValueOnce(
        response(200, '<!doctype html><title>Login</title>', { 'content-type': 'text/html' })
      )
      .mockResolvedValueOnce(
        response(200, '<!doctype html><title>Login</title>', { 'content-type': 'text/html' })
      )
    const { createProfile } = await import('./profile')
    const item = {
      id: 'remote-2',
      type: 'remote' as const,
      name: 'Demo',
      url: 'https://example.invalid/sub'
    }
    await createProfile(item)
    const savedPath = join(mocks.root, 'profiles', 'remote-2.yaml')
    const previous = readFileSync(savedPath, 'utf8')

    await expect(createProfile(item)).rejects.toThrow(/returned HTML/)
    expect(readFileSync(savedPath, 'utf8')).toBe(previous)
  })

  it('rejects non-success HTTP status without creating a profile file', async () => {
    mocks.axiosGet
      .mockResolvedValueOnce(
        response(503, 'temporarily unavailable', { 'content-type': 'text/plain' })
      )
      .mockResolvedValueOnce(
        response(503, 'temporarily unavailable', { 'content-type': 'text/plain' })
      )
    const { createProfile } = await import('./profile')

    await expect(
      createProfile({
        id: 'status-error',
        type: 'remote',
        url: 'https://example.invalid/sub'
      })
    ).rejects.toThrow(/status code 503/)
    expect(existsSync(join(mocks.root, 'profiles', 'status-error.yaml'))).toBe(false)
  })

  it('reports both direct and proxy fallback failures without leaking URLs', async () => {
    mocks.axiosGet
      .mockRejectedValueOnce(
        new Error('request failed at https://example.invalid/private-path-token/sub?token=secret')
      )
      .mockResolvedValueOnce(response(502, 'bad gateway', { 'content-type': 'text/plain' }))
    const { createProfile } = await import('./profile')

    let failure: unknown
    try {
      await createProfile({
        id: 'dual-failure',
        type: 'remote',
        url: 'https://example.invalid/private-path-token/sub?token=secret'
      })
    } catch (error) {
      failure = error
    }
    expect(failure).toBeInstanceOf(AggregateError)
    expect((failure as Error).message).toMatch(
      /failed directly \(network request failed\) and through the local proxy \(Subscription failed: Request status code 502\)/
    )
    expect((failure as Error).message).not.toContain('token=secret')
    expect((failure as Error).message).not.toContain('private-path-token')
    expect(
      (failure as AggregateError).errors.map((error) => String(error)).join('\n')
    ).not.toContain('token=secret')
    expect(mocks.logger.warn.mock.calls.flat().map(String).join('\n')).not.toContain('token=secret')
    expect(mocks.logger.warn.mock.calls.flat().map(String).join('\n')).not.toContain(
      'private-path-token'
    )
  })

  it('normalizes a Base64 URI subscription and rejects unsafe URL schemes and profile ids', async () => {
    const ss = `ss://${Buffer.from('aes-128-gcm:secret').toString('base64url')}@ss.example:8388#HK`
    mocks.axiosGet.mockResolvedValueOnce(
      response(200, Buffer.from(ss).toString('base64'), {
        'content-type': 'application/octet-stream'
      })
    )
    const { createProfile } = await import('./profile')

    await createProfile({
      id: 'base64-sub',
      type: 'remote',
      url: 'https://example.invalid/base64'
    })
    expect(readFileSync(join(mocks.root, 'profiles', 'base64-sub.yaml'), 'utf8')).toMatch(
      /proxy-groups:/
    )
    await expect(
      createProfile({ id: 'bad-url', type: 'remote', url: 'file:///C:/Windows/win.ini' })
    ).rejects.toThrow(/http or https/)
    expect(existsSync(join(mocks.root, 'profiles', 'bad-url.yaml'))).toBe(false)
    await expect(
      createProfile({ id: '..\\escape', type: 'remote', url: 'https://example.invalid/sub' })
    ).rejects.toThrow(/Invalid profile id/)
  })

  it('serializes competing URLs for one profile so the newer request wins deterministically', async () => {
    let release!: () => void
    const slowResponse = new Promise<ReturnType<typeof response>>((resolve) => {
      release = () => resolve(response(200, clashYaml, { 'content-type': 'text/yaml' }))
    })
    const newerYaml = clashYaml.replace('name: One', 'name: New')
    mocks.axiosGet
      .mockImplementationOnce(() => slowResponse)
      .mockResolvedValueOnce(response(200, newerYaml, { 'content-type': 'text/yaml' }))
    const { createProfile } = await import('./profile')

    const older = createProfile({
      id: 'same-profile',
      type: 'remote',
      url: 'https://example.invalid/old'
    })
    await vi.waitFor(() => expect(mocks.axiosGet).toHaveBeenCalledTimes(1))
    const newer = createProfile({
      id: 'same-profile',
      type: 'remote',
      url: 'https://example.invalid/new'
    })
    release()
    await Promise.all([older, newer])

    expect(mocks.axiosGet).toHaveBeenCalledTimes(2)
    const saved = parse<Record<string, unknown>>(
      readFileSync(join(mocks.root, 'profiles', 'same-profile.yaml'), 'utf8')
    )
    expect((saved.proxies as Record<string, unknown>[])[0].name).toBe('New')
    expect(saved.rules).toEqual(['MATCH,Proxy'])
  })

  it('fails closed without any direct request when proxy-only mode has no valid port', async () => {
    mocks.mixedPort = 0
    const { createProfile } = await import('./profile')

    await expect(
      createProfile({
        id: 'proxy-only-no-port',
        type: 'remote',
        url: 'https://example.invalid/sub',
        useProxy: true
      })
    ).rejects.toThrow(/proxy-only mode requires a valid local mixed proxy port/)
    expect(mocks.axiosGet).not.toHaveBeenCalled()
  })

  it('binds HTTP validators to a hashed request identity', async () => {
    mocks.axiosGet
      .mockResolvedValueOnce(
        response(200, clashYaml, { 'content-type': 'text/yaml', etag: '"token-a"' })
      )
      .mockResolvedValueOnce(response(200, clashYaml, { 'content-type': 'text/yaml' }))
    const { createProfile } = await import('./profile')
    const url = 'https://example.invalid/sub?secret=url-secret'

    await createProfile({
      id: 'request-identity',
      type: 'remote',
      url,
      authToken: 'Bearer token-a'
    })
    await createProfile({
      id: 'request-identity',
      type: 'remote',
      url,
      authToken: 'Bearer token-b'
    })

    expect(mocks.axiosGet.mock.calls[1][1].headers).not.toHaveProperty('If-None-Match')
    const metadata = readFileSync(
      join(mocks.root, 'profiles', 'request-identity.yaml.http.json'),
      'utf8'
    )
    expect(metadata).not.toContain('url-secret')
    expect(metadata).not.toContain('token-a')
    expect(metadata).not.toContain('token-b')
    expect(JSON.parse(metadata).url).toMatch(/^[a-f0-9]{64}$/)
  })

  it('restores the previous current profile after a rejected candidate fallback', async () => {
    writeFileSync(
      join(mocks.root, 'profile.yaml'),
      'current: rollback-profile\nitems:\n  - id: rollback-profile\n    type: remote\n    name: Rollback\n'
    )
    const target = join(mocks.root, 'profiles', 'rollback-profile.yaml')
    const previous = 'proxies: []\nrules:\n  - MATCH,DIRECT\n'
    writeFileSync(target, previous)
    mocks.hotReload.mockRejectedValueOnce(new Error('hot reload rejected'))
    mocks.restart
      .mockRejectedValueOnce(new Error('candidate rejected after LKG fallback'))
      .mockResolvedValueOnce(undefined)
    const { setProfileStr } = await import('./profile')

    await expect(
      setProfileStr('rollback-profile', 'proxies: []\nrules:\n  - MATCH,REJECT\n')
    ).rejects.toThrow(/candidate rejected/)

    expect(readFileSync(target, 'utf8')).toBe(previous)
    expect(mocks.restart).toHaveBeenCalledTimes(2)
  })
})
