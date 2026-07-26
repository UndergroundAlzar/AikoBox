export interface WebUIPanelVariables {
  host: string
  port: string
  secret: string
}

export interface ResolvedWebUIPanel {
  url: string
  hostname: string
  // 面板不在本机，打开就等于把整条 URL 交给系统浏览器和第三方站点
  isExternal: boolean
  carriesSecret: boolean
  // 密钥出现在会发给服务器的那一段（userinfo / path / query）= 远端日志里就有它，
  // 等同泄露核心控制权。只有 fragment 才不会离开浏览器。
  secretInQuery: boolean
}

// URL.hostname 对 IPv6 会保留方括号
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]', '0.0.0.0'])

/**
 * 模板里会被真正发送到远端的部分：fragment（# 之后）留在浏览器本地，其余
 * userinfo、path、query 都写进请求行或 Authorization 头，远端一样记得下来。
 */
function templateSentToServer(template: string): string {
  return template.split('#')[0]
}

/** 已下架的三个内置远程面板域名 */
const RETIRED_DEFAULT_PANEL_HOSTS = new Set([
  'metacubex.github.io',
  'yacd.metacubex.one',
  'board.zash.run.place'
])

/**
 * 升级时只清理仍然指向那三个第三方站点的面板。用户完全可能保留了内置条目的 id
 * 却把 URL 换成自己的本地 dashboard——按 id 删会静默毁掉他自己的数据。
 */
export function isRetiredDefaultPanelUrl(template: unknown): boolean {
  if (typeof template !== 'string') return false
  try {
    const hostname = new URL(
      template.replaceAll('%host', 'host.invalid').replaceAll('%port', '1')
    ).hostname.toLowerCase()
    return RETIRED_DEFAULT_PANEL_HOSTS.has(hostname)
  } catch {
    return false
  }
}

export function resolveWebUIPanelUrl(
  template: string,
  variables: WebUIPanelVariables
): ResolvedWebUIPanel {
  // 带字符串模式的 String.replace 只换第一处，重复引用 %host 的自定义面板会留下字面量
  const url = template
    .replaceAll('%host', variables.host)
    .replaceAll('%port', variables.port)
    .replaceAll('%secret', variables.secret)

  let parsed: URL | null = null
  try {
    parsed = new URL(url)
  } catch {
    parsed = null
  }

  const hostname = parsed?.hostname.toLowerCase() ?? ''
  const carriesSecret = variables.secret !== '' && template.includes('%secret')

  return {
    url,
    hostname,
    isExternal: !parsed || !(LOOPBACK_HOSTS.has(hostname) || hostname.endsWith('.localhost')),
    carriesSecret,
    secretInQuery: carriesSecret && templateSentToServer(template).includes('%secret')
  }
}
