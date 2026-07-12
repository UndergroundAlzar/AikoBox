import { beforeEach, describe, expect, it, vi } from 'vitest'

describe('healthy proxy endpoint registry', () => {
  beforeEach(() => vi.resetModules())

  it('exposes only an endpoint that has passed readiness checks', async () => {
    const registry = await import('./healthyProxyEndpoint')
    registry.setHealthyProxyEndpoint('127.0.0.1', 17890)
    expect(registry.getHealthyProxyEndpoint()).toBeNull()
    registry.setHealthyProxyReady(true)
    expect(registry.getHealthyProxyEndpoint()).toEqual({ host: '127.0.0.1', port: 17890 })
    registry.setHealthyProxyReady(false)
    expect(registry.getHealthyProxyEndpoint()).toBeNull()
  })

  it('rejects invalid endpoints', async () => {
    const registry = await import('./healthyProxyEndpoint')
    expect(() => registry.setHealthyProxyEndpoint('', 7890)).toThrow(/Invalid/)
    expect(() => registry.setHealthyProxyEndpoint('127.0.0.1', 0)).toThrow(/Invalid/)
  })
})
