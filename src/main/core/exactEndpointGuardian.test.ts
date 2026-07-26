import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ExactEndpointGuardian,
  beginExactEndpointGuardianShutdown,
  cancelExactEndpointGuardianShutdown,
  isExactEndpointGuardianShutdown
} from './exactEndpointGuardian'

describe('ExactEndpointGuardian', () => {
  const endpoint = { host: '127.0.0.1', port: 17890 }

  it('shares one recovery promise between concurrent callers', async () => {
    const guardian = new ExactEndpointGuardian()
    let healthy = false
    let release!: () => void
    const attempt = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          release = () => {
            healthy = true
            resolve()
          }
        })
    )
    const request = { endpoint, isHealthy: () => healthy, attempt, delay: async () => {} }

    const first = guardian.ensure(request)
    const second = guardian.ensure(request)
    expect(second).toBe(first)
    await vi.waitFor(() => expect(attempt).toHaveBeenCalledTimes(1))
    release()
    await Promise.all([first, second])
  })

  it('does not accept a non-exact or merely running endpoint as healthy', async () => {
    const guardian = new ExactEndpointGuardian()
    let healthyEndpoint = '127.0.0.1:7890'
    const attempt = vi.fn(async () => {
      healthyEndpoint = '127.0.0.1:17890'
    })

    await guardian.ensure({
      endpoint,
      isHealthy: () => healthyEndpoint === '127.0.0.1:17890',
      attempt,
      delay: async () => {}
    })
    expect(attempt).toHaveBeenCalledOnce()
  })

  it('adds a better same-endpoint candidate to the shared recovery pool', async () => {
    const guardian = new ExactEndpointGuardian()
    let healthy = false
    let releaseBad!: () => void
    const badAttempt = vi.fn(
      () =>
        new Promise<void>((_resolve, reject) => {
          releaseBad = () => reject(new Error('bad stored config'))
        })
    )
    const first = guardian.ensure({
      endpoint,
      isHealthy: () => healthy,
      attempt: badAttempt,
      delay: async () => {}
    })
    await vi.waitFor(() => expect(badAttempt).toHaveBeenCalledOnce())

    const goodAttempt = vi.fn(async () => {
      healthy = true
    })
    const second = guardian.ensure({
      endpoint,
      isHealthy: () => healthy,
      attempt: goodAttempt,
      delay: async () => {}
    })
    expect(second).toBe(first)
    releaseBad()
    await Promise.all([first, second])
    expect(goodAttempt).toHaveBeenCalledOnce()
  })

  it('rejects a concurrent request for a different endpoint', async () => {
    const guardian = new ExactEndpointGuardian()
    let healthy = false
    let release!: () => void
    const first = guardian.ensure({
      endpoint,
      isHealthy: () => healthy,
      attempt: () =>
        new Promise<void>((resolve) => {
          release = () => {
            healthy = true
            resolve()
          }
        }),
      delay: async () => {}
    })
    await expect(
      guardian.ensure({
        endpoint: { host: '127.0.0.1', port: 17891 },
        isHealthy: () => false,
        attempt: async () => {},
        delay: async () => {}
      })
    ).rejects.toThrow(/already recovering/i)
    release()
    await first
  })
})

describe('ExactEndpointGuardian shutdown', () => {
  const endpoint = { host: '127.0.0.1', port: 17890 }

  afterEach(() => {
    cancelExactEndpointGuardianShutdown()
  })

  it('refuses to start a recovery once shutdown has begun', async () => {
    beginExactEndpointGuardianShutdown()
    expect(isExactEndpointGuardianShutdown()).toBe(true)
    const guardian = new ExactEndpointGuardian()
    const attempt = vi.fn(async () => {})

    await expect(
      guardian.ensure({ endpoint, isHealthy: () => false, attempt, delay: async () => {} })
    ).rejects.toThrow(/shutting down/i)
    expect(attempt).not.toHaveBeenCalled()
  })

  it('stops respawning an unhealthy endpoint when shutdown starts mid-recovery', async () => {
    const guardian = new ExactEndpointGuardian()
    const attempt = vi.fn(async () => {
      beginExactEndpointGuardianShutdown()
    })

    await expect(
      guardian.ensure({ endpoint, isHealthy: () => false, attempt, delay: async () => {} })
    ).rejects.toThrow(/shutting down/i)
    expect(attempt).toHaveBeenCalledOnce()
  })

  it('does not spawn again when shutdown starts during the recovery backoff', async () => {
    const guardian = new ExactEndpointGuardian()
    const attempt = vi.fn(async () => {
      throw new Error('spawn failed')
    })

    await expect(
      guardian.ensure({
        endpoint,
        isHealthy: () => false,
        attempt,
        onAttemptError: () => {},
        delay: async () => {
          beginExactEndpointGuardianShutdown()
        }
      })
    ).rejects.toThrow(/shutting down/i)
    expect(attempt).toHaveBeenCalledOnce()
  })

  it('resumes recovery after a cancelled shutdown', async () => {
    beginExactEndpointGuardianShutdown()
    cancelExactEndpointGuardianShutdown()
    const guardian = new ExactEndpointGuardian()
    let healthy = false
    const attempt = vi.fn(async () => {
      healthy = true
    })

    await guardian.ensure({ endpoint, isHealthy: () => healthy, attempt, delay: async () => {} })
    expect(attempt).toHaveBeenCalledOnce()
  })
})
