import { beforeAll, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => {
  const registered = new Map<string, (...args: unknown[]) => void>()
  return {
    registered,
    exposed: new Map<string, unknown>(),
    on: vi.fn((channel: string, listener: (...args: unknown[]) => void) => {
      registered.set(channel, listener)
    }),
    removeListener: vi.fn(),
    sendSync: vi.fn(() => true),
    getPathForFile: vi.fn(() => 'C:\\selected.yaml')
  }
})

vi.mock('electron', () => ({
  contextBridge: {
    exposeInMainWorld: (name: string, value: unknown): void => {
      mocks.exposed.set(name, value)
    }
  },
  ipcRenderer: {
    invoke: vi.fn(),
    send: vi.fn(),
    on: mocks.on,
    removeListener: mocks.removeListener,
    sendSync: mocks.sendSync
  },
  webUtils: { getPathForFile: mocks.getPathForFile }
}))

interface ExposedElectronApi {
  ipcRenderer: {
    on(channel: string, listener: (...args: unknown[]) => void): void
    removeListener(channel: string, listener: (...args: unknown[]) => void): void
  }
}

interface ExposedApi {
  webUtils: { getPathForFile(file: File): string }
}

describe('preload IPC listener bridge', () => {
  let api: ExposedElectronApi

  beforeAll(async () => {
    Object.defineProperty(process, 'contextIsolated', { value: true, configurable: true })
    await import('./index')
    api = mocks.exposed.get('electron') as ExposedElectronApi
  })

  it('does not expose the real IpcRendererEvent to page code', () => {
    const listener = vi.fn()
    api.ipcRenderer.on('mihomoTraffic', listener)

    const realEvent = { sender: { invoke: vi.fn(), send: vi.fn() } }
    mocks.registered.get('mihomoTraffic')?.(realEvent, { up: 1, down: 2 })

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener.mock.calls[0][0]).not.toBe(realEvent)
    expect(listener.mock.calls[0][0]).not.toHaveProperty('sender')
    expect(listener.mock.calls[0][1]).toEqual({ up: 1, down: 2 })
  })

  it('removes the wrapped listener rather than leaking it', () => {
    const listener = vi.fn()
    api.ipcRenderer.on('mihomoMemory', listener)
    const registered = mocks.registered.get('mihomoMemory')

    api.ipcRenderer.removeListener('mihomoMemory', listener)

    expect(mocks.removeListener).toHaveBeenCalledWith('mihomoMemory', registered)
  })

  it('grants a one-shot main-process capability for a dropped file path', () => {
    const pageApi = mocks.exposed.get('api') as ExposedApi
    const file = {} as File
    expect(pageApi.webUtils.getPathForFile(file)).toBe('C:\\selected.yaml')
    expect(mocks.getPathForFile).toHaveBeenCalledWith(file)
    expect(mocks.sendSync).toHaveBeenCalledWith('grantSelectedFileCapability', 'C:\\selected.yaml')
  })
})
