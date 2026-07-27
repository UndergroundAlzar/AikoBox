import { describe, expect, it, vi } from 'vitest'
import { CrashRestartPolicy, runRestartTransaction } from './restartPolicy'

describe('CrashRestartPolicy', () => {
  it('backs off and opens the circuit after repeated short-lived starts', () => {
    const policy = new CrashRestartPolicy({
      windowMs: 60_000,
      maxRestarts: 3,
      baseDelayMs: 100,
      maxDelayMs: 250
    })

    expect(policy.recordCrash(1_000)).toEqual({ allowed: true, crashCount: 1, delayMs: 100 })
    expect(policy.recordCrash(2_000)).toEqual({ allowed: true, crashCount: 2, delayMs: 200 })
    expect(policy.recordCrash(3_000)).toEqual({ allowed: true, crashCount: 3, delayMs: 250 })
    expect(policy.recordCrash(4_000)).toEqual({ allowed: false, crashCount: 4, delayMs: 0 })
  })

  it('recovers automatically after a stable window', () => {
    const policy = new CrashRestartPolicy({
      windowMs: 1_000,
      maxRestarts: 1,
      baseDelayMs: 10,
      maxDelayMs: 10
    })

    expect(policy.recordCrash(1_000).allowed).toBe(true)
    expect(policy.recordCrash(1_500).allowed).toBe(false)
    expect(policy.recordCrash(2_501)).toEqual({ allowed: true, crashCount: 1, delayMs: 10 })
  })

  it('rejects invalid options', () => {
    expect(() => new CrashRestartPolicy({ windowMs: 0 })).toThrow()
    expect(() => new CrashRestartPolicy({ maxRestarts: -1 })).toThrow()
    expect(() => new CrashRestartPolicy({ baseDelayMs: 10, maxDelayMs: 5 })).toThrow()
  })
})

describe('runRestartTransaction', () => {
  it('does not restart a healthy core when applying WinINET fails', async () => {
    const startCore = vi.fn(async () => undefined)
    const proxyError = new Error('registry write failed')
    const applySystemProxy = vi.fn(async () => {
      throw proxyError
    })

    await expect(
      runRestartTransaction({
        startCore,
        applySystemProxy,
        isTerminalStartError: () => false,
        onTerminalStartError: async () => undefined,
        onRetry: () => undefined,
        sleep: async () => undefined
      })
    ).rejects.toBe(proxyError)

    expect(startCore).toHaveBeenCalledOnce()
    expect(applySystemProxy).toHaveBeenCalledOnce()
  })

  it('serially retries core startup before applying the proxy once', async () => {
    const startCore = vi
      .fn<() => Promise<void>>()
      .mockRejectedValueOnce(new Error('first'))
      .mockRejectedValueOnce(new Error('second'))
      .mockResolvedValue(undefined)
    const applySystemProxy = vi.fn(async () => undefined)
    const sleep = vi.fn(async () => undefined)

    await runRestartTransaction({
      startCore,
      applySystemProxy,
      isTerminalStartError: () => false,
      onTerminalStartError: async () => undefined,
      onRetry: () => undefined,
      sleep
    })

    expect(startCore).toHaveBeenCalledTimes(3)
    expect(sleep).toHaveBeenNthCalledWith(1, 1000)
    expect(sleep).toHaveBeenNthCalledWith(2, 2000)
    expect(applySystemProxy).toHaveBeenCalledOnce()
  })
})
