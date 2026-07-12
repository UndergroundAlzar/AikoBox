import { mkdir, writeFile, readFile } from 'fs/promises'
import { existsSync } from 'fs'
import { isIP } from 'net'
import { createHash, randomBytes } from 'crypto'
import path from 'path'
import {
  getControledMihomoConfig,
  getProfileConfig,
  getProfile,
  getProfileItem,
  getOverride,
  getOverrideItem,
  getOverrideConfig,
  getAppConfig
} from '../config'
import { mihomoProfileWorkDir, mihomoWorkDir, dataDir, rulePath } from '../utils/dirs'
import { parse, stringify } from '../utils/yaml'
import { deepMerge } from '../utils/merge'
import { createLogger } from '../utils/logger'
import { decryptAgeContent } from '../utils/age'
import { DEFAULT_CONTROL_DNS, DEFAULT_CONTROL_SNIFF } from '../../shared/appConfig'
import { convertClashToSingbox } from './singbox/convert'
import { runtimeCandidateProfilePath, singboxCandidateConfigPath } from './singbox'
import { resolveProxyProviders } from './singbox/providerResolver'
import { resolveRuleProviders } from './singbox/ruleProviderResolver'
import { getHealthyProxyEndpoint } from './healthyProxyEndpoint'

const factoryLogger = createLogger('Factory')
const SMART_OVERRIDE_ID = 'smart-core-override'

let runtimeConfigStr: string = ''
let runtimeConfig: IMihomoConfig = {} as IMihomoConfig
let pendingRuntimeConfigStr: string | null = null
let pendingRuntimeConfig: IMihomoConfig | null = null

// 辅助函数：处理带偏移量的规则
function processRulesWithOffset(ruleStrings: string[], currentRules: string[], isAppend = false) {
  const normalRules: string[] = []
  const rules = [...currentRules]

  ruleStrings.forEach((ruleStr) => {
    const parts = ruleStr.split(',')
    const firstPartIsNumber =
      !isNaN(Number(parts[0])) && parts[0].trim() !== '' && parts.length >= 3

    if (firstPartIsNumber) {
      const offset = parseInt(parts[0])
      const rule = parts.slice(1).join(',')

      if (isAppend) {
        // 后置规则的插入位置计算
        const insertPosition = Math.max(0, rules.length - Math.min(offset, rules.length))
        rules.splice(insertPosition, 0, rule)
      } else {
        // 前置规则的插入位置计算
        const insertPosition = Math.min(offset, rules.length)
        rules.splice(insertPosition, 0, rule)
      }
    } else {
      normalRules.push(ruleStr)
    }
  })

  return { normalRules, insertRules: rules }
}

/**
 * 确保在启用特定条件（如 Smart 覆写）且启用了 TUN 模式时，将代理服务器的 IP 地址添加到路由排除列表中，以避免路由回环。
 * 该函数会遍历配置中的所有代理节点，提取出服务器的 IP 地址（支持 IPv4/IPv6），并将其转换为对应的 CIDR 格式（IPv4: /32, IPv6: /128）。
 *
 * @param profile 当前的 Mihomo 配置对象
 * @param enabled 是否需要执行排除逻辑（通常为是否启用了 Smart 核心覆写）
 * @returns 此次新添加到排除列表中的网段/IP 数组
 */
function ensureSmartProxyServerTunExclude(profile: IMihomoConfig, enabled: boolean): string[] {
  if (!enabled || profile.tun?.enable !== true || !Array.isArray(profile.proxies)) return []

  const routeExcludeAddress = Array.isArray(profile.tun['route-exclude-address'])
    ? [...profile.tun['route-exclude-address']]
    : []
  profile.tun['route-exclude-address'] = routeExcludeAddress

  const existing = new Set(routeExcludeAddress.map((address) => address.trim().toLowerCase()))
  const added: string[] = []

  for (const proxy of profile.proxies as unknown[]) {
    if (!proxy || typeof proxy !== 'object') continue

    const server = (proxy as Record<string, unknown>).server
    if (typeof server !== 'string' && typeof server !== 'number') continue

    const host = String(server)
      .trim()
      .replace(/^\[(.*)\]$/, '$1')
      .toLowerCase()
    const ipVersion = isIP(host)
    if (!ipVersion) continue

    const cidr = ipVersion === 4 ? `${host}/32` : `${host}/128`
    if (existing.has(host) || existing.has(cidr)) continue

    routeExcludeAddress.push(cidr)
    existing.add(cidr)
    added.push(cidr)
  }

  return added
}

export async function generateProfile(): Promise<string | undefined> {
  // 读取最新的配置
  const { current } = await getProfileConfig(true)
  const {
    diffWorkDir = false,
    controlDns = DEFAULT_CONTROL_DNS,
    controlSniff = DEFAULT_CONTROL_SNIFF,
    useNameserverPolicy,
    userAgent: providerUserAgent
  } = await getAppConfig()
  const currentProfileItem = await getProfileItem(current)
  const allowLocalProviderFiles = currentProfileItem?.type === 'local'
  const ageSecretKey = currentProfileItem?.ageSecretKey || ''
  const baseProfile = await getProfile(current)
  const overrideIds = await getOrderedOverrideIds(current)
  const profileWithNormalOverride = await applyOverrides(
    baseProfile,
    overrideIds.normal,
    ageSecretKey
  )
  const profileWithRuleOverride = await applyRuleOverride(current, profileWithNormalOverride)
  const currentProfile = await applyOverrides(
    profileWithRuleOverride,
    overrideIds.smart,
    ageSecretKey
  )
  let controledMihomoConfig = await getControledMihomoConfig()
  const providerProxyPort = getHealthyProxyEndpoint()?.port
  const workDir = diffWorkDir ? mihomoProfileWorkDir(current) : mihomoWorkDir()
  await mkdir(workDir, { recursive: true })
  const providerRequestScope = createHash('sha256')
    .update(
      JSON.stringify({
        version: 1,
        profileId: current || 'default',
        url: currentProfileItem?.url || '',
        authorization: currentProfileItem?.authToken || '',
        userAgent: currentProfileItem?.userAgent || '',
        policy: currentProfileItem?.useProxy ? 'proxy-only' : 'direct-fallback'
      })
    )
    .digest('hex')

  // 根据开关状态过滤控制配置
  controledMihomoConfig = { ...controledMihomoConfig }
  if (!controlDns) {
    delete controledMihomoConfig.dns
    delete controledMihomoConfig.hosts
  }
  if (!controlSniff) {
    delete controledMihomoConfig.sniffer
  }
  if (!useNameserverPolicy) {
    delete controledMihomoConfig?.dns?.['nameserver-policy']
  }

  let profile = deepMerge(currentProfile, controledMihomoConfig)
  const providerResolution = await resolveProxyProviders(
    profile as unknown as Record<string, unknown>,
    {
      baseDir: workDir,
      allowFileProviders: allowLocalProviderFiles,
      proxyPort: providerProxyPort,
      forceProxy: Boolean(currentProfileItem?.useProxy),
      requestScope: providerRequestScope,
      userAgent: currentProfileItem?.userAgent || providerUserAgent || 'AikoBox',
      cacheDir: path.join(dataDir(), 'provider-cache')
    }
  )
  for (const warning of providerResolution.warnings) {
    factoryLogger.warn(`[proxy-provider] ${warning}`)
  }
  if (providerResolution.errors.length > 0) {
    throw new Error(
      `Proxy providers cannot be resolved safely:\n${providerResolution.errors.join('\n')}`
    )
  }
  const ruleProviderResolution = await resolveRuleProviders(providerResolution.config, {
    baseDir: workDir,
    allowFileProviders: allowLocalProviderFiles,
    proxyPort: providerProxyPort,
    forceProxy: Boolean(currentProfileItem?.useProxy),
    requestScope: providerRequestScope,
    userAgent: currentProfileItem?.userAgent || providerUserAgent || 'AikoBox',
    cacheDir: path.join(dataDir(), 'rule-provider-cache')
  })
  for (const warning of ruleProviderResolution.warnings) {
    factoryLogger.warn(`[rule-provider] ${warning}`)
  }
  if (ruleProviderResolution.errors.length > 0) {
    throw new Error(
      `Rule providers cannot be resolved safely:\n${ruleProviderResolution.errors.join('\n')}`
    )
  }
  profile = ruleProviderResolution.config as unknown as IMihomoConfig
  // 关闭 DNS 覆写时，如果最终配置没有启用的 DNS 配置，清空 dns-hijack 避免请求被劫持但无法处理
  if (!controlDns && profile.tun && !profile.dns?.enable) {
    profile.tun = { ...profile.tun, 'dns-hijack': [] }
  }
  // Smart Override JS 早于受控 TUN 配置合并执行；最终配置写出前再排除代理服务器 IP。
  const addedProxyServerRouteExcludes = ensureSmartProxyServerTunExclude(
    profile,
    overrideIds.smart.length > 0
  )
  if (addedProxyServerRouteExcludes.length > 0) {
    factoryLogger.info(
      'Added Smart Override proxy server TUN route excludes',
      addedProxyServerRouteExcludes
    )
  }
  // 确保可以拿到基础日志信息
  // 使用 debug 可以调试内核相关问题 `debug/pprof`
  if (['info', 'debug', 'warning', 'error', 'silent'].includes(profile['log-level']) === false) {
    profile['log-level'] = 'info'
  }
  // 删除空的局域网允许列表，避免局域网访问异常
  if (!profile['lan-allowed-ips']?.length) {
    delete profile['lan-allowed-ips']
  }
  if (diffWorkDir) {
    await prepareProfileWorkDir(current)
  }
  const {
    config: singboxConfig,
    warnings,
    errors
  } = convertClashToSingbox(profile as unknown as Record<string, unknown>, {
    platform: process.platform,
    controllerSecret: randomBytes(32).toString('base64url')
  })
  for (const warning of warnings) {
    factoryLogger.warn(`[singbox-convert] ${warning}`)
  }
  if (errors.length > 0) {
    for (const error of errors) {
      factoryLogger.error(`[singbox-convert] ${error}`)
    }
    throw new Error(`Configuration cannot be converted safely:\n${errors.join('\n')}`)
  }

  // Keep UI/API runtime state pending until the candidate has passed both
  // `sing-box check` and the real process health gate.
  pendingRuntimeConfig = profile
  pendingRuntimeConfigStr = stringify(profile)
  await writeFile(runtimeCandidateProfilePath(workDir), pendingRuntimeConfigStr)
  await writeFile(singboxCandidateConfigPath(workDir), JSON.stringify(singboxConfig, null, 2))
  return current
}

export function promotePendingRuntimeConfig(): void {
  if (!pendingRuntimeConfig || pendingRuntimeConfigStr === null) return
  runtimeConfig = pendingRuntimeConfig
  runtimeConfigStr = pendingRuntimeConfigStr
  pendingRuntimeConfig = null
  pendingRuntimeConfigStr = null
}

export function restoreRuntimeConfig(runtimeProfile: string | undefined): void {
  pendingRuntimeConfig = null
  pendingRuntimeConfigStr = null
  if (!runtimeProfile) return
  runtimeConfig = parse(runtimeProfile) as IMihomoConfig
  runtimeConfigStr = runtimeProfile
}

export function discardPendingRuntimeConfig(): void {
  pendingRuntimeConfig = null
  pendingRuntimeConfigStr = null
}

export function getPendingRuntimeConfig(): IMihomoConfig | null {
  return pendingRuntimeConfig
}

async function applyRuleOverride(
  current: string | undefined,
  profile: IMihomoConfig
): Promise<IMihomoConfig> {
  try {
    const ruleFilePath = rulePath(current || 'default')
    if (!existsSync(ruleFilePath)) {
      return profile
    }

    const ruleFileContent = await readFile(ruleFilePath, 'utf-8')
    const ruleData = parse(ruleFileContent) as {
      prepend?: string[]
      append?: string[]
      delete?: string[]
    } | null

    if (!ruleData || typeof ruleData !== 'object') {
      return profile
    }

    if (!profile.rules) {
      profile.rules = [] as unknown as []
    }

    let rules = [...profile.rules] as unknown as string[]

    if (ruleData.prepend?.length) {
      const { normalRules: prependRules, insertRules } = processRulesWithOffset(
        ruleData.prepend,
        rules
      )
      rules = [...prependRules, ...insertRules]
    }

    if (ruleData.append?.length) {
      const { normalRules: appendRules, insertRules } = processRulesWithOffset(
        ruleData.append,
        rules,
        true
      )
      rules = [...insertRules, ...appendRules]
    }

    if (ruleData.delete?.length) {
      const deleteSet = new Set(ruleData.delete)
      rules = rules.filter((rule) => {
        const ruleStr = Array.isArray(rule) ? rule.join(',') : rule
        return !deleteSet.has(ruleStr)
      })
    }

    profile.rules = rules as unknown as []
    return profile
  } catch (error) {
    factoryLogger.error('Failed to read or apply rule file', error)
    return profile
  }
}

async function prepareProfileWorkDir(current: string | undefined): Promise<void> {
  if (!existsSync(mihomoProfileWorkDir(current))) {
    await mkdir(mihomoProfileWorkDir(current), { recursive: true })
  }
}

async function getOrderedOverrideIds(current: string | undefined): Promise<{
  normal: string[]
  smart: string[]
}> {
  const { items = [] } = (await getOverrideConfig()) || {}
  const globalOverride = items.filter((item) => item.global).map((item) => item.id)
  const { override = [] } = (await getProfileItem(current)) || {}
  const orderedOverrideIds = [...new Set(globalOverride.concat(override))]

  return {
    normal: orderedOverrideIds.filter((id) => id !== SMART_OVERRIDE_ID),
    smart: orderedOverrideIds.filter((id) => id === SMART_OVERRIDE_ID)
  }
}

async function applyOverrides(
  profile: IMihomoConfig,
  overrideIds: string[],
  ageSecretKey: string
): Promise<IMihomoConfig> {
  for (const ov of overrideIds) {
    const item = await getOverrideItem(ov)
    const content = await getOverride(ov, item?.ext || 'js')
    switch (item?.ext) {
      case 'js':
        throw new Error(
          `JavaScript override "${item.name || ov}" is disabled on Windows because it is not a security boundary; convert it to a declarative YAML override`
        )
      case 'yaml': {
        const decryptedContent = await decryptAgeContent(content, ageSecretKey, `override "${ov}"`)
        let patch = parse(decryptedContent) || {}
        if (typeof patch !== 'object') patch = {}
        profile = deepMerge(profile, patch, true)
        break
      }
    }
  }
  return profile
}

export async function getRuntimeConfigStr(): Promise<string> {
  return runtimeConfigStr
}

export async function getRuntimeConfig(): Promise<IMihomoConfig> {
  return runtimeConfig
}
