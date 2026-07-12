import { mkdtempSync, readdirSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AutoProxyState, ManualProxyState } from './systemProxyOwnership'

const mocks = vi.hoisted(() => ({
  dataDir: '',
  manual: {
    enable: true,
    host: '127.0.0.1',
    port: 7890,
    bypass: 'localhost'
  } as ManualProxyState,
  auto: { enable: false, url: '' } as AutoProxyState,
  mode: 'manual' as 'manual' | 'auto',
  manualFailuresRemaining: 0,
  autoFailuresRemaining: 0,
  rawMarker: 'initial',
  setSystemProxy: vi.fn((value: ManualProxyState) => {
    if (mocks.manualFailuresRemaining > 0) {
      mocks.manualFailuresRemaining--
      throw new Error('manual setter failed')
    }
    mocks.manual = structuredClone(value)
  }),
  setAutoProxy: vi.fn((value: AutoProxyState) => {
    if (mocks.autoFailuresRemaining > 0) {
      mocks.autoFailuresRemaining--
      throw new Error('auto setter failed')
    }
    mocks.auto = structuredClone(value)
  }),
  startPacServer: vi.fn(async () => {}),
  stopPacServer: vi.fn(async () => {})
}))

vi.mock('electron', () => ({
  net: { isOnline: () => true }
}))

vi.mock('sysproxy-rs', () => ({
  getSystemProxy: () => structuredClone(mocks.manual),
  getAutoProxy: () => structuredClone(mocks.auto),
  setSystemProxy: mocks.setSystemProxy,
  setAutoProxy: mocks.setAutoProxy,
  triggerSystemProxy: vi.fn(),
  triggerAutoProxy: vi.fn(),
  triggerManualProxy: vi.fn()
}))

vi.mock('./windowsProxyRegistry', () => ({
  isWindowsProxyRegistrySnapshot: (value: unknown) => Boolean(value),
  captureWindowsProxyRegistry: () => ({
    version: 1,
    values: {
      state: {
        exists: true,
        kind: 'String',
        data: JSON.stringify({ manual: mocks.manual, auto: mocks.auto })
      },
      marker: { exists: true, kind: 'String', data: mocks.rawMarker }
    }
  }),
  restoreWindowsProxyRegistry: (snapshot: { values: { state: { data: string } } }) => {
    const state = JSON.parse(snapshot.values.state.data) as {
      manual: ManualProxyState
      auto: AutoProxyState
    }
    mocks.setSystemProxy(state.manual)
    mocks.setAutoProxy(state.auto)
  },
  sameWindowsProxyRegistrySnapshot: (left: unknown, right: unknown) =>
    JSON.stringify(left) === JSON.stringify(right)
}))

vi.mock('../config', () => ({
  getAppConfig: async () => ({
    sysProxy: { enable: true, mode: mocks.mode, host: '127.0.0.1', bypass: ['localhost'] }
  }),
  getControledMihomoConfig: async () => ({ 'mixed-port': 17890 })
}))

vi.mock('../resolve/server', () => ({
  pacPort: 17900,
  startPacServer: mocks.startPacServer,
  stopPacServer: mocks.stopPacServer
}))

vi.mock('../utils/dirs', () => ({
  dataDir: () => mocks.dataDir
}))

vi.mock('../utils/logger', () => ({
  proxyLogger: {
    info: vi.fn(async () => {}),
    warn: vi.fn(async () => {}),
    error: vi.fn(async () => {})
  }
}))

describe('Windows system proxy transaction', () => {
  const hasOwnershipJournal = (): boolean =>
    readdirSync(mocks.dataDir).some((name) => name.startsWith('system-proxy-owner.'))

  beforeEach(() => {
    vi.resetModules()
    vi.clearAllMocks()
    mocks.dataDir = mkdtempSync(join(tmpdir(), 'aikobox-sysproxy-'))
    mocks.manual = {
      enable: true,
      host: '127.0.0.1',
      port: 7890,
      bypass: 'localhost'
    }
    mocks.auto = { enable: false, url: '' }
    mocks.mode = 'manual'
    mocks.manualFailuresRemaining = 0
    mocks.autoFailuresRemaining = 0
    mocks.rawMarker = 'initial'
  })

  afterEach(() => {
    rmSync(mocks.dataDir, { recursive: true, force: true })
  })

  it('refuses to take over WinINET before the core is healthy', async () => {
    const { triggerSysProxy } = await import('./sysproxy')

    await expect(triggerSysProxy(true)).rejects.toThrow('before sing-box is healthy')
    expect(mocks.setSystemProxy).not.toHaveBeenCalled()
  })

  it('refuses a new proxy enable after shutdown cleanup begins', async () => {
    const {
      beginSystemProxyShutdown,
      setSystemProxyCoreEndpoint,
      setSystemProxyCoreReady,
      triggerSysProxy
    } = await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)
    beginSystemProxyShutdown()
    await expect(triggerSysProxy(true)).rejects.toThrow(/exiting/)
    expect(mocks.setSystemProxy).not.toHaveBeenCalled()
  })

  it('cancels an enable already waiting on PAC startup when shutdown begins', async () => {
    let releasePac!: () => void
    mocks.startPacServer.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          releasePac = resolve
        })
    )
    const {
      beginSystemProxyShutdown,
      setSystemProxyCoreEndpoint,
      setSystemProxyCoreReady,
      triggerSysProxy
    } = await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)

    const enabling = triggerSysProxy(true)
    await vi.waitFor(() => expect(mocks.startPacServer).toHaveBeenCalled())
    beginSystemProxyShutdown()
    releasePac()

    await expect(enabling).rejects.toThrow(/exiting/)
    expect(mocks.stopPacServer).toHaveBeenCalled()
    expect(mocks.setSystemProxy).not.toHaveBeenCalled()
    expect(hasOwnershipJournal()).toBe(false)
  })

  it('restores the exact previous proxy when AikoBox releases ownership', async () => {
    const previousManual = structuredClone(mocks.manual)
    const { setSystemProxyCoreEndpoint, setSystemProxyCoreReady, triggerSysProxy } =
      await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)

    await triggerSysProxy(true)
    expect(mocks.manual).toMatchObject({ enable: true, host: '127.0.0.1', port: 17890 })

    await triggerSysProxy(false)
    expect(mocks.manual).toEqual(previousManual)
    expect(mocks.auto).toEqual({ enable: false, url: '' })
  })

  it('uses the verified running endpoint instead of a rejected candidate port', async () => {
    const { setSystemProxyCoreEndpoint, setSystemProxyCoreReady, triggerSysProxy } =
      await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 19999)
    setSystemProxyCoreReady(true)

    await triggerSysProxy(true)
    expect(mocks.manual.port).toBe(19999)
    expect(mocks.startPacServer).toHaveBeenCalledWith(19999)
  })

  it('passes the verified LKG port to PAC mode', async () => {
    mocks.mode = 'auto'
    const { setSystemProxyCoreEndpoint, setSystemProxyCoreReady, triggerSysProxy } =
      await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 18990)
    setSystemProxyCoreReady(true)

    await triggerSysProxy(true)
    expect(mocks.startPacServer).toHaveBeenCalledWith(18990)
    expect(mocks.auto).toEqual({ enable: true, url: 'http://127.0.0.1:17900/pac' })
  })

  it('preserves a newer proxy set by another application', async () => {
    const { setSystemProxyCoreEndpoint, setSystemProxyCoreReady, triggerSysProxy } =
      await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)
    await triggerSysProxy(true)

    const external: ManualProxyState = {
      enable: true,
      host: '127.0.0.1',
      port: 10809,
      bypass: '<local>'
    }
    mocks.manual = structuredClone(external)
    await triggerSysProxy(false)

    expect(mocks.manual).toEqual(external)
  })

  it('keeps the guardian alive when raw WinINET changed but still points at AikoBox', async () => {
    const { setSystemProxyCoreEndpoint, setSystemProxyCoreReady, triggerSysProxy } =
      await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)
    await triggerSysProxy(true)
    mocks.stopPacServer.mockClear()
    mocks.rawMarker = 'external-change'

    await expect(triggerSysProxy(false)).rejects.toThrow(/still points at AikoBox/)
    expect(hasOwnershipJournal()).toBe(true)
    expect(mocks.stopPacServer).not.toHaveBeenCalled()
    expect(mocks.manual).toMatchObject({ enable: true, port: 17890 })
  })

  it('resumes the exact journaled endpoint without rewriting externally changed WinINET data', async () => {
    const {
      getStaleSystemProxyCoreEndpoint,
      recoverStaleSystemProxy,
      resumeStaleSystemProxyDependency,
      setSystemProxyCoreEndpoint,
      setSystemProxyCoreReady,
      triggerSysProxy
    } = await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)
    await triggerSysProxy(true)
    mocks.rawMarker = 'external-change'
    mocks.setSystemProxy.mockClear()

    await expect(recoverStaleSystemProxy()).rejects.toThrow(/still depends/)
    expect(getStaleSystemProxyCoreEndpoint()).toEqual({ host: '127.0.0.1', port: 17890 })
    await expect(resumeStaleSystemProxyDependency()).resolves.toBeUndefined()
    expect(mocks.setSystemProxy).not.toHaveBeenCalled()
    expect(hasOwnershipJournal()).toBe(true)
  })

  it('keeps the crash journal when a partial update and its rollback both fail', async () => {
    mocks.autoFailuresRemaining = 2
    const { setSystemProxyCoreEndpoint, setSystemProxyCoreReady, triggerSysProxy } =
      await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)

    await expect(triggerSysProxy(true)).rejects.toThrow('auto setter failed')
    expect(hasOwnershipJournal()).toBe(true)

    // A subsequent launch can retry and clear the journal once native writes work.
    mocks.autoFailuresRemaining = 0
    vi.resetModules()
    const { recoverStaleSystemProxy } = await import('./sysproxy')
    await recoverStaleSystemProxy()
    expect(hasOwnershipJournal()).toBe(false)
    expect(mocks.manual.port).toBe(7890)
  })

  it('reports synchronous restore failure so shutdown can keep the guardian alive', async () => {
    const {
      disableSysProxySync,
      setSystemProxyCoreEndpoint,
      setSystemProxyCoreReady,
      triggerSysProxy
    } = await import('./sysproxy')
    setSystemProxyCoreEndpoint('127.0.0.1', 17890)
    setSystemProxyCoreReady(true)
    await triggerSysProxy(true)
    mocks.autoFailuresRemaining = 1

    expect(disableSysProxySync()).toBe(false)
    expect(hasOwnershipJournal()).toBe(true)

    mocks.autoFailuresRemaining = 0
    await triggerSysProxy(false)
    expect(mocks.manual.port).toBe(7890)
  })
})
