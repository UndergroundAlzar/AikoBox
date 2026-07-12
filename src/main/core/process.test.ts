/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  getAxios: vi.fn(),
  apiGet: vi.fn()
}))

vi.mock('./mihomoApi', () => ({
  getAxios: mocks.getAxios
}))

vi.mock('./singbox', () => ({
  singboxCorePath: () => 'C:\\AikoBox\\sing-box.exe'
}))

vi.mock('../utils/logger', () => ({
  managerLogger: {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn()
  }
}))
import { waitForCoreReady } from './process'

describe('waitForCoreReady', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.clearAllMocks()
    mocks.getAxios.mockResolvedValue({ get: mocks.apiGet })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('resolves only after the Clash API answers', async () => {
    mocks.apiGet.mockRejectedValueOnce(new Error('not ready')).mockResolvedValueOnce({ data: {} })
    const ready = waitForCoreReady()

    await vi.advanceTimersByTimeAsync(100)
    await expect(ready).resolves.toBeUndefined()
    expect(mocks.apiGet).toHaveBeenCalledTimes(2)
  })

  it('rejects instead of reporting a false success after the timeout', async () => {
    mocks.apiGet.mockRejectedValue(new Error('not ready'))
    const ready = waitForCoreReady()
    const assertion = expect(ready).rejects.toThrow('Clash API was not ready')

    await vi.runAllTimersAsync()
    await assertion
    expect(mocks.apiGet).toHaveBeenCalledTimes(150)
  })
})
