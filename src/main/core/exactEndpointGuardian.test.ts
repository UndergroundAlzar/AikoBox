import { describe, expect, it, vi } from 'vitest'
import { ExactEndpointGuardian } from './exactEndpointGuardian'

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
