import { describe, expect, it } from 'vitest'
import { CrashRestartPolicy } from './restartPolicy'

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
