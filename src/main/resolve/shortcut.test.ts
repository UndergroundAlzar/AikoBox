/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  register: vi.fn((_accelerator: string, _callback: () => void) => true),
  unregister: vi.fn(),
  emit: vi.fn(),
  notify: vi.fn(),
  warn: vi.fn(async () => {}),
  triggerFloatingWindow: vi.fn(async () => {}),
  getAppConfig: vi.fn(async () => ({ sysProxy: { enable: false } })),
  getControledMihomoConfig: vi.fn(async () => ({ tun: { enable: false } })),
  patchAppConfig: vi.fn(async () => {}),
  patchControledMihomoConfig: vi.fn(async () => {}),
  triggerSysProxy: vi.fn(async () => {}),
  setTunEnabled: vi.fn(async () => {}),
  quitWithoutCore: vi.fn(async () => {}),
  copyEnv: vi.fn(async () => {}),
  updateTrayIcon: vi.fn(async () => {})
}))

vi.mock('electron', () => ({
  app: { relaunch: vi.fn(), quit: vi.fn() },
  globalShortcut: { register: mocks.register, unregister: mocks.unregister },
  ipcMain: { emit: mocks.emit },
  Notification: class {
    show = mocks.notify
  }
}))

vi.mock('../window', () => ({ mainWindow: null, triggerMainWindow: vi.fn() }))
vi.mock('../config', () => ({
  getAppConfig: mocks.getAppConfig,
  getControledMihomoConfig: mocks.getControledMihomoConfig,
  patchAppConfig: mocks.patchAppConfig,
  patchControledMihomoConfig: mocks.patchControledMihomoConfig
}))
vi.mock('../sys/sysproxy', () => ({ triggerSysProxy: mocks.triggerSysProxy }))
vi.mock('../core/manager', () => ({
  quitWithoutCore: mocks.quitWithoutCore,
  setTunEnabled: mocks.setTunEnabled
}))
vi.mock('../../shared/i18n', () => ({ default: { t: (key: string) => key } }))
vi.mock('../utils/logger', () => ({
  createLogger: () => ({
    debug: vi.fn(async () => {}),
    info: vi.fn(async () => {}),
    warn: mocks.warn,
    error: vi.fn(async () => {})
  })
}))
vi.mock('./floatingWindow', () => ({
  floatingWindow: null,
  triggerFloatingWindow: mocks.triggerFloatingWindow
}))
vi.mock('./tray', () => ({ copyEnv: mocks.copyEnv, updateTrayIcon: mocks.updateTrayIcon }))

import { registerShortcut } from './shortcut'

async function capture(action: string): Promise<() => void> {
  await registerShortcut('', 'CommandOrControl+Alt+X', action)
  const callback = mocks.register.mock.calls.at(-1)?.[1]
  if (!callback) throw new Error(`no callback registered for ${action}`)
  return callback
}

describe('global shortcut handlers', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('contains a rejecting floating-window handler instead of crashing the process', async () => {
    mocks.triggerFloatingWindow.mockRejectedValueOnce(new Error('window creation failed'))
    const callback = await capture('showFloatingWindowShortcut')

    expect(callback()).toBeUndefined()
    await vi.waitFor(() => expect(mocks.warn).toHaveBeenCalledOnce())
  })

  it('contains a config read that rejects before the handler try block', async () => {
    mocks.getAppConfig.mockRejectedValueOnce(new Error('config.yaml unreadable'))
    const callback = await capture('triggerSysProxyShortcut')

    expect(callback()).toBeUndefined()
    await vi.waitFor(() => expect(mocks.warn).toHaveBeenCalledOnce())
    expect(mocks.triggerSysProxy).not.toHaveBeenCalled()
  })

  it.each([
    ['ruleModeShortcut', 'rule'],
    ['globalModeShortcut', 'global'],
    ['directModeShortcut', 'direct']
  ])('contains a rejecting %s handler', async (action, mode) => {
    mocks.patchControledMihomoConfig.mockRejectedValueOnce(new Error('write failed'))
    const callback = await capture(action)

    expect(callback()).toBeUndefined()
    await vi.waitFor(() => expect(mocks.warn).toHaveBeenCalledOnce())
    expect(mocks.patchControledMihomoConfig).toHaveBeenCalledWith({ mode })
  })

  it('still performs the action when nothing rejects', async () => {
    const callback = await capture('copyEnvShortcut')

    expect(callback()).toBeUndefined()
    await vi.waitFor(() => expect(mocks.copyEnv).toHaveBeenCalledOnce())
    expect(mocks.warn).not.toHaveBeenCalled()
  })
})
