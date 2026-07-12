export function deriveProxyPortFromSingboxConfig(
  config: Record<string, unknown>
): number | undefined {
  const inbounds = Array.isArray(config.inbounds) ? config.inbounds : []
  const preferredTypes = ['mixed', 'http', 'socks']
  for (const type of preferredTypes) {
    const inbound = inbounds.find(
      (value) =>
        value &&
        typeof value === 'object' &&
        (value as Record<string, unknown>).type === type &&
        Number.isInteger((value as Record<string, unknown>).listen_port)
    ) as Record<string, unknown> | undefined
    const port = inbound?.listen_port
    if (typeof port === 'number' && port > 0 && port <= 65535) return port
  }
  return undefined
}
