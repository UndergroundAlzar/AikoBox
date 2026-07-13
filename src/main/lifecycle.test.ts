import { beforeEach, describe, expect, it, vi } from 'vitest'

type TestEventListener = (event?: { preventDefault(): void }) => unknown

const mocks = vi.hoisted(() => ({
  appListeners: new Map<string, TestEventListener>(),
  powerListeners: new Map<string, TestEventListener>(),
  quit: vi.fn(),
  exit: vi.fn(),
  showErrorBox: vi.fn(),
  coreRunning: true,
  stopCore: vi.fn(async () => {
    mocks.coreRunning = false
  }),
  cleanupCoreWatcher: vi.fn(),
  beginSystemProxyShutdown: vi.fn(),
  cancelSystemProxyShutdown: vi.fn(),
  disableSysProxySync: vi.fn(() => true),
  triggerSysProxy: vi.fn(async () => {}),
  saveWindowState: vi.fn(),
  isCiIsolatedSmokeMode: vi.fn(() => false),
  execFileSync: vi.fn(),
  primeAdminPrivilegesCache: vi.fn(),
  appendSwitch: vi.fn()
}))

vi.mock('electron', () => ({
  app: {
    on: vi.fn((event: string, listener: TestEventListener) => {
      mocks.appListeners.set(event, listener)
    }),
    quit: mocks.quit,
    exit: mocks.exit,
    getLocale: () => 'en-US',
    getPath: () => '',
    commandLine: { appendSwitch: mocks.appendSwitch }
  },
  dialog: { showErrorBox: mocks.showErrorBox },
  powerMonitor: {
    on: vi.fn((event: string, listener: TestEventListener) => {
      mocks.powerListeners.set(event, listener)
    })
  }
}))

vi.mock('child_process', () => ({
  spawn: vi.fn(),
  exec: vi.fn(),
  execFileSync: mocks.execFileSync
}))

vi.mock('./core/manager', () => ({
  stopCore: mocks.stopCore,
  cleanupCoreWatcher: mocks.cleanupCoreWatcher
}))

vi.mock('./core/admin', () => ({
  primeAdminPrivilegesCache: mocks.primeAdminPrivilegesCache
}))

vi.mock('./sys/sysproxy', () => ({
  beginSystemProxyShutdown: mocks.beginSystemProxyShutdown,
  cancelSystemProxyShutdown: mocks.cancelSystemProxyShutdown,
  disableSysProxySync: mocks.disableSysProxySync,
  triggerSysProxy: mocks.triggerSysProxy
}))

vi.mock('./utils/ciIsolatedSmoke', () => ({
  isCiIsolatedSmokeMode: mocks.isCiIsolatedSmokeMode
}))

vi.mock('./utils/dirs', () => ({ exePath: () => 'C:\\Program Files\\AikoBox\\AikoBox.exe' }))

async function loadLifecycle(): Promise<typeof import('./lifecycle')> {
  const lifecycle = await import('./lifecycle')
  lifecycle.setLifecycleWindowStateSaver(mocks.saveWindowState)
  lifecycle.setupAppLifecycle()
  return lifecycle
}

describe('Windows session-end lifecycle safety', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.clearAllMocks()
    mocks.appListeners.clear()
    mocks.powerListeners.clear()
    mocks.isCiIsolatedSmokeMode.mockReturnValue(false)
    mocks.disableSysProxySync.mockReturnValue(true)
    mocks.triggerSysProxy.mockResolvedValue(undefined)
    mocks.coreRunning = true
    mocks.stopCore.mockImplementation(async () => {
      mocks.coreRunning = false
    })
  })

  it('blocks query-session-end and keeps the core alive when proxy restore fails', async () => {
    mocks.disableSysProxySync.mockReturnValue(false)
    mocks.triggerSysProxy.mockRejectedValue(new Error('WinINET restore failed'))
    const lifecycle = await loadLifecycle()
    const preventDefault = vi.fn()

    lifecycle.handleWindowsQuerySessionEnd({ preventDefault } as never)
    await vi.waitFor(() => expect(mocks.cancelSystemProxyShutdown).toHaveBeenCalledOnce())

    expect(preventDefault).toHaveBeenCalledOnce()
    expect(mocks.cleanupCoreWatcher).not.toHaveBeenCalled()
    expect(mocks.stopCore).not.toHaveBeenCalled()
    expect(mocks.coreRunning).toBe(true)
    expect(mocks.cancelSystemProxyShutdown).toHaveBeenCalledOnce()
    expect(mocks.quit).not.toHaveBeenCalled()
  })

  it('shares one idempotent proxy-first cleanup across both window session events', async () => {
    const lifecycle = await loadLifecycle()
    const preventDefault = vi.fn()

    lifecycle.handleWindowsQuerySessionEnd({ preventDefault } as never)
    lifecycle.handleWindowsSessionEnd()
    await vi.waitFor(() => expect(mocks.stopCore).toHaveBeenCalledOnce())

    expect(preventDefault).not.toHaveBeenCalled()
    expect(mocks.saveWindowState).toHaveBeenCalledOnce()
    expect(mocks.beginSystemProxyShutdown).toHaveBeenCalledOnce()
    expect(mocks.disableSysProxySync).toHaveBeenCalledOnce()
    expect(mocks.triggerSysProxy).toHaveBeenCalledOnce()
    expect(mocks.cleanupCoreWatcher).toHaveBeenCalledOnce()
    expect(mocks.stopCore).toHaveBeenCalledOnce()
    expect(mocks.coreRunning).toBe(false)
  })

  it('exits only after an asynchronously recovered blocked session is safe', async () => {
    mocks.disableSysProxySync.mockReturnValue(false)
    const lifecycle = await loadLifecycle()
    const preventDefault = vi.fn()

    lifecycle.handleWindowsQuerySessionEnd({ preventDefault } as never)
    lifecycle.handleWindowsQuerySessionEnd({ preventDefault } as never)
    expect(preventDefault).toHaveBeenCalledTimes(2)
    expect(mocks.stopCore).not.toHaveBeenCalled()
    await vi.waitFor(() => expect(mocks.quit).toHaveBeenCalledOnce())

    expect(mocks.stopCore).toHaveBeenCalledOnce()
    expect(mocks.quit).toHaveBeenCalledOnce()
    expect(mocks.disableSysProxySync).toHaveBeenCalledOnce()
  })

  it('preserves before-quit blocking and error reporting on restore failure', async () => {
    mocks.disableSysProxySync.mockReturnValue(false)
    mocks.triggerSysProxy.mockRejectedValue(new Error('WinINET restore failed'))
    await loadLifecycle()
    const preventDefault = vi.fn()

    await mocks.appListeners.get('before-quit')?.({ preventDefault })

    expect(preventDefault).toHaveBeenCalledOnce()
    expect(mocks.stopCore).not.toHaveBeenCalled()
    expect(mocks.showErrorBox).toHaveBeenCalledOnce()
    expect(mocks.quit).not.toHaveBeenCalled()
  })
})

describe('CI isolated smoke lifecycle skips', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.clearAllMocks()
    mocks.appListeners.clear()
    mocks.powerListeners.clear()
    mocks.isCiIsolatedSmokeMode.mockReturnValue(true)
    mocks.disableSysProxySync.mockReturnValue(true)
    mocks.triggerSysProxy.mockResolvedValue(undefined)
    mocks.coreRunning = true
    mocks.stopCore.mockImplementation(async () => {
      mocks.coreRunning = false
    })
  })

  it('skips Windows elevation fltmc probe in setupPlatformSpecifics', async () => {
    const electronVersions = process.versions as NodeJS.ProcessVersions & { electron?: string }
    const previousElectron = electronVersions.electron
    electronVersions.electron = previousElectron ?? '41.0.0'
    try {
      const lifecycle = await import('./lifecycle')
      lifecycle.setupPlatformSpecifics()

      expect(mocks.execFileSync).not.toHaveBeenCalled()
      expect(mocks.primeAdminPrivilegesCache).not.toHaveBeenCalled()
    } finally {
      if (previousElectron === undefined) delete electronVersions.electron
      else electronVersions.electron = previousElectron
    }
  })

  it('skips disableSysProxySync and triggerSysProxy during exit cleanup', async () => {
    const lifecycle = await loadLifecycle()
    const preventDefault = vi.fn()

    lifecycle.handleWindowsQuerySessionEnd({ preventDefault } as never)
    await vi.waitFor(() => expect(mocks.stopCore).toHaveBeenCalledOnce())

    expect(mocks.disableSysProxySync).not.toHaveBeenCalled()
    expect(mocks.triggerSysProxy).not.toHaveBeenCalled()
    expect(mocks.cleanupCoreWatcher).toHaveBeenCalledOnce()
    expect(mocks.stopCore).toHaveBeenCalledOnce()
    expect(preventDefault).not.toHaveBeenCalled()
  })

  it('skips disableSysProxySync on will-quit when isolated', async () => {
    await loadLifecycle()

    mocks.appListeners.get('will-quit')?.()

    expect(mocks.disableSysProxySync).not.toHaveBeenCalled()
  })
})
