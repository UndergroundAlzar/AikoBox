/**
 * Detect bind failures for inbound/controller sockets (Windows WSAEADDRINUSE + POSIX).
 */
export function isPortInUseListenError(message: string): boolean {
  const text = String(message ?? '')
  return (
    /address already in use/i.test(text) ||
    /Only one usage of each socket address/i.test(text) ||
    /EADDRINUSE/i.test(text)
  )
}

/**
 * Bilingual (zh-CN + en) guidance when mixed-port cannot bind.
 * Mentions common conflict with other proxies on 7890 and the 17890+ workaround.
 */
export function formatPortConflictUserMessage(mixedPort?: number): string {
  const portLabel =
    typeof mixedPort === 'number' && Number.isInteger(mixedPort) && mixedPort > 0
      ? ` ${mixedPort}`
      : ''
  return [
    `混合端口${portLabel}被占用（常见原因：其他代理如 Bettbox 占用 7890）。请在设置中将 mixed-port 改为 17890 或更高后重试。`,
    `Mixed-port${portLabel} is already in use (often another proxy like Bettbox on 7890). Change mixed-port in Settings to 17890 or higher, then retry.`
  ].join('\n')
}

/**
 * Map raw core listen/bind output to a user-facing message, or null if unrelated.
 */
export function mapCoreListenError(raw: string, mixedPort?: number): string | null {
  if (!isPortInUseListenError(raw)) return null
  return formatPortConflictUserMessage(mixedPort)
}
