import { beforeEach, describe, expect, it, vi } from 'vitest'

type TestEventListener = (event?: { preventDefault(): void }) => unknown

const mocks = vi.hoisted(() => ({
  appListeners: new Map<string, TestEventListener>(),
  powerListeners: new Map<string, TestEventListener>(),
  quit: vi.fn(),
  exit: vi.fn(),
  showErrorBox: vi.fn(),
  stopCore: vi.fn(async () => {}),
  cleanupCoreWatcher: vi.fn(),
  beginSystemProxyShutdown: vi.fn(),
  cancelSystemProxyShutdown: vi.fn(),
  disableSysProxySync: vi.fn(() => true),
  triggerSysProxy: vi.fn(async () => {}),
  saveWindowState: vi.fn()
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
    commandLine: { appendSwitch: vi.fn() }
  },
  dialog: { showErrorBox: mocks.showErrorBox },
  powerMonitor: {
    on: vi.fn((event: string, listener: TestEventListener) => {
      mocks.powerListeners.set(event, listener)
    })
  }
}))

vi.mock('./core/manager', () => ({
  stopCore: mocks.stopCore,
  cleanupCoreWatcher: mocks.cleanupCoreWatcher
}))

vi.mock('./core/admin', () => ({
  primeAdminPrivilegesCache: vi.fn()
}))

vi.mock('./sys/sysproxy', () => ({
  beginSystemProxyShutdown: mocks.beginSystemProxyShutdown,
  cancelSystemProxyShutdown: mocks.cancelSystemProxyShutdown,
  disableSysProxySync: mocks.disableSysProxySync,
  triggerSysProxy: mocks.triggerSysProxy
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
    mocks.disableSysProxySync.mockReturnValue(true)
    mocks.triggerSysProxy.mockResolvedValue(undefined)
    mocks.stopCore.mockResolvedValue(undefined)
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
