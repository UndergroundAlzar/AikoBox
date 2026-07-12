export interface HealthyProxyEndpoint {
  host: string
  port: number
}

let endpoint: HealthyProxyEndpoint | null = null
let ready = false

export function setHealthyProxyEndpoint(host: string, port: number): void {
  if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error('Invalid healthy core proxy endpoint')
  }
  endpoint = { host, port }
}

export function setHealthyProxyReady(value: boolean): void {
  ready = value
}

export function getHealthyProxyEndpoint(): HealthyProxyEndpoint | null {
  return ready && endpoint ? { ...endpoint } : null
}
