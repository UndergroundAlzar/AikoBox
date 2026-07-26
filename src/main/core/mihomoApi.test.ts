/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

interface FakeSocket {
  url: string
  onmessage: ((e: { data: string }) => unknown) | null
  onclose: (() => unknown) | null
  onerror: ((e: unknown) => unknown) | null
}

const mocks = vi.hoisted(() => {
  const sockets: FakeSocket[] = []
  class FakeWebSocket {
    static readonly CONNECTING = 0
    static readonly OPEN = 1
    readyState = 1
    onmessage: ((e: { data: string }) => unknown) | null = null
    onclose: (() => unknown) | null = null
    onerror: ((e: unknown) => unknown) | null = null
    close = vi.fn()
    terminate = vi.fn()
    removeAllListeners = vi.fn()

    constructor(readonly url: string) {
      sockets.push(this)
    }
  }

  return {
    sockets,
    FakeWebSocket,
    send: vi.fn(),
    setToolTip: vi.fn(),
    logger: {
      debug: vi.fn(async () => {}),
      info: vi.fn(async () => {}),
      warn: vi.fn(async () => {}),
      error: vi.fn(async () => {})
    }
  }
})

vi.mock('ws', () => ({ default: mocks.FakeWebSocket }))
vi.mock('axios', () => ({ default: { create: vi.fn() } }))
vi.mock('../config', () => ({
  getAppConfig: async () => ({}),
  getControledMihomoConfig: async () => ({})
}))
vi.mock('../window', () => ({ mainWindow: { webContents: { send: mocks.send } } }))
vi.mock('../resolve/tray', () => ({ tray: { setToolTip: mocks.setToolTip } }))
vi.mock('../resolve/floatingWindow', () => ({ floatingWindow: null }))
vi.mock('../utils/calc', () => ({ calcTraffic: (n: number) => `${n}B` }))
vi.mock('../utils/logger', () => ({ createLogger: () => mocks.logger }))
vi.mock('./factory', () => ({ getRuntimeConfig: async () => ({}) }))
vi.mock('./singbox', () => ({
  getActiveController: () => ({ host: '127.0.0.1', port: 9090, secret: 's3cr3t-controller' })
}))

import { startMihomoTraffic, stopMihomoTraffic } from './mihomoApi'

describe('traffic stream frame handling', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    mocks.sockets.length = 0
    await startMihomoTraffic()
  })

  afterEach(() => {
    stopMihomoTraffic()
  })

  function currentSocket(): FakeSocket {
    const ws = mocks.sockets.at(-1)
    if (!ws?.onmessage) throw new Error('traffic socket was never wired')
    return ws
  }

  it('forwards a well-formed frame to every consumer', () => {
    currentSocket().onmessage?.({ data: JSON.stringify({ up: 1, down: 2 }) })

    expect(mocks.send).toHaveBeenCalledWith('mihomoTraffic', { up: 1, down: 2 })
  })

  it('swallows a malformed frame instead of rejecting into the process', () => {
    const ws = currentSocket()

    // A rejected promise here would reach process-level unhandled rejection
    // handling and, under Node's default, kill the main process.
    expect(ws.onmessage?.({ data: '{not json' })).toBeUndefined()
    expect(mocks.send).not.toHaveBeenCalled()

    ws.onmessage?.({ data: JSON.stringify({ up: 3, down: 4 }) })
    expect(mocks.send).toHaveBeenCalledWith('mihomoTraffic', { up: 3, down: 4 })
  })

  it('never reports the controller secret in the stream log', () => {
    expect(mocks.logger.info.mock.calls.flat().join(' ')).not.toContain('s3cr3t-controller')
  })
})
