import axios, { AxiosInstance } from 'axios'
import WebSocket from 'ws'
import { getAppConfig, getControledMihomoConfig } from '../config'
import { mainWindow } from '../window'
import { tray } from '../resolve/tray'
import { calcTraffic } from '../utils/calc'
import { floatingWindow } from '../resolve/floatingWindow'
import { createLogger } from '../utils/logger'
import { getRuntimeConfig } from './factory'
import { getActiveController } from './singbox'

const mihomoApiLogger = createLogger('MihomoApi')

let axiosIns: AxiosInstance | null = null
let currentControllerKey: string = ''

const MAX_RETRY = 10
const RECONNECT_INTERVAL_MS = 1000

interface MihomoStreamState {
  ws: WebSocket | null
  retry: number
  active: boolean
  generation: number
  reconnectTimer: NodeJS.Timeout | null
}

const trafficStream: MihomoStreamState = {
  ws: null,
  retry: MAX_RETRY,
  active: false,
  generation: 0,
  reconnectTimer: null
}
const memoryStream: MihomoStreamState = {
  ws: null,
  retry: MAX_RETRY,
  active: false,
  generation: 0,
  reconnectTimer: null
}
const logsStream: MihomoStreamState = {
  ws: null,
  retry: MAX_RETRY,
  active: false,
  generation: 0,
  reconnectTimer: null
}
const connectionsStream: MihomoStreamState = {
  ws: null,
  retry: MAX_RETRY,
  active: false,
  generation: 0,
  reconnectTimer: null
}

function clearStreamReconnect(stream: MihomoStreamState): void {
  if (!stream.reconnectTimer) return
  clearTimeout(stream.reconnectTimer)
  stream.reconnectTimer = null
}

function disposeStreamSocket(ws: WebSocket): void {
  ws.onmessage = null
  ws.onclose = null
  ws.onerror = null
  ws.removeAllListeners()

  if (ws.readyState === WebSocket.OPEN) {
    ws.close()
  } else if (ws.readyState === WebSocket.CONNECTING) {
    ws.terminate()
  }
}

function activateStream(stream: MihomoStreamState): void {
  stream.active = true
  stream.retry = MAX_RETRY
  clearStreamReconnect(stream)
}

function stopStream(stream: MihomoStreamState): void {
  stream.active = false
  stream.retry = 0
  stream.generation++
  clearStreamReconnect(stream)

  const ws = stream.ws
  stream.ws = null
  if (ws) {
    disposeStreamSocket(ws)
  }
}

function beginStreamConnection(stream: MihomoStreamState): number | null {
  if (!stream.active) return null

  stream.generation++
  clearStreamReconnect(stream)

  const ws = stream.ws
  stream.ws = null
  if (ws) {
    disposeStreamSocket(ws)
  }

  return stream.generation
}

function isCurrentStream(stream: MihomoStreamState, generation: number): boolean {
  return stream.active && stream.generation === generation
}

function scheduleStreamReconnect(
  stream: MihomoStreamState,
  generation: number,
  connect: () => Promise<void>
): void {
  if (!isCurrentStream(stream, generation) || stream.retry <= 0) return

  stream.retry--
  clearStreamReconnect(stream)
  stream.reconnectTimer = setTimeout(() => {
    stream.reconnectTimer = null
    if (isCurrentStream(stream, generation)) {
      void connect()
    }
  }, RECONNECT_INTERVAL_MS)
}

function closeErroredStreamSocket(
  stream: MihomoStreamState,
  generation: number,
  ws: WebSocket
): void {
  if (!isCurrentStream(stream, generation)) return

  if (ws.readyState === WebSocket.OPEN) {
    ws.close()
  } else if (ws.readyState === WebSocket.CONNECTING) {
    ws.terminate()
  }
}

function createMihomoWebSocket(endpoint: string): {
  ws: WebSocket
  wsUrl: string
} {
  const { host, port, secret } = getActiveController()
  const separator = endpoint.includes('?') ? '&' : '?'
  const wsUrl = `ws://${host}:${port}${endpoint}${separator}token=${encodeURIComponent(secret)}`

  return {
    ws: new WebSocket(wsUrl, {
      headers: secret ? { Authorization: `Bearer ${secret}` } : undefined
    }),
    wsUrl
  }
}

export const getAxios = async (force: boolean = false): Promise<AxiosInstance> => {
  const { host, port, secret } = getActiveController()
  const controllerKey = `${host}:${port}:${secret}`

  if (axiosIns && !force && currentControllerKey === controllerKey) {
    return axiosIns
  }

  currentControllerKey = controllerKey
  mihomoApiLogger.info(`Creating axios instance for controller: ${host}:${port}`)

  axiosIns = axios.create({
    baseURL: `http://${host}:${port}`,
    headers: secret ? { Authorization: `Bearer ${secret}` } : undefined,
    timeout: 15000
  })

  axiosIns.interceptors.response.use(
    (response) => {
      return response.data
    },
    (error) => {
      if (error.code === 'ECONNREFUSED') {
        mihomoApiLogger.debug(`Controller not ready: ${host}:${port}`)
      } else {
        mihomoApiLogger.error(`Axios error with controller ${host}:${port}: ${error.message}`)
      }

      if (error.response && error.response.data) {
        return Promise.reject(error.response.data)
      }
      return Promise.reject(error)
    }
  )
  return axiosIns
}

export async function mihomoVersion(): Promise<IMihomoVersion> {
  try {
    const instance = await getAxios()
    return await instance.get('/version')
  } catch (error) {
    // REST 不可用时兜底：读取 sing-box 命令行版本
    try {
      const { getCachedCoreVersion } = await import('./manager')
      const version = await getCachedCoreVersion()
      if (version) return { version, meta: true }
    } catch {
      // ignore
    }
    throw error
  }
}

export const patchMihomoConfig = async (patch: Partial<IMihomoConfig>): Promise<void> => {
  const instance = await getAxios()
  return await instance.patch('/configs', patch)
}

export const mihomoCloseConnection = async (id: string): Promise<void> => {
  const instance = await getAxios()
  return await instance.delete(`/connections/${encodeURIComponent(id)}`)
}

export const mihomoCloseAllConnections = async (): Promise<void> => {
  const instance = await getAxios()
  return await instance.delete('/connections')
}

export const mihomoRules = async (): Promise<IMihomoRulesInfo> => {
  const instance = await getAxios()
  return await instance.get('/rules')
}

export const mihomoRulesDisable = async (rules: Record<string, boolean>): Promise<void> => {
  // sing-box clash_api 不支持 /rules/disable，软失败
  try {
    const instance = await getAxios()
    return await instance.patch('/rules/disable', rules)
  } catch (error) {
    mihomoApiLogger.warn('rules/disable is not supported by the sing-box core', error)
  }
}

export const mihomoProxies = async (): Promise<IMihomoProxies> => {
  const instance = await getAxios()
  const proxies = (await instance.get('/proxies')) as IMihomoProxies
  if (!proxies.proxies['GLOBAL']) {
    throw new Error('GLOBAL proxy not found')
  }
  return proxies
}

function isMihomoGroup(proxy: IMihomoProxy | IMihomoGroup | undefined): proxy is IMihomoGroup {
  return Boolean(proxy && 'all' in proxy)
}

const PROVIDER_DETAIL_FETCH_THRESHOLD = 8

async function mihomoProxyProvider(name: string): Promise<IMihomoProxyProvider> {
  const instance = await getAxios()
  return await instance.get(`/providers/proxies/${encodeURIComponent(name)}`)
}

async function resolveProviderProxies(
  names: Set<string>,
  providerNames: Set<string>,
  fallbackToAllProviders: boolean
): Promise<Record<string, IMihomoProxy>> {
  if (names.size === 0) return {}

  const providers =
    fallbackToAllProviders || providerNames.size > PROVIDER_DETAIL_FETCH_THRESHOLD
      ? Object.values((await mihomoProxyProviders()).providers)
      : (
          await Promise.allSettled([...providerNames].map((name) => mihomoProxyProvider(name)))
        ).flatMap((result) => (result.status === 'fulfilled' ? [result.value] : []))

  const providerProxies: Record<string, IMihomoProxy> = {}
  providers.forEach((provider) => {
    provider.proxies?.forEach((proxy) => {
      if (names.has(proxy.name)) {
        providerProxies[proxy.name] = proxy
      }
    })
  })
  return providerProxies
}

export const mihomoGroups = async (): Promise<IMihomoMixedGroup[]> => {
  const { mode = 'rule' } = await getControledMihomoConfig()
  if (mode === 'direct') return []
  const [proxies, runtime] = await Promise.all([mihomoProxies(), getRuntimeConfig()])
  const rawGroups: { group: IMihomoGroup; providers: string[] }[] = []

  runtime?.['proxy-groups']?.forEach((group: { name: string; url?: string; use?: string[] }) => {
    const proxy = proxies.proxies[group.name]
    if (isMihomoGroup(proxy) && !proxy.hidden) {
      rawGroups.push({ group: { ...proxy, testUrl: group.url }, providers: group.use || [] })
    }
  })

  if (!rawGroups.find(({ group }) => group.name === 'GLOBAL')) {
    const global = proxies.proxies['GLOBAL']
    if (isMihomoGroup(global) && !global.hidden) {
      rawGroups.push({ group: global, providers: [] })
    }
  }

  const missingProxyNames = new Set<string>()
  const providerNames = new Set<string>()
  let fallbackToAllProviders = false
  rawGroups.forEach(({ group, providers }) => {
    const proxyNames = group.all || []
    proxyNames.forEach((name) => {
      if (!proxies.proxies[name]) {
        missingProxyNames.add(name)
        if (providers.length > 0) {
          providers.forEach((provider) => providerNames.add(provider))
        } else {
          fallbackToAllProviders = true
        }
      }
    })
  })

  const providerProxies = await resolveProviderProxies(
    missingProxyNames,
    providerNames,
    fallbackToAllProviders
  )
  const groups: IMihomoMixedGroup[] = []
  rawGroups.forEach(({ group }) => {
    const newAll = (group.all || [])
      .map((name) => proxies.proxies[name] || providerProxies[name])
      .filter((proxy): proxy is IMihomoProxy | IMihomoGroup => Boolean(proxy))
    groups.push({ ...group, all: newAll })
  })

  if (mode === 'global') {
    const global = groups.findIndex((group) => group.name === 'GLOBAL')
    if (global > 0) groups.unshift(groups.splice(global, 1)[0])
  }
  return groups
}

export const mihomoProxyProviders = async (): Promise<IMihomoProxyProviders> => {
  // sing-box 没有 proxy providers，软失败返回空集合
  try {
    const instance = await getAxios()
    const result = (await instance.get('/providers/proxies')) as IMihomoProxyProviders
    return result && result.providers ? result : { providers: {} }
  } catch (error) {
    mihomoApiLogger.debug('providers/proxies unavailable on sing-box core', error)
    return { providers: {} }
  }
}

export const mihomoUpdateProxyProviders = async (name: string): Promise<void> => {
  try {
    const instance = await getAxios()
    return await instance.put(`/providers/proxies/${encodeURIComponent(name)}`)
  } catch (error) {
    mihomoApiLogger.warn(`update proxy provider "${name}" is not supported`, error)
  }
}

export const mihomoRuleProviders = async (): Promise<IMihomoRuleProviders> => {
  // sing-box 没有 Clash rule providers，软失败返回空集合
  try {
    const instance = await getAxios()
    const result = (await instance.get('/providers/rules')) as IMihomoRuleProviders
    return result && result.providers ? result : { providers: {} }
  } catch (error) {
    mihomoApiLogger.debug('providers/rules unavailable on sing-box core', error)
    return { providers: {} }
  }
}

export const mihomoUpdateRuleProviders = async (name: string): Promise<void> => {
  try {
    const instance = await getAxios()
    return await instance.put(`/providers/rules/${encodeURIComponent(name)}`)
  } catch (error) {
    mihomoApiLogger.warn(`update rule provider "${name}" is not supported`, error)
  }
}

export const mihomoChangeProxy = async (group: string, proxy: string): Promise<IMihomoProxy> => {
  const instance = await getAxios()
  return await instance.put(`/proxies/${encodeURIComponent(group)}`, { name: proxy })
}

export const mihomoUnfixedProxy = async (group: string): Promise<IMihomoProxy> => {
  // sing-box 不支持取消固定节点，软失败
  try {
    const instance = await getAxios()
    return await instance.delete(`/proxies/${encodeURIComponent(group)}`)
  } catch (error) {
    mihomoApiLogger.warn(`unfixed proxy for group "${group}" is not supported`, error)
    return {} as IMihomoProxy
  }
}

export const mihomoUpgradeGeo = async (): Promise<void> => {
  // sing-box 使用远程 rule-set，无 geo 数据库可升级；软失败
  mihomoApiLogger.warn('upgrade geo is not supported with the sing-box core')
}

export const mihomoProxyDelay = async (
  proxy: string,
  url?: string,
  provider?: string
): Promise<IMihomoDelay> => {
  const appConfig = await getAppConfig()
  const { delayTestUrl, delayTestTimeout } = appConfig
  const instance = await getAxios()
  if (provider) {
    // sing-box 无 provider healthcheck，降级为普通节点延迟测试
    mihomoApiLogger.debug(`provider healthcheck unsupported, fallback to proxy delay: ${proxy}`)
  }
  return await instance.get(`/proxies/${encodeURIComponent(proxy)}/delay`, {
    params: {
      url: delayTestUrl || url || 'https://www.gstatic.com/generate_204',
      timeout: delayTestTimeout || 5000
    }
  })
}

export const mihomoGroupDelay = async (group: string, url?: string): Promise<IMihomoGroupDelay> => {
  const appConfig = await getAppConfig()
  const { delayTestUrl, delayTestTimeout } = appConfig
  const instance = await getAxios()
  return await instance.get(`/group/${encodeURIComponent(group)}/delay`, {
    params: {
      url: delayTestUrl || url || 'https://www.gstatic.com/generate_204',
      timeout: delayTestTimeout || 5000
    }
  })
}

export const mihomoUpgrade = async (): Promise<void> => {
  // 应用内更新内核已停用：内核随应用一起发布
  throw new Error('In-app core upgrade is disabled: the sing-box core ships with the app')
}

export const mihomoUpgradeUI = async (): Promise<void> => {
  mihomoApiLogger.warn('upgrade UI is not supported with the sing-box core')
}

export const mihomoHotReloadConfig = async (): Promise<void> => {
  // sing-box clash_api 不支持从文件热重载配置，降级为重新生成配置并重启内核
  mihomoApiLogger.info('hot reload requested, falling back to core restart for sing-box')
  const { restartCore } = await import('./manager')
  await restartCore()
  try {
    const { scheduleRuntimeConfigUpload } = await import('../resolve/gistApi')
    scheduleRuntimeConfigUpload()
  } catch (error) {
    mihomoApiLogger.warn('Failed to schedule runtime config Gist sync', error)
  }
}

// Smart 内核 API（sing-box 无对应能力，软失败）
export const mihomoSmartGroupWeights = async (
  groupName: string
): Promise<Record<string, number>> => {
  mihomoApiLogger.debug(`smart group weights unavailable for "${groupName}"`)
  return {}
}

export const mihomoSmartFlushCache = async (configName?: string): Promise<void> => {
  mihomoApiLogger.debug(`smart flush cache unavailable${configName ? ` for "${configName}"` : ''}`)
}

export const startMihomoTraffic = async (): Promise<void> => {
  activateStream(trafficStream)
  await mihomoTraffic()
}

export const stopMihomoTraffic = (): void => {
  stopStream(trafficStream)
}

const mihomoTraffic = async (): Promise<void> => {
  const generation = beginStreamConnection(trafficStream)
  if (generation === null) return

  const { ws, wsUrl } = createMihomoWebSocket('/traffic')

  mihomoApiLogger.info(
    `Creating traffic WebSocket with URL: ${wsUrl.replace(/token=[^&]*/, 'token=***')}`
  )
  trafficStream.ws = ws

  ws.onmessage = (e): void => {
    if (!isCurrentStream(trafficStream, generation)) return

    const data = e.data as string
    trafficStream.retry = MAX_RETRY
    try {
      const json = JSON.parse(data) as IMihomoTrafficInfo
      mainWindow?.webContents.send('mihomoTraffic', json)
      if (process.platform !== 'linux') {
        tray?.setToolTip(
          '↑' +
            `${calcTraffic(json.up)}/s`.padStart(9) +
            '\n↓' +
            `${calcTraffic(json.down)}/s`.padStart(9)
        )
      }
      floatingWindow?.webContents.send('mihomoTraffic', json)
    } catch {
      // ignore
    }
  }

  ws.onclose = (): void => {
    if (!isCurrentStream(trafficStream, generation)) return
    trafficStream.ws = null
    scheduleStreamReconnect(trafficStream, generation, mihomoTraffic)
  }

  ws.onerror = (error): void => {
    mihomoApiLogger.error('Traffic WebSocket error', error)
    closeErroredStreamSocket(trafficStream, generation, ws)
  }
}

export const startMihomoMemory = async (): Promise<void> => {
  activateStream(memoryStream)
  await mihomoMemory()
}

export const stopMihomoMemory = (): void => {
  stopStream(memoryStream)
}

const mihomoMemory = async (): Promise<void> => {
  const generation = beginStreamConnection(memoryStream)
  if (generation === null) return

  const { ws } = createMihomoWebSocket('/memory')
  memoryStream.ws = ws

  ws.onmessage = (e): void => {
    if (!isCurrentStream(memoryStream, generation)) return

    const data = e.data as string
    memoryStream.retry = MAX_RETRY
    try {
      mainWindow?.webContents.send('mihomoMemory', JSON.parse(data) as IMihomoMemoryInfo)
    } catch {
      // ignore
    }
  }

  ws.onclose = (): void => {
    if (!isCurrentStream(memoryStream, generation)) return
    memoryStream.ws = null
    scheduleStreamReconnect(memoryStream, generation, mihomoMemory)
  }

  ws.onerror = (): void => {
    closeErroredStreamSocket(memoryStream, generation, ws)
  }
}

export const startMihomoLogs = async (): Promise<void> => {
  activateStream(logsStream)
  await mihomoLogs()
}

export const stopMihomoLogs = (): void => {
  stopStream(logsStream)
}

const mihomoLogs = async (): Promise<void> => {
  const generation = beginStreamConnection(logsStream)
  if (generation === null) return

  const { 'log-level': logLevel = 'info' } = await getControledMihomoConfig()
  // sing-box 日志级别不含 silent，映射为 fatal（几乎无输出）
  const wsLogLevel = logLevel === 'silent' ? 'fatal' : logLevel

  const { ws } = createMihomoWebSocket(`/logs?level=${wsLogLevel}`)
  logsStream.ws = ws

  ws.onmessage = (e): void => {
    if (!isCurrentStream(logsStream, generation)) return

    const data = e.data as string
    logsStream.retry = MAX_RETRY
    try {
      mainWindow?.webContents.send('mihomoLogs', JSON.parse(data) as IMihomoLogInfo)
    } catch {
      // ignore
    }
  }

  ws.onclose = (): void => {
    if (!isCurrentStream(logsStream, generation)) return
    logsStream.ws = null
    scheduleStreamReconnect(logsStream, generation, mihomoLogs)
  }

  ws.onerror = (): void => {
    closeErroredStreamSocket(logsStream, generation, ws)
  }
}

export const startMihomoConnections = async (): Promise<void> => {
  activateStream(connectionsStream)
  await mihomoConnections()
}

export const stopMihomoConnections = (): void => {
  stopStream(connectionsStream)
}

const mihomoConnections = async (): Promise<void> => {
  const generation = beginStreamConnection(connectionsStream)
  if (generation === null) return

  const { ws } = createMihomoWebSocket('/connections')
  connectionsStream.ws = ws

  ws.onmessage = (e): void => {
    if (!isCurrentStream(connectionsStream, generation)) return

    const data = e.data as string
    connectionsStream.retry = MAX_RETRY
    try {
      mainWindow?.webContents.send('mihomoConnections', JSON.parse(data) as IMihomoConnectionsInfo)
    } catch {
      // ignore
    }
  }

  ws.onclose = (): void => {
    if (!isCurrentStream(connectionsStream, generation)) return
    connectionsStream.ws = null
    scheduleStreamReconnect(connectionsStream, generation, mihomoConnections)
  }

  ws.onerror = (): void => {
    closeErroredStreamSocket(connectionsStream, generation, ws)
  }
}

export async function SysProxyStatus(): Promise<boolean> {
  const appConfig = await getAppConfig()
  return appConfig.sysProxy.enable
}

export const TunStatus = async (): Promise<boolean> => {
  const config = await getControledMihomoConfig()
  return config?.tun?.enable === true
}

export function calculateTrayIconStatus(
  sysProxyEnabled: boolean,
  tunEnabled: boolean
): 'white' | 'blue' | 'green' | 'red' {
  if (sysProxyEnabled && tunEnabled) {
    return 'red' // 系统代理 + TUN 同时启用（警告状态）
  } else if (sysProxyEnabled) {
    return 'blue' // 仅系统代理启用
  } else if (tunEnabled) {
    return 'green' // 仅 TUN 启用
  } else {
    return 'white' // 全关
  }
}

export async function getTrayIconStatus(): Promise<'white' | 'blue' | 'green' | 'red'> {
  const [sysProxyEnabled, tunEnabled] = await Promise.all([SysProxyStatus(), TunStatus()])
  return calculateTrayIconStatus(sysProxyEnabled, tunEnabled)
}
