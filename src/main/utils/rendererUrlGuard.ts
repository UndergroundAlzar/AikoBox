import { isForbiddenHost } from '../resolve/plugin/net-guard'

// 必须与 src/renderer/src/pages/network.tsx 的 IP_ENDPOINTS 保持一致
export const IP_INFO_ENDPOINTS = [
  'https://api.ip.sb/geoip',
  'https://ipwho.is/',
  'https://api.ipapi.is/'
]

// 必须与 src/renderer/src/pages/network.tsx 的 DEFAULT_LATENCY_TARGETS 保持一致
export const DEFAULT_LATENCY_TARGETS = [
  'https://www.google.com/generate_204',
  'https://www.cloudflare.com/cdn-cgi/trace',
  'https://github.com/'
]

// renderer 传来的 URL 一律按敌意输入处理：主进程的 net.request 跑在 defaultSession 上，
// 既没有同源策略也带着会话 cookie，不校验就等于把 SSRF 入口开给渲染进程。
export function assertPublicHttpUrl(url: unknown): string {
  if (typeof url !== 'string' || url === '') throw new Error('Invalid request URL')
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new Error('Invalid request URL')
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('Only http(s) request URLs are allowed')
  }
  if (parsed.username || parsed.password) throw new Error('Request URL must not carry credentials')
  if (isForbiddenHost(parsed.hostname)) throw new Error('Refusing to request a non-public host')
  return parsed.toString()
}

export function assertAllowedUrl(url: unknown, allowed: Iterable<string>): string {
  const target = assertPublicHttpUrl(url)
  for (const candidate of allowed) {
    let normalized: string
    try {
      normalized = new URL(candidate).toString()
    } catch {
      continue
    }
    if (normalized === target) return target
  }
  throw new Error('Request URL is not allowed')
}
