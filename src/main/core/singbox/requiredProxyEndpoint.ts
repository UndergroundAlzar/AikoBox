import { isIP } from 'node:net'

export interface RequiredProxyEndpoint {
  host: string
  port: number
}

const PROXY_INBOUND_TYPES = ['mixed', 'http'] as const

export function assertRequiredProxyEndpoint(
  endpoint: RequiredProxyEndpoint
): RequiredProxyEndpoint {
  if (
    !endpoint ||
    (endpoint.host !== '127.0.0.1' && endpoint.host !== '::1') ||
    isIP(endpoint.host) === 0 ||
    !Number.isInteger(endpoint.port) ||
    endpoint.port <= 0 ||
    endpoint.port > 65535
  ) {
    throw new Error('Required system-proxy endpoint must be a valid loopback TCP endpoint')
  }
  return endpoint
}

/**
 * Pin the existing local proxy inbound to the endpoint that stale WinINET data
 * still references. No inbound is invented: recovery may adjust a previously
 * validated proxy configuration, but it must never create a direct fallback.
 */
export function pinRequiredProxyEndpoint(
  config: Record<string, unknown>,
  endpoint: RequiredProxyEndpoint
): Record<string, unknown> {
  assertRequiredProxyEndpoint(endpoint)
  if (!Array.isArray(config.inbounds)) {
    throw new Error('Recovery configuration has no sing-box inbounds')
  }

  const inbounds = config.inbounds.map((value) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return value
    return { ...(value as Record<string, unknown>) }
  })
  let selectedIndex = -1
  for (const type of PROXY_INBOUND_TYPES) {
    selectedIndex = inbounds.findIndex(
      (value) =>
        value &&
        typeof value === 'object' &&
        !Array.isArray(value) &&
        (value as Record<string, unknown>).type === type
    )
    if (selectedIndex >= 0) break
  }
  if (selectedIndex < 0) {
    throw new Error('Recovery configuration has no existing HTTP-compatible proxy inbound')
  }

  for (let index = 0; index < inbounds.length; index += 1) {
    if (index === selectedIndex) continue
    const inbound = inbounds[index]
    if (!inbound || typeof inbound !== 'object' || Array.isArray(inbound)) continue
    const candidate = inbound as Record<string, unknown>
    const listen = candidate.listen
    if (
      candidate.listen_port === endpoint.port &&
      (listen === undefined || listen === '0.0.0.0' || listen === '::' || listen === endpoint.host)
    ) {
      throw new Error('Required system-proxy port conflicts with another sing-box inbound')
    }
  }

  inbounds[selectedIndex] = {
    ...(inbounds[selectedIndex] as Record<string, unknown>),
    listen: endpoint.host,
    listen_port: endpoint.port
  }
  return { ...config, inbounds }
}

export function assertPinnedRequiredProxyEndpoint(
  config: Record<string, unknown>,
  endpoint: RequiredProxyEndpoint
): void {
  assertRequiredProxyEndpoint(endpoint)
  const inbounds = Array.isArray(config.inbounds) ? config.inbounds : []
  const matches = inbounds.filter((value) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false
    const inbound = value as Record<string, unknown>
    return (
      (inbound.type === 'mixed' || inbound.type === 'http') &&
      inbound.listen === endpoint.host &&
      inbound.listen_port === endpoint.port
    )
  })
  if (matches.length !== 1) {
    throw new Error(
      'Recovery snapshot does not contain exactly one required loopback HTTP endpoint'
    )
  }
}
